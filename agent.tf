resource "awscc_wisdom_assistant" "main" {
  count = local.create_assistant ? 1 : 0

  name        = var.name
  type        = "AGENT"
  description = "AI agent assistant for the ${var.name} contact center"
}

resource "awscc_wisdom_ai_prompt" "orchestration" {
  assistant_id  = local.assistant_id
  name          = "${var.name}-orchestration"
  description   = "Voice persona, verification rules and tool guidance"
  type          = "ORCHESTRATION"
  template_type = "TEXT"
  api_format    = "MESSAGES"
  model_id      = var.model_id

  template_configuration = {
    text_full_ai_prompt_edit_template_configuration = {
      text = file("${path.module}/prompts/orchestration.yaml")
    }
  }
}

resource "awscc_wisdom_ai_guardrail" "main" {
  assistant_id              = local.assistant_id
  name                      = "${var.name}-guardrail"
  description               = "Keeps the agent on topic and out of sensitive data"
  blocked_input_messaging   = "Sorry, I can't help with that on this line. I can check on a case or answer questions about our benefit programs."
  blocked_outputs_messaging = "Sorry, I can't share that. I can check on a case or answer questions about our benefit programs."

  content_policy_config = {
    filters_config = concat(
      [for t in ["HATE", "INSULTS", "SEXUAL", "VIOLENCE", "MISCONDUCT"] : {
        type            = t
        input_strength  = "HIGH"
        output_strength = "HIGH"
      }],
      [{
        type            = "PROMPT_ATTACK"
        input_strength  = "HIGH"
        output_strength = "NONE"
      }],
    )
  }

  topic_policy_config = {
    topics_config = [
      {
        name       = "LegalAdvice"
        type       = "DENY"
        definition = "Advice on whether to sue the agency, whether to hire a lawyer, or predictions about winning in court."
        examples   = sort(["Should I sue the agency?", "Do I need a lawyer for this?"])
      },
      {
        name       = "Politics"
        type       = "DENY"
        definition = "Opinions about elected officials, political parties, elections or government policy debates."
        examples   = sort(["What do you think of the new benefits law?", "Who should I vote for?"])
      },
    ]
  }

  # The CloudFormation handler fails with a bare GeneralServiceException unless
  # both lists are present, so the SSN regex also keeps it happy.
  sensitive_information_policy_config = {
    pii_entities_config = [
      for t in ["US_SOCIAL_SECURITY_NUMBER", "US_BANK_ACCOUNT_NUMBER", "CREDIT_DEBIT_CARD_NUMBER", "PASSWORD"] : {
        type   = t
        action = "ANONYMIZE"
      }
    ]
    regexes_config = [{
      name        = "ssn-with-dashes"
      description = "Social Security numbers written as 123-45-6789"
      pattern     = "\\b\\d{3}-\\d{2}-\\d{4}\\b"
      action      = "ANONYMIZE"
    }]
  }
}

# The agent pins published versions of its prompt and guardrail. A change to
# either one cuts a new version and moves the agent to it.
resource "awscc_wisdom_ai_prompt_version" "orchestration" {
  assistant_id          = local.assistant_id
  ai_prompt_id          = awscc_wisdom_ai_prompt.orchestration.ai_prompt_id
  modified_time_seconds = awscc_wisdom_ai_prompt.orchestration.modified_time_seconds

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [awscc_wisdom_ai_prompt.orchestration]
  }
}

resource "awscc_wisdom_ai_guardrail_version" "main" {
  assistant_id          = local.assistant_id
  ai_guardrail_id       = awscc_wisdom_ai_guardrail.main.ai_guardrail_id
  modified_time_seconds = awscc_wisdom_ai_guardrail.main.modified_time_seconds

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [awscc_wisdom_ai_guardrail.main]
  }
}

