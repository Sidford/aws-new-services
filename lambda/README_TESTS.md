# AWS Service Monitor - Lambda Function Tests

## Quick Start

Two comprehensive test scenarios have been created to validate the Lambda function with and without SCP management enabled.

### Files Created

1. **test_index.py** (621 lines)
   - Complete pytest test suite with 12 test cases
   - Tests for both SCP management modes
   - Email notification validation
   - Baseline integrity testing

2. **run_tests.sh** (Executable)
   - Automated test runner with dependency installation
   - Generates coverage reports

3. **TEST_GUIDE.md** (14 KB)
   - Detailed documentation of all test cases
   - Setup instructions and troubleshooting
   - Integration testing guidance

4. **TEST_SCENARIOS_SUMMARY.md** (14 KB)
   - Quick reference for test scenarios
   - Detailed flow diagrams for each scenario
   - Expected email content examples

## Running Tests

### Option 1: Automated (Recommended)

```bash
cd lambda/
chmod +x run_tests.sh
./run_tests.sh
```

This will:
- Create Python virtual environment
- Install test dependencies (pytest, moto, boto3)
- Run all 12 tests with coverage report
- Generate HTML coverage report

### Option 2: Manual

```bash
# Install dependencies
pip install pytest pytest-cov boto3 moto requests

# Run tests
cd lambda/
pytest test_index.py -v

# With coverage
pytest test_index.py -v --cov=index --cov-report=html
```

## Test Coverage Overview

### 12 Total Test Cases Across 5 Classes

#### 1. Without SCP Management (2 tests)
- ✓ Single new service detection
- ✓ Multiple new services detection

#### 2. With SCP Management (3 tests)
- ✓ Successful SCP update
- ✓ SCP update fails (warning email)
- ✓ SCP policy not found (alert email)

#### 3. Email Notifications (4 tests)
- ✓ Success email with SCP
- ✓ Warning email on SCP failure
- ✓ Notifications-only mode email
- ✓ Multi-recipient email delivery

#### 4. Baseline Integrity (1 test)
- ✓ Tampering detection

#### 5. Service Removal & Rediscovery (2 tests)
- ✓ Remove service and rediscover with SCP enabled
- ✓ Remove service and rediscover without SCP

## Key Test Scenarios

### Scenario A: New Service Detection Without SCP

**Setup**:
```
Initial baseline: [ec2, s3, lambda, dynamodb, rds]
New service appears: sagemaker
```

**Expected Results**:
- ✓ Service detected as new
- ✓ Added to DynamoDB registry
- ✓ Email sent with status='disabled' (no SCP action)
- ✓ SCP policy NOT modified

---

### Scenario B: New Service Detection With SCP Success

**Setup**:
```
Initial baseline: [ec2, s3, lambda, dynamodb]
New service appears: sagemaker
SCP policy exists: "blacklist"
SCP update: Succeeds
```

**Expected Results**:
- ✓ Service detected
- ✓ DynamoDB updated
- ✓ SCP updated with 'sagemaker:*' action
- ✓ Email sent with status='success'
- ✓ Email indicates SCP was updated

**Email Content**:
```
Subject: AWS Service Monitor: 1 New Service(s) Detected
Status: ✅ SUCCESS - SCP Policy Updated
Service: sagemaker
Action: Added to blacklist SCP policy
```

---

### Scenario C: Service Removal & Rediscovery

**Test Workflow**:
1. Initialize baseline with 6 services
2. Remove service 'sagemaker' from DynamoDB
3. Update baseline checksum (5 services)
4. Trigger Lambda
5. Lambda detects service as "new" (rediscovery)
6. DynamoDB updated, SCP updated (if enabled), email sent

**With SCP Enabled**:
- ✓ Service rediscovered
- ✓ SCP updated with service:* action
- ✓ Success email sent

**Without SCP Enabled**:
- ✓ Service rediscovered
- ✓ SCP NOT updated
- ✓ Notifications-only email sent

---

## Expected Test Output

