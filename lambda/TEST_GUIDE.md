# Lambda Function Test Guide

This document describes the comprehensive test suite for the AWS Service Monitor Lambda function, covering both SCP management scenarios.

## Test File Structure

- **test_index.py**: Main test suite with pytest fixtures and test classes
- **run_tests.sh**: Automated test runner script with dependency management
- **TEST_GUIDE.md**: This file - documentation and test case descriptions

## Prerequisites

Before running tests locally:

```bash
# Option 1: Install Python test dependencies globally
pip install pytest pytest-cov boto3 moto requests

# Option 2: Create and use virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install pytest pytest-cov boto3 moto requests
```

## Running Tests

### Quick Start (using provided script)

```bash
cd lambda/
chmod +x run_tests.sh
./run_tests.sh
```

### Manual Execution

```bash
# Run all tests with coverage
pytest test_index.py -v --tb=short --cov=index

# Run specific test class
pytest test_index.py::TestNewServiceDetectionWithoutSCP -v

# Run specific test
pytest test_index.py::TestNewServiceDetectionWithoutSCP::test_detect_new_service_no_scp -v

# Run with detailed output
pytest test_index.py -vv -s

# Run with coverage report
pytest test_index.py --cov=index --cov-report=html
```

## Test Suite Overview

### 1. TestNewServiceDetectionWithoutSCP

Tests new service detection when `manage_scp_policy = false` (notifications-only mode).

#### Test Cases:

- **test_detect_new_service_no_scp**: Single new service detection without SCP management
  - Initial services: `[ec2, s3, lambda, dynamodb, rds]`
  - New services detected: `[sagemaker]`
  - Expected: Service added to DynamoDB, email sent with status='disabled'

- **test_detect_multiple_new_services_no_scp**: Multiple new services detection
  - Initial services: `[ec2, s3, lambda]`
  - New services detected: `[sagemaker, bedrock, textract]`
  - Expected: All services added, email includes all 3 services

### 2. TestNewServiceDetectionWithSCP

Tests new service detection when `manage_scp_policy = true` (with SCP management enabled).

#### Test Cases:

- **test_detect_new_service_with_scp_success**: Successful SCP update
  - Initial services: `[ec2, s3, lambda, dynamodb]`
  - New services: `[sagemaker]`
  - SCP policy exists and update succeeds
  - Expected: 
    - Service stored in DynamoDB ✓
    - SCP updated with `sagemaker:*` action ✓
    - Email sent with status='success' ✓

- **test_detect_new_service_scp_update_fails**: SCP update fails (permission denied, etc.)
  - Initial services: `[ec2, s3, lambda]`
  - New services: `[bedrock]`
  - SCP update fails with "Permission denied"
  - Expected:
    - Service still stored in DynamoDB ✓
    - Email sent with status='failed' (warning email) ✓
    - Response includes scp_error message ✓

- **test_detect_new_service_scp_not_found**: SCP policy doesn't exist
  - Initial services: `[ec2, s3]`
  - New services: `[textract]`
  - SCP policy lookup returns None
  - Expected:
    - Service stored in DynamoDB ✓
    - Email sent with status='not_found' ✓
    - Response includes scp_status='not_found' ✓

### 3. TestEmailNotifications

Tests email notification behavior across different scenarios.

#### Test Cases:

- **test_success_email_with_scp_enabled**: Success email when SCP update succeeds
  - Verifies email structure, subject line, recipient
  - Checks HTML body includes service names
  - Checks email metadata

- **test_warning_email_with_scp_failed**: Warning email when SCP update fails
  - Verifies email indicates failure
  - Includes service names in body

- **test_notification_email_disabled_scp_mode**: Email in notifications-only mode
  - Verifies email excludes SCP-related sections
  - Services are listed but SCP actions are not mentioned

- **test_email_to_multiple_recipients**: Multi-recipient email delivery
  - Configured recipients: `[ops@example.com, security@example.com, devops@example.com]`
  - Verifies each recipient receives an email
  - Checks `send_email` call count matches recipient count

### 4. TestBaselineIntegrity

Tests baseline integrity checking and tampering detection.

#### Test Cases:

- **test_baseline_tampering_detection**: Detects baseline tampering
  - Initial services: `[ec2, s3, lambda]`
  - Simulate tampering: Remove 'lambda' without updating checksum
  - Expected:
    - Checksum mismatch detected ✓
    - Returns HTTP 500 ✓
    - Tamper alert email sent ✓
    - SNS alert published ✓

### 5. TestServiceRemovalAndRediscovery

