# Development Guide

This guide covers customizing and extending the AWS Service Monitor.

## Project Structure

```
.
├── providers.tf                    # AWS provider configuration
├── variables.tf                    # Variable definitions
├── main.tf                        # Main Terraform configuration
├── outputs.tf                     # Output definitions
├── terraform.tfvars.example       # Example variable values
├── lambda/
│   ├── index.py                   # Lambda handler function
│   └── requirements.txt           # Python dependencies
├── example-blacklist-policy.json  # Example SCP policy
├── README.md                      # Project overview
├── DEPLOYMENT_GUIDE.md            # Deployment instructions
└── DEVELOPMENT.md                 # This file
```

## Lambda Function Customization

The Lambda function (`lambda/index.py`) handles the core logic:

### 1. Customize Service Fetching

To fetch services differently or from another source, modify `fetch_aws_services()`:

```python
def fetch_aws_services() -> Set[str]:
    """Fetch services from a custom endpoint."""
    # Your custom logic here
    return set(['service1', 'service2'])
```

### 2. Customize Email Template

Modify `generate_html_email()` for HTML emails:

```python
def generate_html_email(services: List[str], timestamp: str) -> str:
    """Generate custom HTML email."""
    html = f"""
    <html>
    <body>
        <h1>Custom Header</h1>
        <!-- Your custom HTML here -->
    </body>
    </html>
    """
    return html
```

Modify `generate_text_email()` for plain text version.

### 3. Filter Services

To exclude certain services, modify the service comparison:

```python
def lambda_handler(event, context):
    # ... existing code ...
    
    # Filter out certain services
    excluded = {'s3', 'iam', 'ec2'}  # Services to ignore
    new_services = (current_services - tracked_services) - excluded
```

### 4. Custom SCP Update Logic

Modify `update_scp_with_services()` to implement different SCP strategies:

```python
def update_scp_with_services(scp_policy: Dict, new_services: List[str]) -> bool:
    """Custom SCP update strategy."""
    # Your logic here
    pass
```

## Local Testing

### 1. Set Up Development Environment

```bash
# Create virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r lambda/requirements.txt
pip install boto3 moto  # moto for mocking AWS
```

### 2. Unit Testing

Create `lambda/test_index.py`:

```python
import json
from unittest.mock import patch, MagicMock
import pytest
from index import fetch_aws_services, lambda_handler

@pytest.fixture
def mock_aws():
    """Mock AWS services."""
    with patch('boto3.resource') as mock_dynamodb, \
         patch('boto3.client') as mock_client:
        yield mock_dynamodb, mock_client

def test_fetch_services_success(mock_aws):
    """Test service fetching."""
    with patch('urllib3.PoolManager.request') as mock_request:
        mock_response = MagicMock()
        mock_response.status = 200
        mock_response.data = json.dumps({
            'services': {
                'service1': {},
                'service2': {}
            }
        }).encode('utf-8')
        mock_request.return_value = mock_response
        
        services = fetch_aws_services()
        assert len(services) == 2

def test_lambda_handler(mock_aws):
    """Test Lambda handler."""
    event = {}
    context = None
    result = lambda_handler(event, context)
    assert result['statusCode'] in [200, 500]

if __name__ == '__main__':
    pytest.main([__file__])
```

Run tests:

```bash
pytest lambda/test_index.py -v
```

### 3. Local Lambda Simulation

Use AWS SAM or localstack:

```bash
# Using AWS SAM
sam local invoke ServiceMonitorFunction --event event.json

# Or using localstack
docker run -d -p 4566:4566 localstack/localstack
```

### 4. Manual Testing

Create a test event file `test_event.json`:

```json
{
  "detail-type": "Scheduled Event",
  "source": "aws.events"
}
```

Invoke locally:

```python
import sys
sys.path.insert(0, 'lambda/')
from index import lambda_handler

event = {
    "detail-type": "Scheduled Event",
    "source": "aws.events"
}

# Mock AWS credentials
import os
os.environ['AWS_ACCESS_KEY_ID'] = 'testing'
os.environ['AWS_SECRET_ACCESS_KEY'] = 'testing'

result = lambda_handler(event, None)
print(json.dumps(result, indent=2))
```

