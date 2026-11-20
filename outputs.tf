output "customer_url" {
  description = "Customer web app"
  value       = "https://${aws_cloudfront_distribution.site["customer"].domain_name}"
}
output "partner_url" {
  description = "Partner (business) web app"
  value       = "https://${aws_cloudfront_distribution.site["partner"].domain_name}"
}
output "admin_url" {
  description = "Admin panel"
  value       = "https://${aws_cloudfront_distribution.site["admin"].domain_name}"
}
output "deploy_role_arn" {
  description = "Put this in the GitHub repo variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}
output "image_repository" {
  value = aws_ecr_repository.server.repository_url
}
output "cluster" {
  value = aws_ecs_cluster.main.name
}
output "vpc_id" {
  value = aws_vpc.main.id
}
output "database_endpoint" {
  value = aws_db_instance.main.address
}
output "database_read_endpoint" {
  value = var.db_read_replica ? aws_db_instance.replica[0].address : null
}
output "test_accounts_secret" {
  description = "Password of the test accounts: Secrets Manager -> this secret -> Retrieve secret value"
  value       = aws_secretsmanager_secret.test_accounts.name
}
