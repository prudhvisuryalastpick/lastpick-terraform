# The three containers on ECS Fargate (ARM/Graviton), behind one private load balancer.
#   customer -> customer web app + customer API
#   partner  -> partner (business) web app + business API
#   admin    -> admin panel + admin API
# Same image for all three (see /Dockerfile); SERVICE and WEB_DIR decide what each one serves.
locals {
  web_variant = { customer = "customer", partner = "owner", admin = "admin" }
  # customer/partner can grow on cheap Spot capacity; admin always on regular Fargate
  spot = { for k, _ in var.services : k => var.use_spot && k != "admin" }
}

# ------------------------------------------------------------------ container image registry
resource "aws_ecr_repository" "server" {
  name                 = "${var.name}/server"
  image_tag_mutability = "MUTABLE"                     # "latest" moves with each deploy; every build is also tagged with its commit
  force_delete         = !var.protect_data             # test setups: delete the images on destroy
  image_scanning_configuration { scan_on_push = true } # known-vulnerability scan of every image
  encryption_configuration { encryption_type = "AES256" }
}
resource "aws_ecr_lifecycle_policy" "server" {
  repository = aws_ecr_repository.server.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------------------ cluster
resource "aws_ecs_cluster" "main" {
  name = var.name
  setting {
    name  = "containerInsights"
    value = "disabled" # basic CPU/memory metrics are free; Container Insights costs extra
  }
}
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = var.services
  name              = "/${var.name}/${each.key}"
  retention_in_days = var.log_days
}

# ------------------------------------------------------------------ roles
data "aws_iam_policy_document" "ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Used by ECS itself: pull the image, write logs, read the secrets into the container.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "execution_secrets" {
  name = "secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [aws_secretsmanager_secret.db.arn, aws_secretsmanager_secret.jwt.arn,
      aws_secretsmanager_secret.origin.arn, aws_secretsmanager_secret.test_accounts.arn]
    }]
  })
}

# Used by the app inside the container. The app calls no AWS APIs yet, so it gets no permissions.
resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}

# ------------------------------------------------------------------ task definitions (one per service)
resource "aws_ecs_task_definition" "service" {
  for_each                 = var.services
  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton: about 20% cheaper than x86
  }

  container_definitions = jsonencode([{
    name                   = each.key
    image                  = "${aws_ecr_repository.server.repository_url}:latest"
    essential              = true
    readonlyRootFilesystem = false
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    stopTimeout            = 20 # time to finish requests in flight on deploys and scale-in
    environment = [
      { name = "SERVICE", value = each.key },
      { name = "SIGNUP", value = each.key == "admin" ? "closed" : "open" }, # customers and partners can create accounts
      { name = "MAIL_FROM", value = local.mail_from },                      # empty until e-mail is ready: no code needed at sign-up
      { name = "AWS_REGION", value = var.region },
      { name = "WEB_DIR", value = "/app/web/dist-${local.web_variant[each.key]}" },
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "8080" },
      { name = "RUN_WORKER", value = "1" }, # jobs are claimed with SKIP LOCKED, so every container can help
      { name = "PROXY_HOPS", value = "2" }, # visitor address comes from CF-Connecting-IP (Cloudflare)
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGHOST_READ", value = var.db_read_replica ? aws_db_instance.replica[0].address : "" },
      { name = "PGPORT", value = "5432" },
      { name = "PGDATABASE", value = "lastpick" },
      { name = "PGUSER", value = "lastpick_app" },
      { name = "DB_POOL_MAX", value = "8" }, # small database: keep total connections low as copies are added
      { name = "ADMIN_ALLOWED_IPS", value = each.key == "admin" ? join(",", var.admin_allowed_ips) : "" },
    ]
    secrets = concat([
      { name = "PGPASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
      { name = "JWT_SECRET", valueFrom = aws_secretsmanager_secret.jwt.arn },
      { name = "ORIGIN_SECRET", valueFrom = aws_secretsmanager_secret.origin.arn },
      ], each.key == "admin" ? [
      # used only by the one-off "seed" task that creates the test accounts
      { name = "SEED_PASSWORD", valueFrom = aws_secretsmanager_secret.test_accounts.arn },
    ] : [])
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service[each.key].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}

# ------------------------------------------------------------------ services
resource "aws_ecs_service" "service" {
  for_each                          = var.services
  name                              = each.key
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.service[each.key].arn
  desired_count                     = each.value.min
  platform_version                  = "LATEST" # AWS patches the Fargate hosts
  health_check_grace_period_seconds = 60
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"

  # new version starts next to the old one; the old one stops only when the new one is healthy
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true # a version that doesn't become healthy is rolled back automatically
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = local.spot[each.key] ? 0 : 1
  }
  dynamic "capacity_provider_strategy" {
    for_each = local.spot[each.key] ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
    }
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # outgoing calls without a NAT gateway; incoming only from the load balancer
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.service[each.key].arn
    container_name   = each.key
    container_port   = 8080
  }

  lifecycle {
    ignore_changes = [desired_count] # set by auto scaling
  }
  depends_on = [aws_lb_listener_rule.service, aws_ecs_cluster_capacity_providers.main]
}

# ------------------------------------------------------------------ auto scaling on CPU
resource "aws_appautoscaling_target" "service" {
  for_each           = { for k, v in var.services : k => v if v.max > v.min }
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.service[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = each.value.min
  max_capacity       = each.value.max
}
resource "aws_appautoscaling_policy" "cpu" {
  for_each           = aws_appautoscaling_target.service
  name               = "${var.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