## Testing Against Real AWS

### 1. Deploy to Test Account

Use a development or staging account first:

```bash
export AWS_PROFILE=staging
terraform init
terraform plan
terraform apply
```

### 2. Invoke Manually

```bash
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json
```

### 3. Check Results

```bash
# View response
cat response.json

# Check logs
aws logs tail /aws/lambda/aws-service-monitor --follow

# Verify DynamoDB updates
aws dynamodb scan --table-name aws-service-monitor-registry

# Check SCP updates
aws organizations describe-policy --policy-id p-xxxxx
```

## Advanced Customizations

### 1. Add Slack Notifications

Modify Lambda to send Slack messages:

```python
import requests

def send_slack_notification(new_services: List[str]) -> bool:
    """Send Slack notification."""
    webhook_url = os.environ['SLACK_WEBHOOK_URL']
    
    message = {
        'text': f'🆕 {len(new_services)} new AWS services detected',
        'blocks': [
            {
                'type': 'section',
                'text': {
                    'type': 'mrkdwn',
                    'text': f'*{len(new_services)} New Services Detected*'
                }
            },
            {
                'type': 'section',
                'text': {
                    'type': 'mrkdwn',
                    'text': '\n'.join([f'• {s}' for s in new_services])
                }
            }
        ]
    }
    
    response = requests.post(webhook_url, json=message)
    return response.status_code == 200
```

Update Terraform to store webhook URL as Lambda environment variable.

### 2. Add SNS Notifications

Modify Lambda to send SNS messages:

```python
import boto3

sns = boto3.client('sns')

def send_sns_notification(new_services: List[str]) -> bool:
    """Send SNS notification."""
    topic_arn = os.environ['SNS_TOPIC_ARN']
    
    message = f"""
    AWS Service Monitor Alert
    
    {len(new_services)} new services detected:
    
    {chr(10).join([f'- {s}' for s in new_services])}
    """
    
    response = sns.publish(
        TopicArn=topic_arn,
        Subject='AWS Service Monitor Alert',
        Message=message
    )
    
    return response.get('MessageId') is not None
```

### 3. Custom Service Filtering

Exclude certain service prefixes:

```python
def fetch_aws_services() -> Set[str]:
    """Fetch and filter services."""
    services = set()  # Your fetch logic
    
    # Exclude services starting with certain prefixes
    excluded_prefixes = ['aws', 'test']
    services = {
        s for s in services
        if not any(s.startswith(prefix) for prefix in excluded_prefixes)
    }
    
    return services
```

### 4. Service Grouping by Category

Group services by category in emails:

```python
SERVICE_CATEGORIES = {
    'compute': ['ec2', 'lambda', 'ecs', 'ek
s'],
    'storage': ['s3', 'ebs', 'efs', 'glacier'],
    'database': ['dynamodb', 'rds', 'elasticache'],
    # ... more categories
}

def categorize_services(services: List[str]) -> Dict[str, List[str]]:
    """Group services by category."""
    categories = {}
    
    for service in services:
        for category, service_list in SERVICE_CATEGORIES.items():
            if service in service_list:
                if category not in categories:
                    categories[category] = []
                categories[category].append(service)
                break
    
    return categories
```

## Code Quality

### 1. Format Code

```bash
# Using black
pip install black
black lambda/index.py

# Using autopep8
pip install autopep8
autopep8 --in-place lambda/index.py
```

### 2. Lint Code

```bash
# Using pylint
pip install pylint
pylint lambda/index.py

# Using flake8
pip install flake8
flake8 lambda/index.py
```

### 3. Type Checking

```bash
# Using mypy
pip install mypy
mypy lambda/index.py
```

## Debugging

### Enable Debug Logging

Add debug logging to Lambda:

