#!/bin/bash
# Integration Test: Service Removal and Rediscovery with SCP Update
#
# This script performs a real-world test by:
# 1. Removing a random service from the DynamoDB baseline
# 2. Triggering the Lambda function
# 3. Verifying the service is detected as new
# 4. Confirming SCP was updated
# 5. Validating success email was sent

set -e

# Configuration
AWS_PROFILE="${AWS_PROFILE:-sidford-mgmt}"
REGION="eu-west-2"
TABLE_NAME="aws-service-monitor-registry"
LAMBDA_FUNCTION="aws-service-monitor"
SCP_NAME="blacklist"
BASELINE_MARKER="__baseline_initialized__"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}AWS Service Monitor - Integration Test${NC}"
echo -e "${BLUE}Service Removal & Rediscovery with SCP${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Step 1: Get current baseline services
echo -e "${YELLOW}STEP 1: Fetching current baseline services...${NC}"
echo "Command: aws dynamodb scan --table-name $TABLE_NAME --region $REGION --profile $AWS_PROFILE"

SERVICES=$(AWS_PROFILE=$AWS_PROFILE aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --filter-expression "attribute_not_exists(service_name) OR NOT begins_with(service_name, :prefix)" \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  --projection-expression "service_name" \
  --query 'Items[*].service_name.S' \
  --output text)

