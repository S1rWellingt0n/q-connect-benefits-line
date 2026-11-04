# A public demo number can be dialed by anyone, so usage is capped where it
# enters: the flow asks the gate before anything billable starts, and a sweep
# ends any contact that runs past the per-call limit.

resource "aws_dynamodb_table" "guard" {
  name         = "${var.name}-guard"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

data "archive_file" "call_guard" {
  type        = "zip"
  source_file = "${path.module}/lambda/call_guard.py"
  output_path = "${path.module}/.build/call_guard.zip"
}

locals {
  guard_functions = {
    gate = {
      handler     = "call_guard.gate_handler"
      description = "Daily contact limit, checked first in the flow"
      actions     = ["dynamodb:UpdateItem", "dynamodb:PutItem"]
    }
    sweep = {
      handler     = "call_guard.sweep_handler"
      description = "Stops contacts that run past the per-call limit"
      actions     = ["dynamodb:Scan", "dynamodb:DeleteItem"]
    }
  }
}

resource "aws_cloudwatch_log_group" "guard" {
  for_each = local.guard_functions

  name              = "/aws/lambda/${var.name}-${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "guard" {
  for_each = local.guard_functions

  #checkov:skip=CKV_AWS_117:No VPC resources to reach. Access is IAM-scoped to one table and the instance.
  #checkov:skip=CKV_AWS_116:Invoked synchronously by Connect or on a schedule; a failed sweep simply runs again next minute.
  #checkov:skip=CKV_AWS_272:Code signing needs a Signer profile; worth adding for production.

  function_name                  = "${var.name}-${each.key}"
  description                    = each.value.description
  role                           = aws_iam_role.guard[each.key].arn
  runtime                        = "python3.13"
  architectures                  = ["arm64"]
  handler                        = each.value.handler
  filename                       = data.archive_file.call_guard.output_path
  source_code_hash               = data.archive_file.call_guard.output_base64sha256
  memory_size                    = 256
  timeout                        = 5
  kms_key_arn                    = aws_kms_key.main.arn
  reserved_concurrent_executions = 10

  environment {
    variables = {
      TABLE_NAME          = aws_dynamodb_table.guard.name
      DAILY_CONTACT_LIMIT = tostring(var.daily_contact_limit)
      MAX_CONTACT_SECONDS = tostring(var.max_contact_minutes * 60)
      INSTANCE_ID         = local.instance_id
    }
  }

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = aws_cloudwatch_log_group.guard[each.key].name
  }

  tracing_config {
    mode = "Active"
  }
}

resource "aws_iam_role" "guard" {
  for_each = local.guard_functions

  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "guard" {
  for_each = local.guard_functions

  statement {
    sid       = "GuardTable"
    actions   = each.value.actions
    resources = [aws_dynamodb_table.guard.arn]
  }

  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.guard[each.key].arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = each.key == "sweep" ? [1] : []

    content {
      sid       = "StopLongContacts"
      actions   = ["connect:StopContact"]
      resources = ["${local.instance_arn}/contact/*"]
    }
  }
}

resource "aws_iam_role_policy" "guard" {
  for_each = local.guard_functions

  name   = "runtime"
  role   = aws_iam_role.guard[each.key].id
  policy = data.aws_iam_policy_document.guard[each.key].json
}

resource "aws_lambda_permission" "gate_from_connect" {
  statement_id   = "AllowConnectInstance"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.guard["gate"].function_name
  principal      = "connect.amazonaws.com"
  source_arn     = local.instance_arn
  source_account = local.account_id
}

resource "aws_connect_lambda_function_association" "gate" {
  instance_id  = local.instance_id
  function_arn = aws_lambda_function.guard["gate"].arn
}

resource "aws_cloudwatch_event_rule" "sweep" {
  name                = "${var.name}-sweep"
  description         = "Ends contacts that run past ${var.max_contact_minutes} minutes"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "sweep" {
  rule = aws_cloudwatch_event_rule.sweep.name
  arn  = aws_lambda_function.guard["sweep"].arn
}

resource "aws_lambda_permission" "sweep_from_schedule" {
  statement_id  = "AllowSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guard["sweep"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweep.arn
}