```python
import logging

logger = logging.getLogger()
logger.setLevel(logging.DEBUG)

# In functions
logger.debug(f"Fetched {len(services)} services")
logger.info(f"Processing {len(new_services)} new services")
logger.warning("SCP not found")
logger.error(f"Failed to send email: {error}")
```

### View Lambda Logs

```bash
# Real-time logs
aws logs tail /aws/lambda/aws-service-monitor --follow

# Search for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/aws-service-monitor \
  --filter-pattern "ERROR"
```

### CloudWatch Insights

Run queries in CloudWatch Logs Insights:

```
fields @timestamp, @message
| filter @message like /ERROR/
| stats count() by @message
```

## Performance Optimization

### 1. Optimize Lambda Memory

Adjust in `main.tf`:

```hcl
# Increase memory for faster execution
memory_size = 512  # Default is 128, max is 10240
```

### 2. Optimize DynamoDB

For large service sets, consider provisioned capacity:

```hcl
resource "aws_dynamodb_table" "service_registry" {
  # Change from on-demand
  billing_mode = "PROVISIONED"
  read_capacity_units = 5
  write_capacity_units = 5
}
```

### 3. Cache Services

Cache the service list in Lambda:

```python
import json
from datetime import datetime, timedelta

service_cache = {
    'data': None,
    'timestamp': None,
    'ttl_minutes': 60
}

def get_services_cached() -> Set[str]:
    """Get services with caching."""
    now = datetime.utcnow()
    
    if service_cache['data'] and service_cache['timestamp']:
        age = (now - service_cache['timestamp']).total_seconds() / 60
        if age < service_cache['ttl_minutes']:
            return service_cache['data']
    
    services = fetch_aws_services()
    service_cache['data'] = services
    service_cache['timestamp'] = now
    return services
```

## Deploying Changes

After modifying Lambda code:

```bash
# Update and redeploy
terraform apply

# Or manually update just the function
zip -r lambda.zip lambda/
aws lambda update-function-code \
  --function-name aws-service-monitor \
  --zip-file fileb://lambda.zip \
  --region eu-west-2
```

## Version Control

### Commit Strategy

```bash
# Code changes
git add lambda/index.py
git commit -m "feat: add Slack notification support"

# Infrastructure changes
git add main.tf variables.tf
git commit -m "feat: add SNS topic for notifications"

# Don't commit:
# - terraform.tfvars (use terraform.tfvars.example instead)
# - lambda.zip (regenerated by terraform)
# - .terraform directory
```

### Branching

```bash
# Feature branch
git checkout -b feature/add-slack-support
# Make changes
git push origin feature/add-slack-support

# Create pull request for review
```

## Troubleshooting Development Issues

### Lambda Dependencies Not Found

Ensure `lambda/requirements.txt` has all dependencies and they're installed:

```bash
pip install -r lambda/requirements.txt
```

### Terraform Plan Shows Unnecessary Changes

```bash
terraform plan -refresh=false
```

### DynamoDB Local Development

Use local DynamoDB for testing:

```bash
# Using Docker
docker run -d -p 8000:8000 amazon/dynamodb-local

# Set endpoint in code
dynamodb = boto3.resource(
    'dynamodb',
    endpoint_url='http://localhost:8000'
)
```

## Service Approval & Allowlist Feature

The system includes an approval workflow for managing blacklisted services:

### How It Works

1. **Detection**: New services are detected automatically
2. **Approval Request**: Email sent to approval team if service needs review
3. **Approval**: Service added to `approved_services` list in configuration
4. **Exclusion**: Service removed from SCP deny list

### Key Functions

- `get_approved_services()`: Load approved services from config and DynamoDB
- `track_service_for_approval()`: Record service as pending approval
- `send_approval_request_email()`: Send approval request to team

### Customizing Approval Workflow

#### Disable Approval Emails

```hcl
# In terraform.tfvars
enable_service_approval_workflow = false
```

#### Change Approval Recipients

```hcl
# Send approval emails to specific team
approval_recipients = [
  "security-team@example.com",
  "infrastructure-team@example.com"
]
```

