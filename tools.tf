locals {
  sample_cases = { for c in jsondecode(file("${path.module}/data/sample-cases.json")) : c.case_number => c }
}

resource "aws_dynamodb_table" "cases" {
  name         = "${var.name}-cases"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "case_number"

  attribute {
    name = "case_number"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table_item" "cases" {
  for_each = local.sample_cases

  table_name = aws_dynamodb_table.cases.name
  hash_key   = aws_dynamodb_table.cases.hash_key
  item       = jsonencode({ for k, v in each.value : k => { S = v } })
}

data "archive_file" "case_status" {
  type        = "zip"
  source_file = "${path.module}/lambda/case_status.py"
  output_path = "${path.module}/.build/case_status.zip"
}

resource "aws_cloudwatch_log_group" "case_status" {
  name              = "/aws/lambda/${var.name}-case-status"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "case_status" {
  function_name    = "${var.name}-case-status"
  description      = "MCP tool: case status lookup for the ${var.name} AI agent"
  role             = aws_iam_role.case_status.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "case_status.lambda_handler"
  filename         = data.archive_file.case_status.output_path
  source_code_hash = data.archive_file.case_status.output_base64sha256
  memory_size      = 256
  timeout          = 5
  kms_key_arn      = aws_kms_key.main.arn

  reserved_concurrent_executions = var.tool_concurrency_limit

  #checkov:skip=CKV_AWS_117:No VPC resources to reach. DynamoDB access is IAM-scoped to one table.
  #checkov:skip=CKV_AWS_116:Only invoked synchronously by the gateway, so a DLQ would never receive anything.
  #checkov:skip=CKV_AWS_272:Code signing needs a Signer profile; worth adding for production.

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.cases.name
    }
  }

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = aws_cloudwatch_log_group.case_status.name
  }

  tracing_config {
    mode = "Active"
  }
}

resource "aws_iam_role" "case_status" {
  name               = "${var.name}-case-status"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "case_status" {
  statement {
    sid       = "ReadCases"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.cases.arn]
  }

  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.case_status.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "case_status" {
  name   = "runtime"
  role   = aws_iam_role.case_status.id
  policy = data.aws_iam_policy_document.case_status.json
}

# AgentCore Gateway turns the Lambda into an MCP server. Connect signs each
# tool call with a JWT from the instance's own identity provider.
resource "aws_bedrockagentcore_gateway" "tools" {
  name            = "${var.name}-tools"
  description     = "MCP tools for the ${var.name} AI agent"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = "${local.instance_url}/.well-known/openid-configuration"
      allowed_audience = [local.mcp_namespace]
    }
  }

  protocol_configuration {
    mcp {
      supported_versions = ["2025-06-18"]
    }
  }

  depends_on = [aws_connect_instance.main]
}

resource "aws_bedrockagentcore_gateway_target" "cases" {
  gateway_identifier = aws_bedrockagentcore_gateway.tools.gateway_id
  name               = local.tool_target
  description        = "Case status lookups"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.case_status.arn

        tool_schema {
          inline_payload {
            name        = local.case_tool
            description = "Look up the status of a benefits case. Needs the 8 digit case number and the 5 digit ZIP code on the application. Returns verified false when the two don't match a case."

            input_schema {
              type = "object"

              property {
                name        = "case_number"
                type        = "string"
                description = "The 8 digit case number, digits only."
                required    = true
              }

              property {
                name        = "zip_code"
                type        = "string"
                description = "The 5 digit ZIP code on the application, digits only."
                required    = true
              }
            }
          }
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.gateway]
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_trust.json
}

data "aws_iam_policy_document" "gateway_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid       = "InvokeTools"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.case_status.arn]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "invoke-tools"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

# Registers the gateway with Connect as an MCP server. The namespace is the
# integration identifier: it must match the gateway's allowed audience.
resource "awscc_appintegrations_application" "mcp_tools" {
  name             = "${var.name}-tools"
  description      = "Case tools for the ${var.name} AI agent"
  namespace        = local.mcp_namespace
  application_type = "MCP_SERVER"

  application_source_config = {
    external_url_config = {
      access_url = aws_bedrockagentcore_gateway.tools.gateway_url
    }
  }

  depends_on = [aws_bedrockagentcore_gateway_target.cases]
}
