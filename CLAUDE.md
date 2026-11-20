# lastpick-terraform

Terraform for LastPick on AWS (ECS Fargate + RDS PostgreSQL + CloudFront, Mumbai). App code: prudhvisuryalastpick/lastpick.

- Use the `infra` agent (.claude/agents/infra.md) for create / check / change / destroy.
- Always plan and get a yes before apply or destroy. Never print secrets.
- After editing .tf files run `terraform fmt -recursive` and `terraform validate`.
- Keep the tech-stack diagram in README.md in sync when resources change.
- Terraform runs in GitHub Actions (`.github/workflows/infra.yml`, plan / apply / destroy); the owner installs nothing locally. State: S3 bucket lastpick-terraform-state-<account-id>.