#### Pre-approve Services

```hcl
# Services detected but not added to SCP
approved_services = [
  "example-service",
  "another-approved-service"
]
```

#### Customize Approval Email

Edit the `send_approval_request_email()` function in `lambda/index.py`:

```python
def send_approval_request_email(service_name: str, timestamp: str) -> bool:
    """Customize this function to change approval email template."""
    subject = f"My Custom Subject: {service_name}"
    html_body = f"""
    <!-- Your custom HTML here -->
    """
    text_body = f"""
    Your custom text here
    """
    # ... rest of implementation
```

### Testing Approval Workflow

```python
# Test approval detection
import json
from lambda.index import get_approved_services, track_service_for_approval

# Simulate approved services
os.environ['APPROVED_SERVICES_LIST'] = json.dumps(['service1', 'service2'])
approved = get_approved_services()
print(f"Approved: {approved}")

# Track for approval
success = track_service_for_approval('test-service', '2026-04-29T08:15:33Z')
print(f"Tracked: {success}")
```

For more information, see [SERVICE_APPROVAL_MANAGEMENT.md](./runbooks/SERVICE_APPROVAL_MANAGEMENT.md).

## Regional Availability Monitoring

The system monitors when new AWS services become available in your target region (eu-west-2 by default). This provides early intelligence about what services AWS is bringing to market, even before they reach your region.

### How It Works

**Zero-Trust Approach:**
1. **Immediate Protection**: All new services are added to SCP blacklist immediately (cautious-by-default)
2. **Regional Intelligence**: System checks if service is available in your target region
3. **Pending Tracking**: Services not yet in region are recorded for daily monitoring
4. **Regional Alert**: When a pending service becomes available in region, you're notified

### Service Lifecycle

```
AWS Announces New Service
         ↓
    [DETECTED]
         ↓
    ┌────────────────────────┐
    │ Check Regional Avail.  │
    └────┬──────────┬────────┘
         │          │
      YES│          │NO
         │          │
    ┌────▼─┐    ┌───▼──────────────┐
    │ACTIVE│    │PENDING (Tracking)│ ← Daily monitoring
    │(SCP) │    │(Not in region)   │
    └──────┘    └───┬──────────────┘
                    │
              Region becomes available
                    │
                    ↓
              [NOTIFICATION SENT]
              Service now available
              for cost planning
```

### Key Features

**1. Strategic Intelligence**
- Know what services AWS is building before public announcements
- Track regional rollout patterns
- Plan for new service adoption

**2. Pending Service Monitoring**
- Services not yet in your region are automatically tracked
- Daily checks detect when they become available
- Email notification sent when pending service arrives

**3. Email Notifications**

Two types of emails are sent:

**Email 1: New Service Detected**
```
Subject: AWS Service Monitor: X New Service(s) Detected

SCP Status: ✅ Added to blacklist (immediately)

Regional Status (eu-west-2):
  Available in eu-west-2: 2/3
  Pending eu-west-2 deployment: 1/3

Services:
  - bedrock-agents (Available now)
  - sagemaker-canvas (Pending eu-west-2)
  - transcribe-streaming (Available now)
```

**Email 2: Service Now Available in Region** (sent later when pending service arrives)
```
Subject: ✅ AWS Service Now Available in eu-west-2: sagemaker-canvas

Service sagemaker-canvas is now available in your region.

Status: Service is already protected by SCP (added on detection date)
Date Available: 2026-06-26 08:15 UTC

This is for cost tracking and operational planning purposes.
No SCP changes are needed - the service has been blocked since first detection.
```

### Configuration

Regional monitoring is enabled by default. To customize:

#### Enable/Disable Regional Monitoring

```python
# In lambda/index.py environment (set via Terraform):
ENABLE_REGIONAL_MONITORING = "true"  # Set to "false" to disable
MONITORED_REGION = "eu-west-2"      # Change to monitor different region
```

#### Monitor Different Region

