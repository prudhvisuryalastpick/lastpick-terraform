# Secrets and the database.

# ------------------------------------------------------------------ secrets (AWS Secrets Manager)
resource "random_password" "db" {
  length  = 32
  special = false
}
resource "random_password" "jwt" {
  length  = 64
  special = false
}
resource "random_password" "origin" {
  length  = 40
  special = false
}
resource "random_password" "test_accounts" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name}/db"
  description             = "LastPick database login"
  recovery_window_in_days = var.protect_data ? 7 : 0
}
resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "lastpick_app", password = random_password.db.result })
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.name}/jwt"
  description             = "Signs LastPick login tokens"
  recovery_window_in_days = var.protect_data ? 7 : 0
}
resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = random_password.jwt.result
}

resource "aws_secretsmanager_secret" "origin" {
  name                    = "${var.name}/origin"
  description             = "Header CloudFront sends so only CloudFront traffic is accepted"
  recovery_window_in_days = var.protect_data ? 7 : 0
}
resource "aws_secretsmanager_secret_version" "origin" {
  secret_id     = aws_secretsmanager_secret.origin.id
  secret_string = random_password.origin.result
}

resource "aws_secretsmanager_secret" "test_accounts" {
  name                    = "${var.name}/test-accounts"
  description             = "Password of the test accounts (admin@, moderator@, owner@, customer@test.lastpick.in)"
  recovery_window_in_days = var.protect_data ? 7 : 0
}
resource "aws_secretsmanager_secret_version" "test_accounts" {
  secret_id     = aws_secretsmanager_secret.test_accounts.id
  secret_string = random_password.test_accounts.result
}

# ------------------------------------------------------------------ database (RDS PostgreSQL 16)
resource "aws_db_subnet_group" "main" {
  name       = var.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "main" {
  name   = "${var.name}-pg16"
  family = "postgres16"
  parameter {
    name  = "rds.force_ssl" # TLS required
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement" # log queries slower than 1 s
    value = "1000"
  }
  parameter {
    name  = "idle_in_transaction_session_timeout" # a transaction left open for 1 minute is ended
    value = "60000"
  }
  parameter {
    name  = "idle_session_timeout" # a connection nobody uses for 10 minutes is closed (the app's own pool closes them after 30 s)
    value = "600000"
  }
}

resource "aws_db_instance" "main" {
  identifier                            = var.name
  engine                                = "postgres"
  engine_version                        = "16"
  instance_class                        = var.db_instance_class
  db_name                               = "lastpick"
  username                              = "lastpick_app"
  password                              = random_password.db.result
  allocated_storage                     = 20
  max_allocated_storage                 = 100
  storage_type                          = "gp3"
  storage_encrypted                     = true
  multi_az                              = var.db_multi_az
  publicly_accessible                   = false
  db_subnet_group_name                  = aws_db_subnet_group.main.name
  vpc_security_group_ids                = [aws_security_group.db.id]
  parameter_group_name                  = aws_db_parameter_group.main.name
  backup_retention_period               = var.db_backup_days
  backup_window                         = "20:00-20:30"         # 01:30 IST
  maintenance_window                    = "sun:21:00-sun:22:00" # Mon 02:30 IST
  auto_minor_version_upgrade            = true
  deletion_protection                   = var.protect_data
  copy_tags_to_snapshot                 = true
  skip_final_snapshot                   = !var.protect_data
  final_snapshot_identifier             = var.protect_data ? "${var.name}-final" : null
  delete_automated_backups              = !var.protect_data
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  apply_immediately                     = false
}

# Read replica: a live read-only copy (usually under a second behind). If it's ever unavailable, the app reads from the main database.
resource "aws_db_instance" "replica" {
  count                                 = var.db_read_replica ? 1 : 0
  identifier                            = "${var.name}-read"
  replicate_source_db                   = aws_db_instance.main.identifier
  instance_class                        = var.db_instance_class
  storage_type                          = "gp3"
  max_allocated_storage                 = 100
  publicly_accessible                   = false
  vpc_security_group_ids                = [aws_security_group.db.id]
  parameter_group_name                  = aws_db_parameter_group.main.name
  backup_retention_period               = 0 # backups come from the main database
  auto_minor_version_upgrade            = true
  maintenance_window                    = "sun:22:00-sun:23:00" # an hour after the main database
  skip_final_snapshot                   = true
  deletion_protection                   = false
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  apply_immediately                     = false
}

# Weekly snapshot kept 5 weeks (on top of RDS's daily backups and point-in-time restore).
resource "aws_backup_vault" "main" {
  name          = var.name
  force_destroy = !var.protect_data # test setups: delete the weekly snapshots with everything else
}
resource "aws_backup_plan" "weekly" {
  name = "${var.name}-weekly"
  rule {
    rule_name         = "weekly"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 20 ? * SAT *)"
    lifecycle { delete_after = 35 }
  }
}
resource "aws_iam_role" "backup" {
  name = "${var.name}-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "backup.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}
resource "aws_backup_selection" "db" {
  name         = "${var.name}-db"
  plan_id      = aws_backup_plan.weekly.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_db_instance.main.arn]
}

