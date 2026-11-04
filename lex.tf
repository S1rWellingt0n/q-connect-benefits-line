# The Lex bot is a thin speech layer. Its one real intent hands every turn to
# the Q in Connect assistant. Neither Terraform provider can set the
# assistant on an AMAZON.QInConnectIntent yet, but Lex's import format can, so
# the bot definition is rendered here and imported from S3.

locals {
  bot_name = "${var.name}-bot"

  locale_base = {
    name                   = "English (US)"
    identifier             = "en_US"
    nluConfidenceThreshold = 0.4
  }

  bot_locale_json = var.speech_mode == "nova_sonic" ? jsonencode(merge(local.locale_base, {
    unifiedSpeechSettings = {
      speechFoundationModel = {
        modelArn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/amazon.nova-2-sonic-v1:0"
        voiceId  = lower(var.voice_id)
      }
    }
    })) : jsonencode(merge(local.locale_base, {
    voiceSettings = {
      voiceId = var.voice_id
      engine  = "neural"
    }
  }))

  end_conversation = {
    dialogAction = { type = "EndConversation" }
  }

  q_answers_intent = {
    name                  = "QAnswers"
    parentIntentSignature = "AMAZON.QInConnectIntent"
    qInConnectIntentConfiguration = {
      qInConnectAssistantConfiguration = {
        assistantArn = awscc_wisdom_assistant.main.assistant_arn
      }
    }
    dialogCodeHook = { enabled = false }
    fulfillmentCodeHook = {
      enabled  = false
      isActive = true
      postFulfillmentStatusSpecification = {
        successResponse = {
          allowInterrupt = true
          messageGroupsList = [{
            message = { plainTextMessage = { value = "((x-amz-lex:q-in-connect-response))" } }
          }]
        }
        successNextStep = local.end_conversation
        failureNextStep = local.end_conversation
        timeoutNextStep = local.end_conversation
      }
    }
  }
}

data "archive_file" "lex_bot" {
  type        = "zip"
  output_path = "${path.module}/.build/lex-bot.zip"

  source {
    filename = "Manifest.json"
    content  = jsonencode({ metaData = { schemaVersion = "1", resourceType = "BOT", fileFormat = "LexJson" } })
  }

  source {
    filename = "${local.bot_name}/Bot.json"
    content = jsonencode({
      name                    = local.bot_name
      version                 = "DRAFT"
      description             = "Speech layer for the ${var.name} AI agent"
      dataPrivacy             = { childDirected = false }
      idleSessionTTLInSeconds = 300
    })
  }

  source {
    filename = "${local.bot_name}/BotLocales/en_US/BotLocale.json"
    content  = local.bot_locale_json
  }

  source {
    filename = "${local.bot_name}/BotLocales/en_US/Intents/QAnswers/Intent.json"
    content  = jsonencode(local.q_answers_intent)
  }

  source {
    filename = "${local.bot_name}/BotLocales/en_US/Intents/FallbackIntent/Intent.json"
    content = jsonencode({
      name                  = "FallbackIntent"
      identifier            = "FALLBCKINT"
      parentIntentSignature = "AMAZON.FallbackIntent"
    })
  }
}

resource "aws_s3_object" "lex_bot" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "lex/${local.bot_name}.zip"
  source      = data.archive_file.lex_bot.output_path
  source_hash = data.archive_file.lex_bot.output_base64sha256
}

resource "awscc_lex_bot" "main" {
  name                        = local.bot_name
  description                 = "Speech layer for the ${var.name} AI agent"
  role_arn                    = aws_iam_role.lex.arn
  idle_session_ttl_in_seconds = 300
  auto_build_bot_locales      = true

  data_privacy = {
    child_directed = false
  }

  bot_file_s3_location = {
    s3_bucket         = aws_s3_object.lex_bot.bucket
    s3_object_key     = aws_s3_object.lex_bot.key
    s3_object_version = aws_s3_object.lex_bot.version_id
  }
}

resource "awscc_lex_bot_version" "main" {
  bot_id = awscc_lex_bot.main.bot_id

  bot_version_locale_specification = [{
    locale_id = "en_US"
    bot_version_locale_details = {
      source_bot_version = "DRAFT"
    }
  }]

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [aws_s3_object.lex_bot.version_id]
  }
}

resource "awscc_lex_bot_alias" "live" {
  bot_id         = awscc_lex_bot.main.bot_id
  bot_alias_name = "live"
  bot_version    = awscc_lex_bot_version.main.bot_version

  bot_alias_locale_settings = [{
    locale_id = "en_US"
    bot_alias_locale_setting = {
      enabled = true
    }
  }]

  conversation_log_settings = var.enable_conversation_logs ? {
    text_log_settings = [{
      enabled = true
      destination = {
        cloudwatch = {
          cloudwatch_log_group_arn = aws_cloudwatch_log_group.lex[0].arn
          log_prefix               = "live/"
        }
      }
    }]
  } : null

  depends_on = [aws_iam_role_policy.lex]
}

resource "aws_cloudwatch_log_group" "lex" {
  count = var.enable_conversation_logs ? 1 : 0

  name              = "/aws/lex/${local.bot_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_iam_role" "lex" {
  name               = "${var.name}-lex"
  assume_role_policy = data.aws_iam_policy_document.lex_trust.json
}

data "aws_iam_policy_document" "lex_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lexv2.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "lex" {
  #checkov:skip=CKV_AWS_356:polly:SynthesizeSpeech has no resource-level scoping for voices.

  statement {
    sid       = "Speech"
    actions   = ["polly:SynthesizeSpeech"]
    resources = ["*"]
  }

  statement {
    sid = "AiAgentSession"
    actions = [
      "wisdom:GetAssistant",
      "wisdom:CreateSession",
      "wisdom:GetSession",
      "wisdom:UpdateSession",
      "wisdom:SendMessage",
      "wisdom:GetNextMessage",
      "wisdom:QueryAssistant",
      "wisdom:GetRecommendations",
      "wisdom:PutFeedback",
    ]
    resources = [
      awscc_wisdom_assistant.main.assistant_arn,
      "${awscc_wisdom_assistant.main.assistant_arn}/*",
      "arn:${local.partition}:wisdom:${local.region}:${local.account_id}:session/${awscc_wisdom_assistant.main.assistant_id}/*",
    ]
  }

  statement {
    sid     = "KnowledgeRead"
    actions = ["wisdom:GetKnowledgeBase", "wisdom:SearchContent", "wisdom:GetContent"]
    resources = [
      awscc_wisdom_knowledge_base.policy.knowledge_base_arn,
      "${awscc_wisdom_knowledge_base.policy.knowledge_base_arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.enable_conversation_logs ? [1] : []

    content {
      sid       = "ConversationLogs"
      actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      resources = ["${aws_cloudwatch_log_group.lex[0].arn}:*"]
    }
  }
}

resource "aws_iam_role_policy" "lex" {
  name   = "runtime"
  role   = aws_iam_role.lex.id
  policy = data.aws_iam_policy_document.lex.json
}