Tests the complete workflow from requirement: Remove service → Trigger Lambda → Rediscover → Email.

#### Test Case A: With SCP Management

**Scenario**: Remove 'sagemaker' from baseline, then trigger Lambda which rediscovers it.

1. **Setup**: Initialize baseline with 6 services
   ```
   [ec2, s3, lambda, dynamodb, rds, sagemaker]
   ```

2. **Removal Phase**:
   - Delete 'sagemaker' from DynamoDB
   - Update baseline checksum to match 5 remaining services

3. **Trigger Phase**:
   - Mock `fetch_aws_services()` to return original 6 services
   - SCP policy exists and update succeeds

4. **Verification**:
   ```
   ✓ sagemaker detected as new service
   ✓ Service added to DynamoDB
   ✓ SCP updated with sagemaker:*
   ✓ Email sent to ops@example.com with status='success'
   ✓ Email includes service name and indicates SCP action completed
   ```

**Expected Email Content**:
```
Subject: AWS Service Monitor: 1 New Service(s) Detected
Status: SCP successfully updated with new service restrictions
Service: sagemaker
Action: Added to blacklist SCP policy
```

#### Test Case B: Without SCP Management

**Scenario**: Same removal/rediscovery but with `manage_scp_policy = false`.

1. **Setup**: Initialize baseline with 6 services
   ```
   [ec2, s3, lambda, dynamodb, rds, bedrock]
   ```

2. **Removal Phase**:
   - Delete 'bedrock' from DynamoDB
   - Update baseline checksum

3. **Trigger Phase**:
   - Mock `fetch_aws_services()` returns original 6 services
   - SCP management is disabled

4. **Verification**:
   ```
   ✓ bedrock detected as new service
   ✓ Service added to DynamoDB
   ✓ SCP management NOT triggered (disabled)
   ✓ Email sent with status='disabled' (notifications-only)
   ✓ Email indicates detection but no SCP action
   ```

**Expected Email Content**:
```
Subject: AWS Service Monitor: 1 New Service(s) Detected
Status: Notifications-only mode - no SCP changes made
Service: bedrock
Action: None (SCP management disabled)
```

## Success Email Examples

### When SCP Update Succeeds

```
Subject: AWS Service Monitor: 1 New Service(s) Detected

✅ SUCCESS: Service Control Policy Updated

New Services Detected: 1
- sagemaker

Service Control Policy Status: Successfully Updated
- Policy Name: blacklist
- Action: Added sagemaker:* to Deny statement
- Services in Policy: 5 total actions

Next Steps:
- Review SCP policy changes at: AWS Organizations > Service Control Policies
- All accounts are now restricted from using sagemaker service
- Changes took effect immediately
```

### When SCP Update Fails (Warning)

```
Subject: AWS Service Monitor: 1 New Service(s) Detected

⚠️ WARNING: Services Detected But SCP Update Failed

New Services Detected: 1
- bedrock

Service Control Policy Status: FAILED TO UPDATE
- Error: Permission denied on UpdatePolicy call
- Impact: Service detected but NOT added to SCP policy

Action Required:
1. Check Lambda execution role permissions
2. Verify Organizations policy access
3. Review CloudWatch logs for details
4. Retry manual SCP update or investigate permissions
```

### Notifications-Only Mode

```
Subject: AWS Service Monitor: 1 New Service(s) Detected

📢 NEW SERVICES DETECTED (Notifications-Only)

New Services Detected: 1
- textract

Service Control Policy: Not Updated
- Mode: Notifications-only (SCP management disabled)
- Impact: Service detected but NO policy changes made

Notes:
- Set MANAGE_SCP_POLICY=true to enable automatic SCP updates
- Or manually add services to your blacklist policy
```

## Mock Objects Used

### AWS Services Mocked

1. **DynamoDB** (moto mock_dynamodb)
   - Table: `test-registry`
   - Operations: put_item, delete_item, update_item, scan, get_item

2. **S3** (moto mock_s3)
   - Bucket: `test-baseline-bucket`
   - Operations: put_object for baseline snapshots

3. **SES** (moto mock_ses)
   - Operations: send_email
   - Verified emails: monitor@example.com, ops@example.com

4. **Organizations API** (unittest.mock)
   - Mocked: get_scp_policy, update_policy, list_policies

5. **CloudWatch** (moto mock_cloudwatch)
   - Metrics: service_count, new_services, baseline_integrity

6. **SNS** (unittest.mock)
   - Operations: publish alerts

## Environment Variables (Test Configuration)

