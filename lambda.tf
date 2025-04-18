#####################################################################################
# LAMBDA
#####################################################################################

resource "terraform_data" "bootstrap" {
  provisioner "local-exec" {
    command = "cd ${path.module} && make build"
  }
}

################# Run task EventBridge ##################
resource "aws_lambda_function" "runtask_eventbridge" {
  function_name    = "${local.solution_prefix}-runtask-eventbridge"
  description      = "HCP Terraform run task - EventBridge handler"
  role             = aws_iam_role.runtask_eventbridge.arn
  architectures    = local.lambda_architecture
  source_code_hash = data.archive_file.runtask_eventbridge.output_base64sha256
  filename         = data.archive_file.runtask_eventbridge.output_path
  handler          = "handler.lambda_handler"
  runtime          = local.lambda_python_runtime
  timeout          = local.lambda_default_timeout
  environment {
    variables = {
      HCP_TF_HMAC_SECRET_ARN = aws_secretsmanager_secret.runtask_hmac.arn
      HCP_TF_USE_WAF         = var.deploy_waf ? "True" : "False"
      HCP_TF_CF_SECRET_ARN   = var.deploy_waf ? aws_secretsmanager_secret.runtask_cloudfront[0].arn : null
      HCP_TF_CF_SIGNATURE    = var.deploy_waf ? local.cloudfront_sig_name : null
      EVENT_BUS_NAME         = var.event_bus_name
      EVENT_RULE_DETAIL_TYPE = local.solution_prefix # ensure uniqueness of event sent to each runtask state machine
    }
  }
  tracing_config {
    mode = "Active"
  }
  reserved_concurrent_executions = local.lambda_reserved_concurrency
  tags                           = local.combined_tags
  #checkov:skip=CKV_AWS_116:not using DLQ
  #checkov:skip=CKV_AWS_117:VPC is not required
  #checkov:skip=CKV_AWS_173:non sensitive environment variables
  #checkov:skip=CKV_AWS_272:skip code-signing
}

resource "aws_lambda_function_url" "runtask_eventbridge" {
  function_name      = aws_lambda_function.runtask_eventbridge.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_lambda_permission" "runtask_eventbridge" {
  count         = local.waf_deployment
  statement_id  = "AllowCloudFrontToFunctionUrl"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.runtask_eventbridge.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = module.runtask_cloudfront[count.index].cloudfront_distribution_arn
}

resource "aws_cloudwatch_log_group" "runtask_eventbridge" {
  name              = "/aws/lambda/${aws_lambda_function.runtask_eventbridge.function_name}"
  retention_in_days = var.cloudwatch_log_group_retention
  kms_key_id        = aws_kms_key.runtask_key.arn
  tags              = local.combined_tags
}

################# Run task request ##################
resource "aws_lambda_function" "runtask_request" {
  function_name                  = "${local.solution_prefix}-runtask-request"
  description                    = "HCP Terraform run task - Request handler"
  role                           = aws_iam_role.runtask_request.arn
  architectures                  = local.lambda_architecture
  source_code_hash               = data.archive_file.runtask_request.output_base64sha256
  filename                       = data.archive_file.runtask_request.output_path
  handler                        = "handler.lambda_handler"
  runtime                        = local.lambda_python_runtime
  timeout                        = local.lambda_default_timeout
  reserved_concurrent_executions = local.lambda_reserved_concurrency
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      HCP_TF_ORG             = var.hcp_tf_org
      RUNTASK_STAGES         = join(",", var.runtask_stages)
      WORKSPACE_PREFIX       = length(var.workspace_prefix) > 0 ? var.workspace_prefix : null
      EVENT_RULE_DETAIL_TYPE = local.solution_prefix # ensure uniqueness of event sent to each runtask state machine
    }
  }
  tags = local.combined_tags
  #checkov:skip=CKV_AWS_116:not using DLQ
  #checkov:skip=CKV_AWS_117:VPC is not required
  #checkov:skip=CKV_AWS_173:no sensitive data in env var
  #checkov:skip=CKV_AWS_272:skip code-signing
}

resource "aws_cloudwatch_log_group" "runtask_request" {
  name              = "/aws/lambda/${aws_lambda_function.runtask_request.function_name}"
  retention_in_days = var.cloudwatch_log_group_retention
  kms_key_id        = aws_kms_key.runtask_key.arn
  tags              = local.combined_tags
}

