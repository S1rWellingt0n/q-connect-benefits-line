provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

provider "awscc" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # Connect instance aliases are global, so add a short, stable suffix per account.
  instance_alias = "${var.name}-${substr(sha1(local.account_id), 0, 6)}"
  instance_url   = "https://${local.instance_alias}.my.connect.aws"

  # Connect sends this value as the JWT audience when the AI agent calls the
  # gateway, and security profiles grant tool access under it.
  mcp_namespace = "${var.name}-tools"
  tool_target   = "casetools"
  case_tool     = "get_case_status"

  cli_env = merge(
    { AWS_REGION = var.region },
    var.aws_profile == null ? {} : { AWS_PROFILE = var.aws_profile },
  )
}