resource "awscc_wisdom_ai_agent" "orchestration" {
  assistant_id = local.assistant_id
  name         = "${var.name}-agent"
  description  = "Answers program questions, checks case status and hands off to specialists"
  type         = "ORCHESTRATION"

  configuration = {
    orchestration_ai_agent_configuration = {
      connect_instance_arn          = local.instance_arn
      locale                        = "en_US"
      orchestration_ai_prompt_id    = "${awscc_wisdom_ai_prompt.orchestration.ai_prompt_id}:${awscc_wisdom_ai_prompt_version.orchestration.version_number}"
      orchestration_ai_guardrail_id = "${awscc_wisdom_ai_guardrail.main.ai_guardrail_id}:${awscc_wisdom_ai_guardrail_version.main.version_number}"

      tool_configurations = [
        {
          tool_name = "Retrieve"
          tool_type = "MODEL_CONTEXT_PROTOCOL"
          tool_id   = "aws_service__qconnect_Retrieve"
          instruction = {
            instruction = "Search the program and policy articles before answering any question about programs, documents, deadlines, appeals, hours or what a status means. Answer only from what the search returns."
          }
          override_input_values = [{
            json_path = "$.retrievalConfiguration.knowledgeSource.assistantAssociationIds"
            value = {
              constant = {
                type  = "JSON_STRING"
                value = jsonencode([awscc_wisdom_assistant_association.policy.assistant_association_id])
              }
            }
          }]
        },
        {
          tool_name = local.case_tool
          tool_type = "MODEL_CONTEXT_PROTOCOL"
          tool_id   = "gateway_${local.mcp_namespace}__${local.tool_target}___${local.case_tool}"
          instruction = {
            instruction = "Call once you have both the 8 digit case number and the 5 digit ZIP code. Pass digits only."
          }
        },
        {
          tool_name   = "escalate_to_agent"
          tool_type   = "RETURN_TO_CONTROL"
          title       = "Transfer to a specialist"
          description = "Hand the caller to a benefits specialist."
          instruction = {
            instruction = "Call when the caller asks for a person, or needs something only a specialist can do. Say one short sentence that you're connecting them first."
          }
          input_schema = jsonencode({
            type       = "object"
            properties = { reason = { type = "string", description = "Why the caller needs a specialist, in a few words." } }
            required   = ["reason"]
          })
        },
        {
          tool_name   = "end_call"
          tool_type   = "RETURN_TO_CONTROL"
          title       = "End the call"
          description = "Hang up after a clean goodbye."
          instruction = {
            instruction = "Call right after you say goodbye, once the caller has nothing else."
          }
          input_schema = jsonencode({
            type       = "object"
            properties = { reason = { type = "string" } }
          })
        },
      ]
    }
  }

  depends_on = [
    awscc_connect_integration_association.mcp_tools,
    awscc_connect_integration_association.knowledge_base,
  ]
}

# The AI agent's permission to call MCP tools comes from a Connect security
# profile, granted per tool under the integration's namespace.
resource "awscc_connect_security_profile" "ai_agent" {
  instance_arn          = local.instance_arn
  security_profile_name = "${var.name}-ai-agent"
  description           = "Tool access for the ${var.name} AI agent"
  permissions           = ["BasicAgentAccess", "Wisdom.View"]

  applications = [{
    namespace               = local.mcp_namespace
    type                    = "MCP"
    application_permissions = ["${local.tool_target}___${local.case_tool}"]
  }]

  depends_on = [awscc_connect_integration_association.mcp_tools]
}

# Neither provider has a resource for these two yet, so they run through the
# AWS CLI. Both are idempotent and both undo themselves on destroy.
locals {
  agent_security_profile = {
    instance_id = local.instance_id
    profile_id  = element(split("/", awscc_connect_security_profile.ai_agent.security_profile_arn), 3)
    agent_arn   = trimsuffix(awscc_wisdom_ai_agent.orchestration.ai_agent_arn, ":$LATEST")
    env         = local.cli_env
  }

  default_agent = {
    assistant_id = local.assistant_id
    agent_id     = awscc_wisdom_ai_agent.orchestration.ai_agent_id
    env          = local.cli_env
  }
}

