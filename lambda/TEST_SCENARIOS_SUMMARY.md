# Test Scenarios Summary

Quick reference guide for the test suite covering both SCP management options.

## Overview

This test suite validates the AWS Service Monitor Lambda function across two major configuration modes:

1. **With SCP Management Enabled** (`manage_scp_policy = true`)
2. **Without SCP Management** (`manage_scp_policy = false` - notifications-only mode)

## Scenario Matrix

### Scenario 1: New Service Detection Without SCP Management

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = false` |
| **Trigger** | 1 new service appears in AWS service reference |
| **Expected Flow** | ✓ Service detected → ✓ DynamoDB updated → ✓ Email sent (status=disabled) |
| **SCP Action** | None (management disabled) |
| **Email Status** | `disabled` - Notifications-only |
| **Test Case** | `test_detect_new_service_no_scp` |

**Test Execution**:
```
Initial baseline:    [ec2, s3, lambda, dynamodb, rds]
AWS services fetch:  [ec2, s3, lambda, dynamodb, rds, sagemaker]
New services:        [sagemaker] ← Detected as new
DynamoDB change:     Add 'sagemaker' to registry
SCP Policy:          NOT touched (disabled)
Email sent:          Yes - indicates notifications-only mode
```

---

### Scenario 2: Multiple New Services Without SCP Management

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = false` |
| **Trigger** | 3 new services added to AWS service reference |
| **Expected Flow** | ✓ All services detected → ✓ All added to DynamoDB → ✓ Email lists all 3 |
| **Email Status** | `disabled` |
| **Test Case** | `test_detect_multiple_new_services_no_scp` |

**Test Execution**:
```
Initial baseline:    [ec2, s3, lambda]
AWS services fetch:  [ec2, s3, lambda, sagemaker, bedrock, textract]
New services:        [sagemaker, bedrock, textract]
DynamoDB change:     Add all 3 services
Email includes:      All 3 service names + disabled status
```

---

### Scenario 3: New Service with SCP Update Success

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = true`, `require_approval = false` |
| **Trigger** | 1 new service detected + SCP exists + update succeeds |
| **Expected Flow** | ✓ Service detected → ✓ DynamoDB updated → ✓ SCP updated → ✓ Success email |
| **SCP Action** | Updated with new service:* action |
| **Email Status** | `success` - SCP update completed |
| **Test Case** | `test_detect_new_service_with_scp_success` |

**Test Execution**:
```
Initial baseline:        [ec2, s3, lambda, dynamodb]
AWS services fetch:      [ec2, s3, lambda, dynamodb, sagemaker]
New services:            [sagemaker]
DynamoDB change:         Add 'sagemaker'
SCP policy lookup:       ✓ Found ('blacklist')
SCP update:              ✓ Succeeded - added 'sagemaker:*' to Deny actions
Email sent:              ✓ Yes, status='success'
Email content includes:  Service name + SCP update confirmation
```

**Expected Email**:
```
Subject: AWS Service Monitor: 1 New Service(s) Detected
Status: ✅ SUCCESS - SCP Policy Updated
Service: sagemaker
Action: Added to blacklist SCP policy
Next Steps: Review policy at AWS Organizations console
```

---

### Scenario 4: New Service with SCP Update Failure

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = true`, `require_approval = false` |
| **Trigger** | 1 new service detected but SCP update fails (permission denied) |
| **Expected Flow** | ✓ Service detected → ✓ DynamoDB updated → ✗ SCP update fails → ⚠️ Warning email |
| **SCP Action** | Attempted but failed |
| **Email Status** | `failed` - Warning email |
| **Test Case** | `test_detect_new_service_scp_update_fails` |

**Test Execution**:
```
Initial baseline:        [ec2, s3, lambda]
AWS services fetch:      [ec2, s3, lambda, bedrock]
New services:            [bedrock]
DynamoDB change:         ✓ Add 'bedrock'
SCP policy lookup:       ✓ Found
SCP update:              ✗ FAILED - Permission denied
Lambda response:         HTTP 200 (service stored) + scp_error
Email sent:              ✓ Yes, status='failed'
Email content includes:  Service name + error message + action required
```

**Expected Email**:
```
Subject: AWS Service Monitor: 1 New Service(s) Detected
Status: ⚠️ WARNING - SCP Update Failed
Service: bedrock
Error: Permission denied on UpdatePolicy call
Action Required: Check Lambda execution role permissions, retry SCP update
```

---

