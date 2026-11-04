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

data "aws_connect_instance" "existing" {
  count       = local.create_instance ? 0 : 1
  instance_id = var.existing_instance_id
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  create_instance  = var.existing_instance_id == null
  create_assistant = var.existing_assistant_id == null

  # Connect instance aliases are global, so add a short, stable suffix per account.
  new_instance_alias = "${var.name}-${substr(sha1(local.account_id), 0, 6)}"

  instance_id    = local.create_instance ? aws_connect_instance.main[0].id : var.existing_instance_id
  instance_arn   = local.create_instance ? aws_connect_instance.main[0].arn : data.aws_connect_instance.existing[0].arn
  instance_alias = local.create_instance ? local.new_instance_alias : data.aws_connect_instance.existing[0].instance_alias
  instance_url   = "https://${local.instance_alias}.my.connect.aws"

  assistant_id  = local.create_assistant ? awscc_wisdom_assistant.main[0].assistant_id : var.existing_assistant_id
  assistant_arn = "arn:${local.partition}:wisdom:${local.region}:${local.account_id}:assistant/${local.assistant_id}"

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
