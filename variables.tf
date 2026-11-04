variable "region" {
  description = "AWS region. Needs Amazon Connect, Q in Connect and AgentCore Gateway."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "benefits-line"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "Use 3 to 31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "existing_instance_id" {
  description = "Deploy into this Connect instance instead of creating one."
  type        = string
  default     = null
}

variable "existing_assistant_id" {
  description = "Use this Q in Connect assistant, already associated with existing_instance_id, instead of creating one. Needed when the instance already has an assistant, since an instance takes only one."
  type        = string
  default     = null

  validation {
    condition     = var.existing_assistant_id == null || var.existing_instance_id != null
    error_message = "existing_assistant_id needs existing_instance_id, the instance the assistant is associated with."
  }
}

variable "aws_profile" {
  description = "Named AWS CLI profile for the two steps that run through the CLI. Leave null to use the default credential chain."
  type        = string
  default     = null
}

variable "model_id" {
  description = "Bedrock model the AI agent reasons with."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "speech_mode" {
  description = "polly uses Lex speech recognition with a Polly voice. nova_sonic uses Amazon Nova Sonic speech to speech, which needs an instance entitled to Connect's AI features."
  type        = string
  default     = "polly"

  validation {
    condition     = contains(["polly", "nova_sonic"], var.speech_mode)
    error_message = "speech_mode must be polly or nova_sonic."
  }
}

variable "voice_id" {
  description = "Voice for the agent and the flow prompts."
  type        = string
  default     = "Matthew"
}

variable "time_zone" {
  description = "Time zone for the specialists' hours."
  type        = string
  default     = "America/Chicago"
}

variable "claim_phone_number" {
  description = "Claim a DID and point it at the flow. Costs about a dollar a month plus per-minute charges."
  type        = bool
  default     = false
}

variable "phone_country_code" {
  description = "Country for the claimed number."
  type        = string
  default     = "US"
}

variable "enable_conversation_logs" {
  description = "Write Lex conversation text logs. They contain what callers say, so they're off by default."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for every log group this project creates."
  type        = number
  default     = 365
}

variable "tool_concurrency_limit" {
  description = "Reserved concurrency for the tool Lambda. Caps cost and load if something loops."
  type        = number
  default     = 20
}

variable "daily_contact_limit" {
  description = "Contacts allowed per UTC day. Past it, callers hear a closing message and nothing billable runs."
  type        = number
  default     = 20
}

variable "max_contact_minutes" {
  description = "Longest a contact may run before the sweep ends it."
  type        = number
  default     = 8
}

variable "alarm_email" {
  description = "Email that gets alarm notifications. Leave null to skip the subscription."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource that supports default tags."
  type        = map(string)
  default = {
    project = "q-connect-benefits-line"
  }
}