### Scenario 5: New Service with SCP Policy Not Found

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = true`, `require_approval = false` |
| **Trigger** | 1 new service detected but configured SCP policy doesn't exist |
| **Expected Flow** | ✓ Service detected → ✓ DynamoDB updated → ✗ SCP not found → ⚠️ Alert email |
| **SCP Action** | Not attempted (policy doesn't exist) |
| **Email Status** | `not_found` |
| **Test Case** | `test_detect_new_service_scp_not_found` |

**Test Execution**:
```
Initial baseline:        [ec2, s3]
AWS services fetch:      [ec2, s3, textract]
New services:            [textract]
DynamoDB change:         ✓ Add 'textract'
SCP policy lookup:       ✗ NOT FOUND (policy 'blacklist' doesn't exist)
SCP update:              Not attempted
Email sent:              ✓ Yes, status='not_found'
Lambda response:         HTTP 200 + scp_status='not_found'
```

**Expected Email**:
```
Subject: AWS Service Monitor: 1 New Service(s) Detected
Status: ⚠️ SCP Policy Not Found
Service: textract
Issue: Service Control Policy 'blacklist' not found in AWS Organizations
Action Required: Create SCP or verify policy name in configuration
```

---

### Scenario 6: Service Removal and Rediscovery (WITH SCP)

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = true`, `require_approval = false` |
| **Setup** | Initialize baseline with 6 services |
| **Step 1** | Remove 1 service from DynamoDB, update baseline checksum |
| **Step 2** | Trigger Lambda (mock returns original 6 services) |
| **Expected Result** | Service rediscovered, SCP updated, success email sent |
| **Test Case** | `test_remove_service_and_rediscover_with_scp` |

**Detailed Flow**:

```
STEP 1: Initialize Baseline
├─ Services: [ec2, s3, lambda, dynamodb, rds, sagemaker]
├─ Checksum: abc123def456... (6 services)
└─ Status: Initialized

STEP 2: Remove Service from Baseline
├─ Action: Delete 'sagemaker' from DynamoDB
├─ Checksum update: xyz789abc123... (5 services)
└─ Status: Service removed but monitoring continues

STEP 3: Trigger Lambda Handler
├─ Fetch AWS services: Returns [ec2, s3, lambda, dynamodb, rds, sagemaker]
├─ Get tracked services: Returns [ec2, s3, lambda, dynamodb, rds]
├─ Calculate new services: [sagemaker] ✓ DETECTED
├─ DynamoDB: Add 'sagemaker' back to registry ✓
├─ Get SCP: Lookup 'blacklist' policy ✓ Found
├─ Update SCP: Add 'sagemaker:*' to Deny actions ✓ Success
└─ Send Email: Success notification ✓

STEP 4: Email Notification
├─ Recipients: [ops@example.com]
├─ Status: success
├─ Subject: AWS Service Monitor: 1 New Service(s) Detected
├─ Body includes:
│  ├─ Service name: sagemaker
│  ├─ SCP status: Successfully updated
│  ├─ Policy name: blacklist
│  └─ Instruction: Review policy in AWS Organizations
└─ Sent: ✓ Yes

VERIFICATION
├─ Lambda response: HTTP 200, scp_status='success'
├─ DynamoDB: 'sagemaker' in registry ✓
├─ SCP: Contains 'sagemaker:*' action ✓
├─ Email: Received with success status ✓
└─ Test: PASSED ✓
```

---

### Scenario 7: Service Removal and Rediscovery (WITHOUT SCP)

| Aspect | Details |
|--------|---------|
| **Configuration** | `manage_scp_policy = false` |
| **Setup** | Initialize baseline with 6 services |
| **Step 1** | Remove 1 service from DynamoDB, update baseline checksum |
| **Step 2** | Trigger Lambda (mock returns original 6 services) |
| **Expected Result** | Service rediscovered, NO SCP action, disabled email sent |
| **Test Case** | `test_remove_service_and_rediscover_without_scp` |

**Detailed Flow**:

```
STEP 1: Initialize Baseline
├─ Services: [ec2, s3, lambda, dynamodb, rds, bedrock]
├─ Checksum: abc123def456... (6 services)
└─ Status: Initialized (SCP management disabled)

STEP 2: Remove Service from Baseline
├─ Action: Delete 'bedrock' from DynamoDB
├─ Checksum update: xyz789abc123... (5 services)
└─ Status: Service removed

STEP 3: Trigger Lambda Handler
├─ Fetch AWS services: Returns [ec2, s3, lambda, dynamodb, rds, bedrock]
├─ Get tracked services: Returns [ec2, s3, lambda, dynamodb, rds]
├─ Calculate new services: [bedrock] ✓ DETECTED
├─ DynamoDB: Add 'bedrock' back to registry ✓
├─ MANAGE_SCP_POLICY check: FALSE → Skip SCP operations
├─ Set scp_status: 'disabled'
└─ Send Email: Notifications-only ✓

STEP 4: Email Notification
├─ Recipients: [ops@example.com]
├─ Status: disabled
├─ Subject: AWS Service Monitor: 1 New Service(s) Detected
├─ Body includes:
│  ├─ Service name: bedrock
│  ├─ SCP status: Not updated (notifications-only)
│  ├─ Note: No SCP policy changes were made
│  └─ Instruction: Manually add to SCP if desired
└─ Sent: ✓ Yes (different template than SCP case)

VERIFICATION
├─ Lambda response: HTTP 200, scp_status='disabled'
├─ DynamoDB: 'bedrock' in registry ✓
├─ SCP: NOT touched ✓
├─ Email: Received with disabled status ✓
└─ Test: PASSED ✓
```

---

## Email Verification Tests

### Test: Success Email with SCP Enabled

**Verifies**:
- ✓ Email structure (Source, Destination, Subject, Body)
- ✓ Subject contains service count
- ✓ HTML body contains service names
- ✓ HTML body includes SCP-related information
- ✓ Text body is also generated

**Test Case**: `test_success_email_with_scp_enabled`

---

### Test: Warning Email with SCP Failed

**Verifies**:
- ✓ Email sent when SCP update fails
- ✓ Subject indicates the number of services detected
- ✓ Body contains failure indication
- ✓ Error message is included

**Test Case**: `test_warning_email_with_scp_failed`

---

### Test: Notifications-Only Mode Email

**Verifies**:
- ✓ Email sent when SCP management is disabled
- ✓ HTML/Text body excludes SCP-related sections
- ✓ Services are still listed
- ✓ Status clearly indicates "Notifications-Only"

**Test Case**: `test_notification_email_disabled_scp_mode`

---

### Test: Multi-Recipient Email Delivery

**Verifies**:
- ✓ Each recipient in list receives email
- ✓ `send_email` called once per recipient (not once per list)
- ✓ Each email has correct To: address

**Test Case**: `test_email_to_multiple_recipients`

**Configuration**: `email_recipients = ["ops@example.com", "security@example.com", "devops@example.com"]`

---

## Baseline Integrity Test

### Test: Baseline Tampering Detection

**Scenario**:
```
Baseline has: [ec2, s3, lambda]
Stored checksum: For 3 services

Tampering occurs: User deletes 'lambda' from DynamoDB
Updated checksum: NOT updated (checksum still = 3 services)

Lambda invoked:
├─ Fetch returns: [ec2, s3, lambda] (original AWS list)
├─ Verify baseline integrity:
│  ├─ Calculate checksum of current DynamoDB: 2 services
│  ├─ Compare with stored checksum: 3 services
│  └─ Result: ✗ MISMATCH → TAMPERING DETECTED
├─ Send tamper alert email ✓
├─ Send SNS alert ✓
└─ Return HTTP 500 ✓
```

**Test Case**: `test_baseline_tampering_detection`

**Expected Outcome**:
- HTTP 500 error with "Baseline integrity check failed"
- Tamper alert email sent
- SNS alert published
- No DynamoDB updates (Lambda halts on security failure)

---

## Quick Test Commands

### Run All Tests
```bash
pytest lambda/test_index.py -v
```

### Run Specific Test Class
```bash
# Without SCP tests
pytest lambda/test_index.py::TestNewServiceDetectionWithoutSCP -v

# With SCP tests
pytest lambda/test_index.py::TestNewServiceDetectionWithSCP -v

# Email tests
pytest lambda/test_index.py::TestEmailNotifications -v

# Removal/rediscovery tests
pytest lambda/test_index.py::TestServiceRemovalAndRediscovery -v
```

### Run With Coverage
```bash
pytest lambda/test_index.py --cov=lambda.index --cov-report=html
# Open htmlcov/index.html in browser
```

### Run Verbose (Show Print Output)
```bash
pytest lambda/test_index.py -v -s
```

---

## Success Criteria

All tests should **PASS** with these criteria:

| Test Class | Test Count | Status |
|-----------|----------|--------|
| TestNewServiceDetectionWithoutSCP | 2 | ✓ PASS |
| TestNewServiceDetectionWithSCP | 3 | ✓ PASS |
| TestEmailNotifications | 4 | ✓ PASS |
| TestBaselineIntegrity | 1 | ✓ PASS |
| TestServiceRemovalAndRediscovery | 2 | ✓ PASS |
| **Total** | **12** | **✓ ALL PASS** |

**Coverage Target**: ≥90% of `index.py` functions

---

## Common Assertions in Tests

```python
# Response validation
assert response['statusCode'] == 200
assert 'scp_status' in body
assert body['scp_status'] == 'success'

# Service detection validation
assert 'new_services' in body
assert 'sagemaker' in body['new_services']

# Email validation
assert mock_send_email.called
assert mock_send_email.call_count == 1  # or number of recipients

# Mock call validation
call_args = mock_send_email.call_args
assert call_args[0][0] == ['sagemaker']  # services
assert call_args[0][1] == 'success'      # status
```

---

## Next Steps

1. **Run the tests**: `./run_tests.sh` or `pytest lambda/test_index.py -v`
2. **Check coverage**: Review `htmlcov/index.html`
3. **Review output**: Ensure all 12 tests pass
4. **Integration test**: Deploy to staging and test with real AWS
5. **Manual verification**: Check email delivery and SCP updates in AWS console