################# Run task callback ##################
resource "aws_lambda_function" "runtask_callback" {
  function_name                  = "${local.solution_prefix}-runtask-callback"
  description                    = "HCP Terraform run task - Callback handler"
  role                           = aws_iam_role.runtask_callback.arn
  architectures                  = local.lambda_architecture
  source_code_hash               = data.archive_file.runtask_callback.output_base64sha256
  filename                       = data.archive_file.runtask_callback.output_path
  handler                        = "handler.lambda_handler"
  runtime                        = local.lambda_python_runtime
  timeout                        = local.lambda_default_timeout
  reserved_concurrent_executions = local.lambda_reserved_concurrency
  tracing_config {
    mode = "Active"
  }
  tags = local.combined_tags
  #checkov:skip=CKV_AWS_116:not using DLQ
  #checkov:skip=CKV_AWS_117:VPC is not required
  #checkov:skip=CKV_AWS_272:skip code-signing
}

resource "aws_cloudwatch_log_group" "runtask_callback" {
  name              = "/aws/lambda/${aws_lambda_function.runtask_callback.function_name}"
  retention_in_days = var.cloudwatch_log_group_retention
  kms_key_id        = aws_kms_key.runtask_key.arn
  tags              = local.combined_tags
}

################# Run task Edge ##################
resource "aws_lambda_function" "runtask_edge" {
  provider                       = aws.cloudfront_waf # Lambda@Edge must be in us-east-1
  function_name                  = "${local.solution_prefix}-runtask-edge"
  description                    = "HCP Terraform run task - Lambda@Edge handler"
  role                           = aws_iam_role.runtask_edge.arn
  architectures                  = local.lambda_architecture
  source_code_hash               = data.archive_file.runtask_edge.output_base64sha256
  filename                       = data.archive_file.runtask_edge.output_path
  handler                        = "handler.lambda_handler"
  runtime                        = local.lambda_python_runtime
  timeout                        = 5 # Lambda@Edge max timout is 5
  reserved_concurrent_executions = local.lambda_reserved_concurrency
  publish                        = true # Lambda@Edge must be published
  tags                           = local.combined_tags
  #checkov:skip=CKV_AWS_116:not using DLQ
  #checkov:skip=CKV_AWS_117:VPC is not required
  #checkov:skip=CKV_AWS_173:no sensitive data in env var
  #checkov:skip=CKV_AWS_272:skip code-signing
  #checkov:skip=CKV_AWS_50:no x-ray for lambda@edge
}

################# Run task Fulfillment ##################
resource "aws_lambda_function" "runtask_fulfillment" {
  function_name                  = "${local.solution_prefix}-runtask-fulfillment"
  description                    = "HCP Terraform run task - Fulfillment handler"
  role                           = aws_iam_role.runtask_fulfillment.arn
  architectures                  = local.lambda_architecture
  source_code_hash               = data.archive_file.runtask_fulfillment.output_base64sha256
  filename                       = data.archive_file.runtask_fulfillment.output_path
  handler                        = "handler.lambda_handler"
  runtime                        = local.lambda_python_runtime
  timeout                        = local.lambda_default_timeout
  reserved_concurrent_executions = local.lambda_reserved_concurrency
  tracing_config {
    mode = "Active"
  }
  environment {
    variables = {
      CW_LOG_GROUP_NAME         = local.cloudwatch_log_group_name
      BEDROCK_LLM_MODEL         = var.bedrock_llm_model
      BEDROCK_GUARDRAIL_ID      = aws_bedrock_guardrail.runtask_fulfillment.guardrail_id
      BEDROCK_GUARDRAIL_VERSION = aws_bedrock_guardrail_version.runtask_fulfillment.version
    }
  }
  tags = local.combined_tags
  #checkov:skip=CKV_AWS_116:not using DLQ
  #checkov:skip=CKV_AWS_117:VPC is not required
  #checkov:skip=CKV_AWS_173:no sensitive data in env var
  #checkov:skip=CKV_AWS_272:skip code-signing
}

resource "aws_cloudwatch_log_group" "runtask_fulfillment" {
  name              = "/aws/lambda/${aws_lambda_function.runtask_fulfillment.function_name}"
  retention_in_days = var.cloudwatch_log_group_retention
  kms_key_id        = aws_kms_key.runtask_key.arn
  tags              = local.combined_tags
}

resource "aws_cloudwatch_log_group" "runtask_fulfillment_output" {
  name              = var.cloudwatch_log_group_name
  retention_in_days = var.cloudwatch_log_group_retention
  kms_key_id        = aws_kms_key.runtask_key.arn
  tags              = local.combined_tags
}