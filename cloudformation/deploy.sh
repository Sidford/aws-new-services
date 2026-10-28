#!/usr/bin/env bash
# deploy.sh — deploy the AWS Service Monitor CloudFormation stack
#
# The Lambda function code is embedded directly in template.yaml (ZipFile).
# No separate Lambda packaging or S3 Lambda bucket is required.
#
# Because the template exceeds CloudFormation's 51 KB direct-upload limit the
# script uploads template.yaml to a temporary S3 key and deploys via --template-url.
# The same S3 bucket is reused across deployments and can be deleted afterwards.
#
# Usage:
#   ./cloudformation/deploy.sh [options]
#
# Options:
#   --stack-name NAME       Stack name                  (default: aws-service-monitor)
#   --region REGION         Deployment region           (default: eu-west-2)
#   --deploy-bucket BUCKET  S3 bucket for the template  (auto-created if omitted)
#   --email EMAILS          JSON array of recipients    (e.g. '["ops@example.com"]')
#   --sender EMAIL          SES verified sender address
#   --no-approve            Skip change-set approval prompt (CI mode)
#   --help                  Show this help
#
# All parameters can also be set via environment variables:
#   STACK_NAME, DEPLOY_REGION, DEPLOY_BUCKET, EMAIL_RECIPIENTS, SENDER_EMAIL
#
set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
STACK_NAME="${STACK_NAME:-aws-service-monitor}"
DEPLOY_REGION="${DEPLOY_REGION:-eu-west-2}"
DEPLOY_BUCKET="${DEPLOY_BUCKET:-}"
EMAIL_RECIPIENTS="${EMAIL_RECIPIENTS:-}"
SENDER_EMAIL="${SENDER_EMAIL:-}"
NO_APPROVE=false

TEMPLATE_S3_KEY="aws-service-monitor/template.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --stack-name)    STACK_NAME="$2";       shift 2 ;;
    --region)        DEPLOY_REGION="$2";    shift 2 ;;
    --deploy-bucket) DEPLOY_BUCKET="$2";    shift 2 ;;
    --email)         EMAIL_RECIPIENTS="$2"; shift 2 ;;
    --sender)        SENDER_EMAIL="$2";     shift 2 ;;
    --no-approve)    NO_APPROVE=true;       shift ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) error "Unknown option: $1" ;;
  esac
done

# ── prerequisites ─────────────────────────────────────────────────────────────
for cmd in aws; do
  command -v "$cmd" &>/dev/null || error "'$cmd' is required but not found in PATH"
done