To monitor a different region (e.g., us-east-1):

```hcl
# In Terraform, update Lambda environment:
environment {
  variables = {
    MONITORED_REGION = "us-east-1"
  }
}
```

**Note**: Regional monitoring requires DynamoDB access and boto3 service endpoint checking.

### Data Storage

Pending services are tracked in `aws-service-monitor-pending-regional` DynamoDB table:

| Field | Purpose |
|-------|---------|
| `service_name` | Service identifier (partition key) |
| `detected_at` | When service was detected globally (sort key) |
| `first_detected_at` | First detection timestamp |
| `region_name` | Target region (e.g., "eu-west-2") |
| `available_in_region` | Boolean: 0=not available, 1=available |
| `last_checked_at` | Most recent availability check |
| `available_at` | When service became available in region |
| `notification_sent` | Boolean: whether alert was sent |

**Access Pattern**: Query by `region_name` and `available_in_region` to find pending services for daily monitoring.

### Core Functions

**Check Regional Availability**
```python
def check_regional_availability(services: List[str], region: str = 'eu-west-2') -> Dict:
    """
    Check if services are available in a region.
    Returns dict: {'service_name': {'available_in_region': bool, 'checked_at': timestamp}}
    """
```

**Track for Monitoring**
```python
def track_service_for_regional_monitoring(service_name: str, region: str, detected_at: str) -> bool:
    """Record service in pending table for daily monitoring."""
```

**Daily Monitoring Check**
```python
def check_pending_regional_services(timestamp: str) -> Dict:
    """
    Run daily to check if pending services have become available.
    Returns: {'available': [...], 'still_pending': [...], 'errors': [...]}
    """
```

**Send Region Available Alert**
```python
def send_regional_availability_notification(service_name: str, timestamp: str) -> bool:
    """Send email when pending service becomes available in region."""
```

### Testing Regional Monitoring

#### 1. Test Regional Availability Check

```python
import json
from lambda.index import check_regional_availability

# Check if services are available in eu-west-2
services = ['s3', 'lambda', 'bedrock']
result = check_regional_availability(services, region='eu-west-2')

for service, status in result.items():
    print(f"{service}: {status['available_in_region']}")
```

#### 2. Test Pending Service Tracking

```python
from lambda.index import track_service_for_regional_monitoring

# Track a service as pending
success = track_service_for_regional_monitoring(
    service_name='test-service',
    region='eu-west-2',
    detected_at='2026-06-11T08:15:33Z'
)

print(f"Tracked: {success}")

# Verify in DynamoDB
aws dynamodb get-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{"service_name":{"S":"test-service"},"detected_at":{"S":"2026-06-11T08:15:33Z"}}'
```

#### 3. Test Daily Monitoring

```python
from lambda.index import check_pending_regional_services
from datetime import datetime

# Run pending service check
timestamp = datetime.utcnow().isoformat()
summary = check_pending_regional_services(timestamp)

print(f"Available: {summary['available']}")
print(f"Still pending: {summary['still_pending']}")
print(f"Errors: {summary['errors']}")
```

#### 4. Integration Test: Full Flow

```bash
# 1. Deploy to test account
terraform apply -var-file=test.tfvars

# 2. Invoke Lambda manually
aws lambda invoke \
  --function-name aws-service-monitor \
  --region eu-west-2 \
  response.json

# 3. Check CloudWatch logs for regional monitoring activity
aws logs tail /aws/lambda/aws-service-monitor --follow --since 5m

# Expected log output:
# INFO: === CHECKING PENDING REGIONAL SERVICES ===
# INFO: Checking 3 pending services for regional availability
# INFO: Service bedrock-agents is now available in eu-west-2
# INFO: Sent regional availability notification for bedrock-agents
```

#### 5. Query Pending Services

```bash
# Find all services pending in eu-west-2
aws dynamodb query \
  --table-name aws-service-monitor-pending-regional \
  --index-name region-name-index \
  --key-condition-expression 'region_name = :region AND available_in_region = :available' \
  --expression-attribute-values '{
    ":region":{"S":"eu-west-2"},
    ":available":{"N":"0"}
  }' \
  --region eu-west-2
```