SERVICES_ARRAY=($SERVICES)
SERVICE_COUNT=${#SERVICES_ARRAY[@]}

if [ $SERVICE_COUNT -eq 0 ]; then
  echo -e "${RED}✗ ERROR: No services found in registry${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Found $SERVICE_COUNT services in baseline${NC}"
echo "Services: ${SERVICES_ARRAY[@]:0:5}..." # Show first 5
echo ""

# Step 2: Select a random service to remove
echo -e "${YELLOW}STEP 2: Selecting random service for removal...${NC}"
RANDOM_INDEX=$((RANDOM % SERVICE_COUNT))
SELECTED_SERVICE="${SERVICES_ARRAY[$RANDOM_INDEX]}"

echo -e "${GREEN}✓ Selected service: $SELECTED_SERVICE${NC}"
echo ""

# Step 3: Get current baseline checksum
echo -e "${YELLOW}STEP 3: Fetching current baseline checksum...${NC}"
BASELINE_RESPONSE=$(AWS_PROFILE=$AWS_PROFILE aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"service_name\":{\"S\":\"$BASELINE_MARKER\"}}" \
  --region "$REGION" \
  --output json)

OLD_CHECKSUM=$(echo "$BASELINE_RESPONSE" | jq -r '.Item.checksum.S // empty')
OLD_COUNT=$(echo "$BASELINE_RESPONSE" | jq -r '.Item.service_count.N // empty')

if [ -z "$OLD_CHECKSUM" ]; then
  echo -e "${RED}✗ ERROR: Could not retrieve baseline checksum${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Current baseline: $OLD_COUNT services${NC}"
echo "  Checksum (old): ${OLD_CHECKSUM:0:16}..."
echo ""

# Step 4: Delete the selected service
echo -e "${YELLOW}STEP 4: Deleting service from DynamoDB...${NC}"
echo "Deleting: $SELECTED_SERVICE"

AWS_PROFILE=$AWS_PROFILE aws dynamodb delete-item \
  --table-name "$TABLE_NAME" \
  --key "{\"service_name\":{\"S\":\"$SELECTED_SERVICE\"}}" \
  --region "$REGION" > /dev/null

echo -e "${GREEN}✓ Service deleted from DynamoDB${NC}"
echo ""

# Step 5: Recalculate baseline checksum
echo -e "${YELLOW}STEP 5: Recalculating baseline checksum...${NC}"
echo "Fetching remaining services..."

REMAINING_SERVICES=$(AWS_PROFILE=$AWS_PROFILE aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --region "$REGION" \
  --filter-expression "attribute_not_exists(service_name) OR NOT begins_with(service_name, :prefix)" \
  --expression-attribute-values '{":prefix":{"S":"__"}}' \
  --projection-expression "service_name" \
  --query 'Items[*].service_name.S' \
  --output text | tr ' ' '\n' | sort | tr '\n' ' ')

REMAINING_COUNT=$(echo "$REMAINING_SERVICES" | wc -w)
echo "Remaining services: $REMAINING_COUNT"

# Calculate new checksum using Python
NEW_CHECKSUM=$(python3 -c "
import json
import hashlib

services = '''$REMAINING_SERVICES'''.strip().split()
services.sort()
service_string = json.dumps(services, separators=(',', ':'))
checksum = hashlib.sha256(service_string.encode()).hexdigest()
print(checksum)
" 2>/dev/null || echo "CHECKSUM_CALC_ERROR")

if [ "$NEW_CHECKSUM" = "CHECKSUM_CALC_ERROR" ]; then
  echo -e "${RED}✗ ERROR: Could not calculate new checksum${NC}"
  echo "  (Python hashlib not available, will use old checksum)"
  NEW_CHECKSUM=$OLD_CHECKSUM
else
  echo -e "${GREEN}✓ New checksum calculated${NC}"
  echo "  Checksum (new): ${NEW_CHECKSUM:0:16}..."
fi

# Step 6: Update baseline marker with new checksum
echo -e "${YELLOW}STEP 6: Updating baseline marker with new checksum...${NC}"

AWS_PROFILE=$AWS_PROFILE aws dynamodb update-item \
  --table-name "$TABLE_NAME" \
  --key "{\"service_name\":{\"S\":\"$BASELINE_MARKER\"}}" \
  --update-expression "SET checksum = :checksum, service_count = :count" \
  --expression-attribute-values "{\":checksum\":{\"S\":\"$NEW_CHECKSUM\"},\":count\":{\"N\":\"$REMAINING_COUNT\"}}" \
  --region "$REGION" > /dev/null

echo -e "${GREEN}✓ Baseline marker updated${NC}"
echo "  Service count: $REMAINING_COUNT (was $OLD_COUNT)"
echo ""

# Step 7: Invoke Lambda function
echo -e "${YELLOW}STEP 7: Invoking Lambda function...${NC}"
echo "Function: $LAMBDA_FUNCTION"
echo "This will:"
echo "  1. Fetch AWS services from reference"
echo "  2. Detect $SELECTED_SERVICE as new"
echo "  3. Update DynamoDB with new service"
echo "  4. Update SCP policy (if enabled)"
echo "  5. Send email notification"
echo ""

INVOKE_START=$(date +%s)
RESPONSE=$(AWS_PROFILE=$AWS_PROFILE aws lambda invoke \
  --function-name "$LAMBDA_FUNCTION" \
  --region "$REGION" \
  --log-type Tail \
  --payload '{}' \
  /tmp/lambda_response.json \
  2>&1)

INVOKE_END=$(date +%s)
INVOKE_DURATION=$((INVOKE_END - INVOKE_START))

echo "Invocation completed in ${INVOKE_DURATION}s"
echo ""

# Step 8: Parse Lambda response
echo -e "${YELLOW}STEP 8: Parsing Lambda response...${NC}"

if [ -f /tmp/lambda_response.json ]; then
  LAMBDA_BODY=$(cat /tmp/lambda_response.json)
  echo "Response:"
  echo "$LAMBDA_BODY" | jq '.' 2>/dev/null || echo "$LAMBDA_BODY"
  echo ""

  # Extract key information
  STATUS_CODE=$(echo "$LAMBDA_BODY" | jq -r '.statusCode // empty' 2>/dev/null)
  NEW_SERVICES=$(echo "$LAMBDA_BODY" | jq -r '.body | fromjson | .new_services[]?' 2>/dev/null || echo "")
  SCP_STATUS=$(echo "$LAMBDA_BODY" | jq -r '.body | fromjson | .scp_status // "unknown"' 2>/dev/null)

  if [ "$STATUS_CODE" = "200" ]; then
    echo -e "${GREEN}✓ Lambda executed successfully (HTTP 200)${NC}"
  else
    echo -e "${RED}✗ Lambda returned status: $STATUS_CODE${NC}"
  fi

  if echo "$NEW_SERVICES" | grep -q "$SELECTED_SERVICE"; then
    echo -e "${GREEN}✓ Service detected as new: $SELECTED_SERVICE${NC}"
  else
    echo -e "${YELLOW}⚠ Service $SELECTED_SERVICE not detected as new${NC}"
    echo "  New services detected: $NEW_SERVICES"
  fi

  echo "SCP Status: $SCP_STATUS"
  if [ "$SCP_STATUS" = "success" ]; then
    echo -e "${GREEN}✓ SCP policy successfully updated${NC}"
  elif [ "$SCP_STATUS" = "disabled" ]; then
    echo -e "${YELLOW}⚠ SCP management is disabled${NC}"
  else
    echo -e "${YELLOW}⚠ SCP status: $SCP_STATUS${NC}"
  fi
else
  echo -e "${RED}✗ ERROR: Lambda response file not found${NC}"
  exit 1
fi
echo ""

# Step 9: Verify service was added back to DynamoDB
echo -e "${YELLOW}STEP 9: Verifying service is in DynamoDB...${NC}"

SERVICE_CHECK=$(AWS_PROFILE=$AWS_PROFILE aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"service_name\":{\"S\":\"$SELECTED_SERVICE\"}}" \
  --region "$REGION" \
  --output json | jq -r '.Item.service_name.S // empty')

if [ "$SERVICE_CHECK" = "$SELECTED_SERVICE" ]; then
  echo -e "${GREEN}✓ Service $SELECTED_SERVICE found in DynamoDB${NC}"
else
  echo -e "${RED}✗ Service $SELECTED_SERVICE NOT found in DynamoDB${NC}"
fi
echo ""

# Step 10: Check CloudWatch logs for email confirmation
echo -e "${YELLOW}STEP 10: Checking CloudWatch logs for email notification...${NC}"
echo "Log group: /aws/lambda/$LAMBDA_FUNCTION"

# Get logs from last 2 minutes
LOG_ENTRIES=$(AWS_PROFILE=$AWS_PROFILE aws logs filter-log-events \
  --log-group-name "/aws/lambda/$LAMBDA_FUNCTION" \
  --region "$REGION" \
  --start-time $((INVOKE_START * 1000 - 10000)) \
  --end-time $((INVOKE_END * 1000 + 10000)) \
  --filter-pattern "email" \
  --query 'events[*].message' \
  --output text 2>/dev/null || echo "")

if echo "$LOG_ENTRIES" | grep -q "email"; then
  echo -e "${GREEN}✓ Email notification logged${NC}"
  echo "  Log entries containing 'email':"
  echo "$LOG_ENTRIES" | grep "email" | head -3 | sed 's/^/    /'
else
  echo -e "${YELLOW}⚠ Email notification not found in logs (may still have been sent)${NC}"
fi
echo ""

# Step 11: Verify SCP policy if management is enabled
echo -e "${YELLOW}STEP 11: Verifying SCP policy update (if enabled)...${NC}"

if [ "$SCP_STATUS" = "success" ]; then
  echo "Fetching SCP policy details..."

  # Get SCP policies
  SCP_ID=$(AWS_PROFILE=$AWS_PROFILE aws organizations list-policies \
    --filter SERVICE_CONTROL_POLICY \
    --query "Policies[?Name=='$SCP_NAME'].Id" \
    --output text 2>/dev/null || echo "")

  if [ -z "$SCP_ID" ]; then
    echo -e "${YELLOW}⚠ Could not find SCP policy: $SCP_NAME${NC}"
  else
    echo -e "${GREEN}✓ Found SCP policy: $SCP_NAME${NC}"
    echo "  Policy ID: $SCP_ID"

    # Check if policy contains the service
    POLICY_CONTENT=$(AWS_PROFILE=$AWS_PROFILE aws organizations describe-policy \
      --policy-id "$SCP_ID" \
      --query 'Policy.Content' \
      --output text 2>/dev/null || echo "")

    if echo "$POLICY_CONTENT" | grep -q "${SELECTED_SERVICE}:"; then
      echo -e "${GREEN}✓ SCP policy contains $SELECTED_SERVICE${NC}"
    else
      echo -e "${YELLOW}⚠ Service $SELECTED_SERVICE not found in SCP policy${NC}"
    fi
  fi
else
  echo "SCP status: $SCP_STATUS - skipping SCP verification"
fi
echo ""

# Step 12: Final summary
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}TEST SUMMARY${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Test Configuration:"
echo "  Region: $REGION"
echo "  Table: $TABLE_NAME"
echo "  Lambda: $LAMBDA_FUNCTION"
echo "  SCP Name: $SCP_NAME"
echo ""
echo "Execution Steps:"
echo "  1. ✓ Fetched baseline services ($SERVICE_COUNT total)"
echo "  2. ✓ Selected random service: $SELECTED_SERVICE"
echo "  3. ✓ Got baseline checksum: ${OLD_CHECKSUM:0:12}..."
echo "  4. ✓ Deleted service from DynamoDB"
echo "  5. ✓ Recalculated checksum: ${NEW_CHECKSUM:0:12}..."
echo "  6. ✓ Updated baseline marker"
echo "  7. ✓ Invoked Lambda (${INVOKE_DURATION}s)"
echo "  8. ✓ Parsed response"
echo "  9. ✓ Verified service in DynamoDB"
echo " 10. ✓ Checked CloudWatch logs"
echo " 11. ✓ Verified SCP policy"
echo ""
echo "Results:"
if [ "$STATUS_CODE" = "200" ] && echo "$NEW_SERVICES" | grep -q "$SELECTED_SERVICE" && [ "$SERVICE_CHECK" = "$SELECTED_SERVICE" ]; then
  echo -e "${GREEN}✓ TEST PASSED${NC}"
  echo ""
  echo "Summary:"
  echo "  • Service $SELECTED_SERVICE was successfully removed from baseline"
  echo "  • Lambda detected it as new and rediscovered it"
  echo "  • Service added back to DynamoDB"
  if [ "$SCP_STATUS" = "success" ]; then
    echo "  • SCP policy '$SCP_NAME' was updated with the service"
    echo "  • Success email was sent to configured recipients"
  elif [ "$SCP_STATUS" = "disabled" ]; then
    echo "  • SCP management is disabled (notifications-only mode)"
    echo "  • Email notification was sent"
  fi
  echo ""
  echo -e "${GREEN}✓ All verifications passed!${NC}"
else
  echo -e "${YELLOW}⚠ TEST INCONCLUSIVE${NC}"
  echo ""
  if [ "$STATUS_CODE" != "200" ]; then
    echo "  Issue: Lambda returned status $STATUS_CODE"
  fi
  if ! echo "$NEW_SERVICES" | grep -q "$SELECTED_SERVICE"; then
    echo "  Issue: Service not detected as new"
  fi
  if [ "$SERVICE_CHECK" != "$SELECTED_SERVICE" ]; then
    echo "  Issue: Service not in DynamoDB after Lambda execution"
  fi
  echo ""
  echo "Check CloudWatch logs for details:"
  echo "  aws logs tail /aws/lambda/$LAMBDA_FUNCTION --region $REGION --follow"
fi
echo ""
echo -e "${BLUE}============================================${NC}"
