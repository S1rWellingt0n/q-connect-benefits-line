resource "aws_s3_bucket" "knowledge" {
  bucket        = "${var.name}-knowledge-${local.account_id}-${local.region}"
  force_destroy = true

  #checkov:skip=CKV_AWS_18:Access logging needs a separate log bucket; worth adding for production.
  #checkov:skip=CKV_AWS_144:Content is rebuilt from this repo, so cross-region replication adds cost without recovery value.
  #checkov:skip=CKV2_AWS_62:Nothing consumes object events.
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${local.account_id}-${local.region}"
  force_destroy = true

  #checkov:skip=CKV_AWS_18:Access logging needs a separate log bucket; worth adding for production.
  #checkov:skip=CKV_AWS_144:Content is rebuilt from this repo, so cross-region replication adds cost without recovery value.
  #checkov:skip=CKV2_AWS_62:Nothing consumes object events.
}

locals {
  buckets = {
    knowledge = aws_s3_bucket.knowledge
    artifacts = aws_s3_bucket.artifacts
  }
}

resource "aws_s3_bucket_versioning" "all" {
  for_each = local.buckets
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "all" {
  for_each = local.buckets
  bucket   = each.value.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "all" {
  for_each = local.buckets
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "all" {
  for_each = local.buckets
  bucket   = each.value.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "knowledge" {
  bucket = aws_s3_bucket.knowledge.id
  policy = data.aws_iam_policy_document.knowledge_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.all]
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.tls_only["artifacts"].json

  depends_on = [aws_s3_bucket_public_access_block.all]
}

data "aws_iam_policy_document" "tls_only" {
  for_each = local.buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "knowledge_bucket" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["knowledge"].json]

  statement {
    sid       = "KnowledgeIngestion"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.knowledge.arn, "${aws_s3_bucket.knowledge.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["app-integrations.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_object" "knowledge" {
  for_each = fileset("${path.module}/knowledge", "*.html")

  bucket       = aws_s3_bucket.knowledge.id
  key          = each.value
  source       = "${path.module}/knowledge/${each.value}"
  source_hash  = filemd5("${path.module}/knowledge/${each.value}")
  content_type = "text/html"

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.all]
}

resource "awscc_appintegrations_data_integration" "knowledge" {
  name        = "${var.name}-knowledge"
  description = "Program and policy articles for the ${var.name} AI agent"
  source_uri  = "s3://${aws_s3_bucket.knowledge.id}"
  kms_key     = aws_kms_key.main.arn

  depends_on = [aws_s3_bucket_policy.knowledge]
}

resource "awscc_wisdom_knowledge_base" "policy" {
  name                = "${var.name}-knowledge"
  description         = "Program and policy articles"
  knowledge_base_type = "EXTERNAL"

  source_configuration = {
    app_integrations = {
      app_integration_arn = awscc_appintegrations_data_integration.knowledge.data_integration_arn
    }
  }

  depends_on = [aws_s3_object.knowledge]
}

resource "awscc_wisdom_assistant_association" "policy" {
  assistant_id     = awscc_wisdom_assistant.main.assistant_id
  association_type = "KNOWLEDGE_BASE"

  association = {
    knowledge_base_id = awscc_wisdom_knowledge_base.policy.knowledge_base_id
  }
}
