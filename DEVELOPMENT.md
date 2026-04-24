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
  --region us-east-1 \
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
  --region us-east-1
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

## Related Documentation

- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
- [boto3 Documentation](https://boto3.amazonaws.com/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Organizations Service Control Policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
