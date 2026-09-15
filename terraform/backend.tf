# Remote state backend (Requisito de Estado da Fase 3).
#
# The bucket name/region/key can't be interpolated from variables here
# (the backend block is evaluated before any variables), so fill in the
# real bucket created by terraform/bootstrap before the first `terraform init`,
# either by editing this file or by passing -backend-config on init:
#
#   terraform init \
#     -backend-config="bucket=<state_bucket_name>" \
#     -backend-config="region=us-east-1"

terraform {
  backend "s3" {
    bucket       = "togglemaster-tfstate-CHANGE-ME"
    key          = "tech-challenger-3/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # native S3 state locking (Terraform >= 1.10), no DynamoDB table needed
  }
}