# ── interactive prompts if required values are missing ───────────────────────
if [[ -z "$DEPLOY_BUCKET" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  DEPLOY_BUCKET="aws-service-monitor-deploy-${ACCOUNT_ID}-${DEPLOY_REGION}"
  warn "No --deploy-bucket specified; will use: ${DEPLOY_BUCKET}"
fi

if [[ -z "$EMAIL_RECIPIENTS" ]]; then
  read -rp "Email recipients (JSON array, e.g. [\"ops@example.com\"]): " EMAIL_RECIPIENTS
fi

if [[ -z "$SENDER_EMAIL" ]]; then
  read -rp "Sender email (must be verified in SES): " SENDER_EMAIL
fi

# Basic validation — must look like a JSON array of quoted strings
if [[ ! "$EMAIL_RECIPIENTS" =~ ^\[\".*\"\]$ ]]; then
  error "EMAIL_RECIPIENTS must be a JSON array, e.g. [\"ops@example.com\"]"
fi

# ── create / verify deployment S3 bucket ─────────────────────────────────────
if aws s3api head-bucket --bucket "$DEPLOY_BUCKET" --region "$DEPLOY_REGION" 2>/dev/null; then
  info "Deployment bucket exists: s3://${DEPLOY_BUCKET}"
else
  info "Creating deployment bucket: s3://${DEPLOY_BUCKET}"
  if [[ "$DEPLOY_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$DEPLOY_BUCKET" \
      --region "$DEPLOY_REGION"
  else
    aws s3api create-bucket \
      --bucket "$DEPLOY_BUCKET" \
      --region "$DEPLOY_REGION" \
      --create-bucket-configuration LocationConstraint="$DEPLOY_REGION"
  fi
  # Block public access on the new bucket
  aws s3api put-public-access-block \
    --bucket "$DEPLOY_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  success "Deployment bucket created"
fi

# ── upload template to S3 ────────────────────────────────────────────────────
# CloudFormation's --template-body limit is 51 KB; the embedded-Lambda template
# is ~105 KB, so we must use --template-url from S3 instead.
info "Uploading template → s3://${DEPLOY_BUCKET}/${TEMPLATE_S3_KEY}"
aws s3 cp "${SCRIPT_DIR}/template.yaml" \
  "s3://${DEPLOY_BUCKET}/${TEMPLATE_S3_KEY}" \
  --region "$DEPLOY_REGION"
TEMPLATE_URL="https://s3.amazonaws.com/${DEPLOY_BUCKET}/${TEMPLATE_S3_KEY}"
success "Template uploaded"

# ── validate template ─────────────────────────────────────────────────────────
info "Validating CloudFormation template..."
aws cloudformation validate-template \
  --template-url "$TEMPLATE_URL" \
  --region "$DEPLOY_REGION" \
  --output table
success "Template is valid"

# ── deploy stack via change-set ───────────────────────────────────────────────
CS_NAME="${STACK_NAME}-$(date +%Y%m%d%H%M%S)"

# Determine whether this is a CREATE or UPDATE
CHANGE_SET_TYPE="CREATE"
if aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$DEPLOY_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null | grep -q 'COMPLETE'; then
  CHANGE_SET_TYPE="UPDATE"
fi

info "Creating change-set '${CS_NAME}' (${CHANGE_SET_TYPE})..."
aws cloudformation create-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CS_NAME" \
  --template-url "$TEMPLATE_URL" \
  --parameters \
    "ParameterKey=EmailRecipients,ParameterValue=${EMAIL_RECIPIENTS}" \
    "ParameterKey=SenderEmail,ParameterValue=${SENDER_EMAIL}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$DEPLOY_REGION" \
  --change-set-type "$CHANGE_SET_TYPE"

info "Waiting for change-set to be ready..."
aws cloudformation wait change-set-create-complete \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CS_NAME" \
  --region "$DEPLOY_REGION"

echo ""
info "Change-set summary:"
aws cloudformation describe-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CS_NAME" \
  --region "$DEPLOY_REGION" \
  --query 'Changes[].{Action:ResourceChange.Action,Resource:ResourceChange.LogicalResourceId,Type:ResourceChange.ResourceType}' \
  --output table

if [[ "$NO_APPROVE" == false ]]; then
  echo ""
  read -rp "Apply this change-set? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    warn "Deployment cancelled. Deleting change-set."
    aws cloudformation delete-change-set \
      --stack-name "$STACK_NAME" \
      --change-set-name "$CS_NAME" \
      --region "$DEPLOY_REGION"
    exit 0
  fi
fi

info "Executing change-set..."
aws cloudformation execute-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CS_NAME" \
  --region "$DEPLOY_REGION"

info "Waiting for stack operation to complete (this may take a few minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name "$STACK_NAME" \
  --region "$DEPLOY_REGION" 2>/dev/null || \
aws cloudformation wait stack-update-complete \
  --stack-name "$STACK_NAME" \
  --region "$DEPLOY_REGION" 2>/dev/null || true

STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$DEPLOY_REGION" \
  --query 'Stacks[0].StackStatus' \
  --output text)

if [[ "$STATUS" == *"COMPLETE"* && "$STATUS" != *"ROLLBACK"* ]]; then
  success "Stack '${STACK_NAME}' deployed successfully (${STATUS})"
else
  error "Stack ended in unexpected state: ${STATUS}"
fi

# ── print outputs ─────────────────────────────────────────────────────────────
echo ""
info "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$DEPLOY_REGION" \
  --query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
  --output table

echo ""
success "Deployment complete!"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Confirm subscription emails sent to: ${EMAIL_RECIPIENTS}"
echo "  2. Verify the sender address in SES if you haven't already:"
echo "       aws ses verify-email-identity --email-address ${SENDER_EMAIL} --region ${DEPLOY_REGION}"
echo "  3. Test by invoking the Lambda manually:"
echo "       aws lambda invoke --function-name aws-service-monitor --region ${DEPLOY_REGION} response.json && cat response.json"
echo "  4. Check logs:"
echo "       aws logs tail /aws/lambda/aws-service-monitor --region ${DEPLOY_REGION} --follow"
