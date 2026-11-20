# lastpick-terraform

AWS infrastructure for **LastPick**: ECS Fargate + RDS PostgreSQL in Mumbai (`ap-south-1`), in its own VPC (`10.40.0.0/16`).
The application code (server, web apps, Dockerfile, deploy workflow) lives in [prudhvisuryalastpick/lastpick](https://github.com/prudhvisuryalastpick/lastpick).

## Tech stack

```mermaid
flowchart LR
  subgraph Users["Users (phone / browser)"]
    C["Customers<br/>LastPick app"]
    P["Partners<br/>LastPick Business"]
    A["Admins & moderators<br/>LastPick Admin"]
  end

  subgraph Edge["Amazon CloudFront (HTTPS, caching, DDoS protection)"]
    CF1["customer distribution"]
    CF2["partner distribution"]
    CF3["admin distribution"]
  end

  subgraph VPC["LastPick VPC 10.40.0.0/16 · Mumbai"]
    subgraph Private["Private subnets (no internet route)"]
      ALB["Internal Application Load Balancer<br/>routes by service header + secret"]
      RDS[("RDS PostgreSQL 16<br/>db.t4g.micro · encrypted · TLS<br/>7-day point-in-time restore")]
      RR[("Read replica<br/>feeds, dashboards, stats")]
    end
    subgraph Public["Public subnets (containers accept traffic only from the load balancer)"]
      S1["ECS service: customer<br/>Fargate ARM · 1–4 copies"]
      S2["ECS service: partner<br/>Fargate ARM · 1–3 copies"]
      S3["ECS service: admin<br/>Fargate ARM · 1 copy"]
    end
  end

  C --> CF1
  P --> CF2
  A --> CF3
  CF1 & CF2 & CF3 -- "VPC origin (AWS network)" --> ALB
  ALB --> S1 & S2 & S3
  S1 & S2 & S3 -- "writes + reads" --> RDS
  S1 & S2 & S3 -. "heavy reads" .-> RR
  RDS -- "replication" --> RR

  subgraph Ops["Operations"]
    ECR["ECR image registry<br/>scan on push"]
    SM["Secrets Manager<br/>DB password, JWT, origin secret"]
    CW["CloudWatch logs + alarms<br/>SNS e-mail · Budget alert"]
    BK["AWS Backup<br/>weekly snapshot, 5 weeks"]
  end
  GH["GitHub Actions<br/>(lastpick repo)<br/>test → build ARM image → deploy"] -- "OIDC role, no stored keys" --> ECR
  GH -- "rolling deploy, auto-rollback" --> S1 & S2 & S3
  SM -.-> S1 & S2 & S3
  S1 & S2 & S3 -.-> CW
  RDS -.-> BK
```

| Layer | Technology |
|---|---|
| Web apps (customer, partner, admin) | React 18 + Vite, served by each service's container |
| API | Node.js 22 (one codebase, `SERVICE=customer\|partner\|admin`), only package `pg` |
| Containers | Docker image (Alpine, non-root, ARM/Graviton) on ECS Fargate, Fargate Spot for extra copies |
| Database | Amazon RDS PostgreSQL 16 + read replica, Postgres job queue (`SKIP LOCKED`) |
| Edge | Amazon CloudFront (3 distributions) with VPC origins to an internal ALB |
| Secrets | AWS Secrets Manager, injected by ECS |
| Monitoring | CloudWatch logs and alarms, RDS events, SNS e-mail, AWS Budgets |
| Backups | RDS automated backups (7 days PITR) + AWS Backup weekly |
| Infrastructure as code | Terraform (this repo) |
| CI/CD | GitHub Actions with OIDC (app repo), weekly security rebuild |

## Files

| File | What it creates |
|---|---|
| `network.tf` | VPC, 2 public subnets (containers), 2 private subnets (load balancer, database), security groups |
| `ecs.tf` | ECR, ECS cluster, 3 services (customer, partner, admin), task definitions, CPU auto scaling |
| `alb.tf` | Internal load balancer, target groups, header-based routing |
| `cdn.tf` | CloudFront VPC origin and 3 distributions |
| `data.tf` | RDS main database + read replica, parameter group, Secrets Manager, AWS Backup |
| `operations.tf` | Alarms, RDS event e-mails, budget alert, GitHub deploy role, `/lastpick/deploy` settings |

## Create it (AWS CloudShell, region Mumbai, ~20 minutes)

```bash
sudo dnf install -y dnf-plugins-core && sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo && sudo dnf install -y terraform
git clone https://github.com/prudhvisuryalastpick/lastpick-terraform && cd lastpick-terraform
cp terraform.tfvars.example terraform.tfvars    # put your e-mail; protect_data = false for a test setup you'll delete
terraform init
terraform plan
terraform apply
terraform output
```

Then:
1. Confirm the alarm and budget e-mails from AWS.
2. In the **lastpick** repo: Settings → Secrets and variables → Actions → Variables → `AWS_DEPLOY_ROLE_ARN` = `terraform output -raw deploy_role_arn`.
3. In the **lastpick** repo: Actions → Deploy to AWS → Run workflow (tick *test accounts*). Until this first run the services have no image and keep retrying; that's expected.
4. Test account password: Secrets Manager → `lastpick/test-accounts`. Site addresses: `terraform output`.

## Terminate everything (after testing)

```bash
# 1. if you created it with protect_data = true, switch protection off first:
sed -i 's/^protect_data.*/protect_data = false/' terraform.tfvars && terraform apply
# 2. remove everything (database, images, logs, CloudFront, VPC):
terraform destroy
```

CloudFront distributions take about 15 minutes to disable before they are deleted; `terraform destroy` waits for that. Check the bill afterwards: Billing → Bills should show nothing new the next day.

## Monthly cost (estimate, Mumbai, $1 = ₹94.85)

≈ $93.5 ≈ ₹8,860 + 18% GST ≈ **₹10,460** with the read replica; ≈ ₹8,430 incl. GST without it (`db_read_replica = false`). Testing for a few days costs a few hundred rupees (everything is billed by the hour), as long as you destroy it afterwards.

## Keep the state safe (for a long-lived setup)

```bash
aws s3 mb s3://lastpick-terraform-state-$(aws sts get-caller-identity --query Account --output text) --region ap-south-1
# uncomment the backend "s3" block in versions.tf (put your account id in the bucket name), then:
terraform init -migrate-state
```

For a short test that you destroy from the same CloudShell, the local state is fine. Don't delete the CloudShell home folder before `terraform destroy`.

## AI agent

`.claude/agents/infra.md`: a Claude Code agent for creating, changing, checking and destroying this infrastructure. It always shows the plan and asks before `apply` or `destroy`.