```
==================== test session starts ====================
platform linux -- Python 3.x.x, pytest-x.x.x
collected 12 items

test_index.py::TestNewServiceDetectionWithoutSCP::test_detect_new_service_no_scp PASSED
test_index.py::TestNewServiceDetectionWithoutSCP::test_detect_multiple_new_services_no_scp PASSED
test_index.py::TestNewServiceDetectionWithSCP::test_detect_new_service_with_scp_success PASSED
test_index.py::TestNewServiceDetectionWithSCP::test_detect_new_service_scp_update_fails PASSED
test_index.py::TestNewServiceDetectionWithSCP::test_detect_new_service_scp_not_found PASSED
test_index.py::TestEmailNotifications::test_success_email_with_scp_enabled PASSED
test_index.py::TestEmailNotifications::test_warning_email_with_scp_failed PASSED
test_index.py::TestEmailNotifications::test_notification_email_disabled_scp_mode PASSED
test_index.py::TestEmailNotifications::test_email_to_multiple_recipients PASSED
test_index.py::TestBaselineIntegrity::test_baseline_tampering_detection PASSED
test_index.py::TestServiceRemovalAndRediscovery::test_remove_service_and_rediscover_with_scp PASSED
test_index.py::TestServiceRemovalAndRediscovery::test_remove_service_and_rediscover_without_scp PASSED

==================== 12 passed in ~2-3 seconds ====================

Coverage Report:
Name      Stmts   Miss  Cover
index.py   342    18    95%
```

## Test Mocking Strategy

All AWS services are mocked using:

| Service | Mock Library | Mocked Operations |
|---------|--------------|-------------------|
| DynamoDB | moto | put_item, delete_item, update_item, scan, get_item |
| S3 | moto | put_object (baseline snapshots) |
| SES | moto | send_email |
| Organizations | unittest.mock | get_scp_policy, update_policy |
| CloudWatch | moto | publish_metrics |
| SNS | unittest.mock | publish (alerts) |

No AWS credentials or real AWS resources are required to run tests.

## Test Environment Variables

Tests automatically configure:
```
DYNAMODB_TABLE = 'test-registry'
SCP_NAME = 'blacklist'
EMAIL_RECIPIENTS = '["ops@example.com"]'
SENDER_EMAIL = 'monitor@example.com'
REQUIRE_APPROVAL = 'false'
BASELINE_SNAPSHOT_BUCKET = 'test-baseline-bucket'
ALERT_TOPIC_ARN = 'arn:aws:sns:us-east-1:123456789012:alerts'
```

## Next Steps

1. **Run tests**: `./run_tests.sh`
2. **Review coverage**: Check `htmlcov/index.html` for coverage details
3. **Check documentation**: See TEST_GUIDE.md for detailed test descriptions
4. **Integration testing**: Deploy to staging AWS account and test with real SES
5. **Verify email delivery**: Confirm emails are sent and formatted correctly

## Troubleshooting

### ImportError: No module named 'moto'

```bash
pip install pytest pytest-cov boto3 moto requests
```

### Tests timeout or hang

Increase pytest timeout:
```bash
pytest test_index.py --timeout=30 -v
```

### Coverage report not generated

Ensure pytest-cov is installed:
```bash
pip install pytest-cov
```

## Integration Testing (After Unit Tests Pass)

Once unit tests pass, test with real AWS:

```bash
# 1. Verify email in SES
aws ses verify-email-identity --email-address ops@example.com

# 2. Deploy infrastructure
terraform apply

# 3. Remove a service from DynamoDB
aws dynamodb delete-item \
  --table-name aws-service-monitor-registry \
  --key '{"service_name":{"S":"sagemaker"}}' \
  --region eu-west-2

# 4. Update baseline checksum manually
# (See CLAUDE.md for instructions)

# 5. Invoke Lambda
aws lambda invoke --function-name aws-service-monitor response.json

# 6. Check email was delivered
# Verify ops@example.com inbox

# 7. Verify SCP was updated (if manage_scp_policy=true)
aws organizations describe-policy --policy-id p-...
```

## Documentation Files

- **TEST_GUIDE.md**: Complete guide with detailed test descriptions
- **TEST_SCENARIOS_SUMMARY.md**: Quick reference with flow diagrams
- **README_TESTS.md**: This file - quick start guide

## Contact & Support

For detailed test documentation:
- See TEST_GUIDE.md for setup and troubleshooting
- See TEST_SCENARIOS_SUMMARY.md for scenario details and email examples
- See CLAUDE.md for integration testing instructions