```python
DYNAMODB_TABLE = 'test-registry'
SCP_NAME = 'blacklist'
EMAIL_RECIPIENTS = '["ops@example.com"]'
SENDER_EMAIL = 'monitor@example.com'
REQUIRE_APPROVAL = 'false'  # For these tests
BASELINE_SNAPSHOT_BUCKET = 'test-baseline-bucket'
ALERT_TOPIC_ARN = 'arn:aws:sns:us-east-1:123456789012:alerts'
```

## Test Execution Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      Test Setup                             │
│  - Mock DynamoDB, S3, SES, Organizations, CloudWatch       │
│  - Initialize baseline with services                        │
└─────────────────────────────────────────────────────────────┘
                          ↓
         ┌─────────────────────────────────┐
         │  Remove Service from Baseline    │
         │  Update Checksum                │
         └─────────────────────────────────┘
                          ↓
         ┌─────────────────────────────────┐
         │  Trigger lambda_handler()        │
         │  - Fetch services               │
         │  - Detect new services          │
         │  - Update DynamoDB              │
         │  - SCP operations (if enabled)  │
         │  - Send email notifications     │
         └─────────────────────────────────┘
                          ↓
         ┌─────────────────────────────────┐
         │  Verify Outcomes                 │
         │  - Response code                |
         │  - DynamoDB state                |
         │  - Email calls                  │
         │  - SCP calls (if applicable)    │
         └─────────────────────────────────┘
```

## Interpreting Test Results

### Successful Test Run

```
test_index.py::TestNewServiceDetectionWithoutSCP::test_detect_new_service_no_scp PASSED
test_index.py::TestNewServiceDetectionWithSCP::test_detect_new_service_with_scp_success PASSED
test_index.py::TestEmailNotifications::test_success_email_with_scp_enabled PASSED
...

==================== 12 passed in 2.34s ====================
```

### Coverage Report

```
Name          Stmts   Miss  Cover
-----------------------------------
index.py       342    18    95%
-----------------------------------
TOTAL          342    18    95%
```

Aim for **90%+ coverage** on:
- `fetch_aws_services()` - Service detection
- `send_notification_email()` - Email delivery
- `initialize_baseline()` - Baseline setup
- `lambda_handler()` - Main orchestration
- `get_scp_policy()` - SCP operations
- `update_scp_with_services()` - SCP updates

## Troubleshooting

### Test Import Errors

If you get `ModuleNotFoundError: No module named 'moto'`:

```bash
pip install moto boto3 pytest
```

### Environment Variable Issues

If tests fail with missing environment variables, ensure `test_index.py` is in the same directory as `index.py`:

```bash
cd lambda/
pytest test_index.py
```

### Mock Object Not Working

If mocks aren't patching correctly, verify patch paths use full module path:

```python
@patch('index.MANAGE_SCP_POLICY', True)  # ✓ Correct
@patch('MANAGE_SCP_POLICY', True)        # ✗ Wrong - won't patch
```

## Next Steps

1. **Run tests**: `./run_tests.sh` or `pytest test_index.py -v`
2. **Review coverage**: Check htmlcov/index.html for coverage details
3. **Run integration tests**: Deploy to staging AWS account and test with real SES
4. **Validate email delivery**: Confirm emails arrive with correct formatting
5. **Test edge cases**: Manually test with large service lists, network timeouts, etc.

## Integration Testing (Manual)

After unit tests pass, perform integration testing:

### With SCP Enabled

```bash
# 1. Ensure your testing email is verified in SES
aws ses verify-email-identity --email-address ops@example.com --region eu-west-2

# 2. Update terraform.tfvars with test values
cat >> terraform.tfvars << EOF
manage_scp_policy = true
email_recipients = ["ops@example.com"]
sender_email = "monitor@example.com"
EOF

# 3. Deploy test infrastructure
terraform apply -var-file=terraform.tfvars

# 4. Remove a service from DynamoDB to test rediscovery
aws dynamodb delete-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"sagemaker"}}' \
  --region eu-west-2

# 5. Update baseline checksum
# (See CLAUDE.md for manual testing instructions)

# 6. Invoke Lambda
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json && cat response.json

# 7. Check email arrived
# Check ops@example.com inbox for new service notification

# 8. Verify SCP was updated
aws organizations describe-policy --policy-id p-your-policy-id
```

### Without SCP Enabled

```bash
# Same as above but with manage_scp_policy = false
# Email should arrive but indicate "Notifications-Only Mode"
# SCP should NOT be updated
```
