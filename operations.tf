# Alarms, the GitHub deploy role and the settings the deploy workflow reads.

# Patching: AWS patches the Fargate hosts and the database (minor versions, Sunday night maintenance window).
# The container image is rebuilt every week by GitHub Actions (.github/workflows/deploy.yml), which picks up
# Node.js and Alpine security fixes, and ECR scans every image for known vulnerabilities.

# ------------------------------------------------------------------ alarms
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# A service has no healthy container (the site is down).
resource "aws_cloudwatch_metric_alarm" "healthy" {
  for_each            = var.services
  alarm_name          = "${var.name}-${each.key}-down"
  alarm_description   = "LastPick ${each.key} - no healthy container for 2 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.service[each.key].arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
# Many server errors.
resource "aws_cloudwatch_metric_alarm" "errors" {
  for_each            = var.services
  alarm_name          = "${var.name}-${each.key}-errors"
  alarm_description   = "LastPick ${each.key} - more than 20 server errors (5xx) in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.service[each.key].arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
locals {
  ecs_alarms = { cpu = "CPUUtilization", memory = "MemoryUtilization" }
  ecs_alarm_pairs = merge([for svc, _ in var.services : { for k, m in local.ecs_alarms : "${svc}-${k}" => { service = svc, metric = m } }]...)
}
resource "aws_cloudwatch_metric_alarm" "ecs" {
  for_each            = local.ecs_alarm_pairs
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = "LastPick ${each.value.service} - ${each.value.metric} above 85% for 15 minutes (raise cpu/memory or max in var.services)"
  namespace           = "AWS/ECS"
  metric_name         = each.value.metric
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.service[each.value.service].name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

locals {
  db_alarms = {
    cpu     = { metric = "CPUUtilization", stat = "Average", op = "GreaterThanThreshold", threshold = 80, desc = "CPU above 80% for 15 minutes" }
    storage = { metric = "FreeStorageSpace", stat = "Minimum", op = "LessThanThreshold", threshold = 3000000000, desc = "less than 3 GB free" }
    memory  = { metric = "FreeableMemory", stat = "Minimum", op = "LessThanThreshold", threshold = 100000000, desc = "less than 100 MB free memory" }
    connections = { metric = "DatabaseConnections", stat = "Maximum", op = "GreaterThanThreshold", threshold = 70, desc = "more than 70 connections (limit is about 100 on db.t4g.micro)" }
  }
}
resource "aws_cloudwatch_metric_alarm" "db" {
  for_each            = local.db_alarms
  alarm_name          = "${var.name}-db-${each.key}"
  alarm_description   = "LastPick database - ${each.value.desc}"
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = each.value.stat
  period              = 300
  evaluation_periods  = 3
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count               = var.db_read_replica ? 1 : 0
  alarm_name          = "${var.name}-db-read-lag"
  alarm_description   = "LastPick read replica - more than 30 s behind the main database for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.replica[0].identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 30
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Bill alert: e-mail at 80% of the monthly budget actually spent, and when the month is forecast to go over it.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# E-mail when something happens to the database itself: failover, restart, maintenance, low storage, backup problems.
resource "aws_db_event_subscription" "db" {
  name             = "${var.name}-db-events"
  sns_topic        = aws_sns_topic.alerts.arn
  source_type      = "db-instance"
  source_ids       = concat([aws_db_instance.main.identifier], aws_db_instance.replica[*].identifier)
  event_categories = ["availability", "failover", "failure", "low storage", "maintenance", "notification", "recovery", "restoration", "backup"]
}

# ------------------------------------------------------------------ settings for the deploy workflow
resource "aws_ssm_parameter" "deploy" {
  name = "/${var.name}/deploy"
  type = "String"
  value = jsonencode({
    repository  = aws_ecr_repository.server.repository_url
    cluster     = aws_ecs_cluster.main.name
    services    = [for k in keys(var.services) : aws_ecs_service.service[k].name]
    seedTask    = aws_ecs_task_definition.service["admin"].family
    subnets     = aws_subnet.public[*].id
    securityGroup = aws_security_group.app.id
    customerUrl = "https://${aws_cloudfront_distribution.site["customer"].domain_name}"
    partnerUrl  = "https://${aws_cloudfront_distribution.site["partner"].domain_name}"
    adminUrl    = "https://${aws_cloudfront_distribution.site["admin"].domain_name}"
  })
}

# ------------------------------------------------------------------ GitHub Actions deploy role (no stored AWS keys)
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "deploy" {
  name = "${var.name}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main" }
      }
    }]
  })
}
resource "aws_iam_role_policy" "deploy" {
  name = "deploy"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = aws_ssm_parameter.deploy.arn },
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:DescribeImageScanFindings"]
        Resource = aws_ecr_repository.server.arn
      },
      {
        Effect    = "Allow"
        Action    = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource  = [for k in keys(var.services) : "arn:aws:ecs:${var.region}:${data.aws_caller_identity.me.account_id}:service/${aws_ecs_cluster.main.name}/${k}"]
      },
      {
        Effect    = "Allow"
        Action    = "ecs:RunTask"
        Resource  = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.me.account_id}:task-definition/${aws_ecs_task_definition.service["admin"].family}:*"
      },
      { Effect = "Allow", Action = "ecs:DescribeTasks", Resource = "*" },
      { Effect = "Allow", Action = "iam:PassRole", Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn] },
    ]
  })
}