resource "terraform_data" "agent_security_profile" {
  input            = local.agent_security_profile
  triggers_replace = local.agent_security_profile

  provisioner "local-exec" {
    environment = self.input.env
    command     = "aws connect associate-security-profiles --instance-id ${self.input.instance_id} --security-profiles Id=${self.input.profile_id} --entity-type AI_AGENT --entity-arn ${self.input.agent_arn} --output text"
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    environment = self.output.env
    command     = "aws connect disassociate-security-profiles --instance-id ${self.output.instance_id} --security-profiles Id=${self.output.profile_id} --entity-type AI_AGENT --entity-arn ${self.output.agent_arn}"
  }
}

# On an assistant this project owns, makes this agent the self-service
# orchestrator. A shared assistant keeps its default, and the flow binds each
# session to this agent instead (bind_agent below).
resource "terraform_data" "default_agent" {
  count = local.create_assistant ? 1 : 0

  input            = local.default_agent
  triggers_replace = local.default_agent

  provisioner "local-exec" {
    environment = self.input.env
    command     = "aws qconnect update-assistant-ai-agent --assistant-id ${self.input.assistant_id} --ai-agent-type ORCHESTRATION --orchestrator-use-case Connect.SelfService --configuration aiAgentId=${self.input.agent_id} --query assistant.assistantId --output text"
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    environment = self.output.env
    command     = "aws qconnect remove-assistant-ai-agent --assistant-id ${self.output.assistant_id} --ai-agent-type ORCHESTRATION --orchestrator-use-case Connect.SelfService --query assistant.assistantId --output text"
  }

  depends_on = [terraform_data.agent_security_profile]
}

data "archive_file" "bind_agent" {
  type        = "zip"
  source_file = "${path.module}/lambda/bind_agent.py"
  output_path = "${path.module}/.build/bind_agent.zip"
}

resource "aws_cloudwatch_log_group" "bind_agent" {
  name              = "/aws/lambda/${var.name}-bind-agent"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_function" "bind_agent" {
  #checkov:skip=CKV_AWS_117:No VPC resources to reach. Access is IAM-scoped to this assistant's sessions.
  #checkov:skip=CKV_AWS_116:Invoked synchronously by Connect, so a DLQ would never receive anything.
  #checkov:skip=CKV_AWS_272:Code signing needs a Signer profile; worth adding for production.

  function_name                  = "${var.name}-bind-agent"
  description                    = "Points each Q in Connect session at the ${var.name} AI agent"
  role                           = aws_iam_role.bind_agent.arn
  runtime                        = "python3.13"
  architectures                  = ["arm64"]
  handler                        = "bind_agent.lambda_handler"
  filename                       = data.archive_file.bind_agent.output_path
  source_code_hash               = data.archive_file.bind_agent.output_base64sha256
  memory_size                    = 256
  timeout                        = 5
  kms_key_arn                    = aws_kms_key.main.arn
  reserved_concurrent_executions = 10

  environment {
    variables = {
      ASSISTANT_ID = local.assistant_id
      AI_AGENT_ID  = "${awscc_wisdom_ai_agent.orchestration.ai_agent_id}:$LATEST"
    }
  }

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = aws_cloudwatch_log_group.bind_agent.name
  }

  tracing_config {
    mode = "Active"
  }
}

resource "aws_iam_role" "bind_agent" {
  name               = "${var.name}-bind-agent"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "bind_agent" {
  statement {
    sid     = "BindSessions"
    actions = ["wisdom:UpdateSession", "wisdom:GetSession"]
    resources = [
      local.assistant_arn,
      "arn:${local.partition}:wisdom:${local.region}:${local.account_id}:session/${local.assistant_id}/*",
    ]
  }

  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.bind_agent.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bind_agent" {
  name   = "runtime"
  role   = aws_iam_role.bind_agent.id
  policy = data.aws_iam_policy_document.bind_agent.json
}

resource "aws_lambda_permission" "bind_agent_from_connect" {
  statement_id   = "AllowConnectInstance"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.bind_agent.function_name
  principal      = "connect.amazonaws.com"
  source_arn     = local.instance_arn
  source_account = local.account_id
}

resource "aws_connect_lambda_function_association" "bind_agent" {
  instance_id  = local.instance_id
  function_arn = aws_lambda_function.bind_agent.arn
}
