output "instance_url" {
  description = "Connect admin website for the new instance."
  value       = local.instance_url
}

output "instance_id" {
  value = local.instance_id
}

output "contact_flow_id" {
  value = aws_connect_contact_flow.benefits_line.contact_flow_id
}

output "phone_number" {
  description = "The line's number, when claim_phone_number is true."
  value       = var.claim_phone_number ? aws_connect_phone_number.main[0].phone_number : null
}

output "assistant_id" {
  value = local.assistant_id
}

output "ai_agent_id" {
  value = awscc_wisdom_ai_agent.orchestration.ai_agent_id
}

output "gateway_url" {
  description = "MCP endpoint of the AgentCore gateway."
  value       = aws_bedrockagentcore_gateway.tools.gateway_url
}

output "lex_bot_alias_arn" {
  value = awscc_lex_bot_alias.live.arn
}