### Troubleshooting

#### Services Not Being Tracked as Pending

**Symptoms**: Regional status email section shows 0 pending services

**Check**:
1. Verify `ENABLE_REGIONAL_MONITORING = "true"` in Lambda environment
2. Check Lambda logs for regional availability check errors
3. Verify `pending_regional_services` table exists: `aws dynamodb describe-table --table-name aws-service-monitor-pending-regional`

**Solution**: Ensure new services are actually unavailable in the region. Some services may be available globally in all regions.

#### Regional Availability Notification Not Sent

**Symptoms**: Service becomes available in region but no email received

**Check**:
1. Verify `PENDING_REGIONAL_SERVICES_TABLE` is set correctly
2. Check Lambda logs for notification sending errors
3. Verify email addresses are verified in SES

**Solution**: 
```bash
# Check pending service status in DynamoDB
aws dynamodb get-item \
  --table-name aws-service-monitor-pending-regional \
  --key '{"service_name":{"S":"service-name"},"detected_at":{"S":"timestamp"}}'

# Check notification_sent field - should be true if notified
```

#### Regional Availability Check Failing

**Symptoms**: Lambda logs show regional availability check errors

**Check**:
1. Lambda has permissions to call boto3 (should be automatic)
2. boto3 service model is available for the service

**Solution**: Regional checks are graceful - if boto3 check fails, service defaults to "not available" and is tracked for monitoring.

### Performance Considerations

**Regional Availability Checking**
- Boto3 client creation: ~50-100ms per service
- For 100 new services: ~5-10 seconds total
- Checks are performed in serial (not parallel) to avoid rate limiting

**DynamoDB Operations**
- Pending service tracking: 1 write per service (billed as single write)
- Daily monitoring queries: 1 query + updates (on-demand billing)
- Expected cost: <$1/month for typical deployments

**Recommendations**
- Keep `ENABLE_REGIONAL_MONITORING = true` (minimal overhead)
- Regional checks run in series with other Lambda operations
- No additional Lambda memory or timeout needed

### Advanced Customization

#### Change Email Template for Regional Status

Edit `generate_html_email()` and `generate_text_email()` in `lambda/index.py`:

```python
def generate_html_email(services, timestamp, scp_status, regional_status):
    # Customize how regional status appears in email
    if regional_status:
        available_count = sum(1 for s in regional_status.values() 
                             if s['available_in_region'])
        # Add custom HTML section here
```

#### Filter Services from Regional Monitoring

To exclude certain services from pending tracking:

```python
def track_service_for_regional_monitoring(service_name, region, detected_at):
    # Skip services that shouldn't be monitored
    excluded = {'s3', 'iam', 'cloudfront'}
    if service_name in excluded:
        return True
    
    # Continue with normal tracking...
```

#### Change Regional Availability Check Logic

Replace boto3 logic with custom endpoint check:

```python
def check_regional_availability(services, region='eu-west-2'):
    # Custom logic: check AWS API endpoints, SSM parameters, etc.
    # Example: Check if service endpoint exists in target region
    result = {}
    for service in services:
        available = custom_check_service_in_region(service, region)
        result[service] = {
            'available_in_region': available,
            'checked_at': datetime.utcnow().isoformat()
        }
    return result
```

### Related Documentation

- [Operational Runbooks](./runbooks/) - Procedures for managing pending services
- [SERVICE_APPROVAL_MANAGEMENT.md](./runbooks/SERVICE_APPROVAL_MANAGEMENT.md) - Approval workflow guide
- [ARCHITECTURE.md](./ARCHITECTURE.md) - System design and data flow
- [TESTING_GUIDE.md](./TESTING_GUIDE.md) - Manual testing procedures

## Related Documentation

- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
- [boto3 Documentation](https://boto3.amazonaws.com/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Organizations Service Control Policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
