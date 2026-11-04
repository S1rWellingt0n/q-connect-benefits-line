resource "aws_connect_instance" "main" {
  instance_alias            = local.instance_alias
  identity_management_type  = "CONNECT_MANAGED"
  inbound_calls_enabled     = true
  outbound_calls_enabled    = false
  contact_flow_logs_enabled = true
}

# Connect writes flow logs here. Creating it first sets retention and encryption.
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/connect/${local.instance_alias}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_connect_hours_of_operation" "specialists" {
  instance_id = aws_connect_instance.main.id
  name        = "Benefits specialists"
  description = "Weekdays 8 AM to 5 PM"
  time_zone   = var.time_zone

  dynamic "config" {
    for_each = toset(["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY"])

    content {
      day = config.value

      start_time {
        hours   = 8
        minutes = 0
      }

      end_time {
        hours   = 17
        minutes = 0
      }
    }
  }
}

resource "aws_connect_queue" "specialists" {
  instance_id           = aws_connect_instance.main.id
  name                  = "Benefits specialists"
  description           = "Callers the AI agent hands off to a person"
  hours_of_operation_id = aws_connect_hours_of_operation.specialists.hours_of_operation_id
  max_contacts          = 25
}

resource "aws_connect_contact_flow" "benefits_line" {
  instance_id = aws_connect_instance.main.id
  name        = "Benefits line"
  description = "Q in Connect AI agent with hand-off to a specialist"
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/benefits-line.json.tftpl", {
    voice_id      = var.voice_id
    assistant_arn = awscc_wisdom_assistant.main.assistant_arn
    bot_alias_arn = awscc_lex_bot_alias.live.arn
    queue_arn     = aws_connect_queue.specialists.arn
    hours_arn     = aws_connect_hours_of_operation.specialists.arn
    gate_arn      = aws_lambda_function.guard["gate"].arn
  })

  depends_on = [
    awscc_connect_integration_association.assistant,
    awscc_connect_integration_association.lex_bot,
    terraform_data.default_agent,
    aws_connect_lambda_function_association.gate,
  ]
}

resource "aws_connect_phone_number" "main" {
  count = var.claim_phone_number ? 1 : 0

  target_arn   = aws_connect_instance.main.arn
  country_code = var.phone_country_code
  type         = "DID"
  description  = "${var.name} AI agent"
}

resource "aws_connect_phone_number_contact_flow_association" "main" {
  count = var.claim_phone_number ? 1 : 0

  instance_id     = aws_connect_instance.main.id
  phone_number_id = aws_connect_phone_number.main[0].id
  contact_flow_id = aws_connect_contact_flow.benefits_line.contact_flow_id
}

resource "awscc_connect_integration_association" "assistant" {
  instance_id      = aws_connect_instance.main.arn
  integration_type = "WISDOM_ASSISTANT"
  integration_arn  = awscc_wisdom_assistant.main.assistant_arn
}

resource "awscc_connect_integration_association" "knowledge_base" {
  instance_id      = aws_connect_instance.main.arn
  integration_type = "WISDOM_KNOWLEDGE_BASE"
  integration_arn  = awscc_wisdom_knowledge_base.policy.knowledge_base_arn
}

resource "awscc_connect_integration_association" "lex_bot" {
  instance_id      = aws_connect_instance.main.arn
  integration_type = "LEX_BOT"
  integration_arn  = awscc_lex_bot_alias.live.arn
}

resource "awscc_connect_integration_association" "mcp_tools" {
  instance_id      = aws_connect_instance.main.arn
  integration_type = "APPLICATION"
  integration_arn  = awscc_appintegrations_application.mcp_tools.application_arn
}
