import json
import os
import pytest
import hashlib
from datetime import datetime
from unittest.mock import patch, MagicMock, call
from moto import mock_dynamodb, mock_s3, mock_ses
import boto3

# Set up environment variables before importing the handler
os.environ['DYNAMODB_TABLE'] = 'test-registry'
os.environ['SCP_NAME'] = 'blacklist'
os.environ['EMAIL_RECIPIENTS'] = '["ops@example.com"]'
os.environ['SENDER_EMAIL'] = 'monitor@example.com'
os.environ['REQUIRE_APPROVAL'] = 'false'
os.environ['BASELINE_SNAPSHOT_BUCKET'] = 'test-baseline-bucket'
os.environ['ALERT_TOPIC_ARN'] = 'arn:aws:sns:us-east-1:123456789012:alerts'

# Import handler after environment setup
import sys
sys.path.insert(0, os.path.dirname(__file__))
from index import (
    lambda_handler,
    fetch_aws_services,
    initialize_baseline,
    get_tracked_services,
    calculate_baseline_checksum,
    send_notification_email,
    BASELINE_MARKER
)


@pytest.fixture
def aws_credentials():
    """Set up mock AWS credentials."""
    os.environ['AWS_ACCESS_KEY_ID'] = 'testing'
    os.environ['AWS_SECRET_ACCESS_KEY'] = 'testing'
    os.environ['AWS_SECURITY_TOKEN'] = 'testing'
    os.environ['AWS_SESSION_TOKEN'] = 'testing'
    os.environ['AWS_DEFAULT_REGION'] = 'us-east-1'


@pytest.fixture
def dynamodb_table(aws_credentials):
    """Create a mock DynamoDB table for testing."""
    with mock_dynamodb():
        dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
        table = dynamodb.create_table(
            TableName='test-registry',
            KeySchema=[{'AttributeName': 'service_name', 'KeyType': 'HASH'}],
            AttributeDefinitions=[{'AttributeName': 'service_name', 'AttributeType': 'S'}],
            BillingMode='PAY_PER_REQUEST'
        )
        yield table


@pytest.fixture
def s3_bucket(aws_credentials):
    """Create a mock S3 bucket for baseline snapshots."""
    with mock_s3():
        s3 = boto3.client('s3', region_name='us-east-1')
        s3.create_bucket(Bucket='test-baseline-bucket')
        yield s3


@pytest.fixture
def ses_client(aws_credentials):
    """Create a mock SES client for email testing."""
    with mock_ses():
        ses = boto3.client('ses', region_name='us-east-1')
        # Verify email addresses in SES
        ses.verify_email_identity(EmailAddress='monitor@example.com')
        ses.verify_email_identity(EmailAddress='ops@example.com')
        yield ses


def create_baseline_with_services(table, services):
    """Helper to create baseline in DynamoDB."""
    timestamp = datetime.utcnow().isoformat()
    checksum = calculate_baseline_checksum(set(services))

    # Create baseline marker
    table.put_item(
        Item={
            'service_name': BASELINE_MARKER,
            'first_seen': timestamp,
            'last_updated': timestamp,
            'status': 'initialized',
            'service_count': len(services),
            'checksum': checksum
        }
    )

    # Add services
    with table.batch_writer() as batch:
        for service in services:
            batch.put_item(Item={
                'service_name': service,
                'first_seen': timestamp,
                'last_updated': timestamp,
                'is_baseline': True
            })

    return checksum


def update_baseline_checksum(table, new_checksum):
    """Update the baseline checksum after removing services."""
    table.update_item(
        Key={'service_name': BASELINE_MARKER},
        UpdateExpression='SET checksum = :checksum',
        ExpressionAttributeValues={':checksum': new_checksum}
    )


class TestNewServiceDetectionWithoutSCP:
    """Test new service detection when SCP management is disabled."""

    @patch('index.MANAGE_SCP_POLICY', False)
    @patch('index.fetch_aws_services')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_detect_new_service_no_scp(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_fetch_services,
        dynamodb_table
    ):
        """Test detection of 1 new service without SCP management."""
        # Setup baseline with initial services
        initial_services = ['ec2', 's3', 'lambda', 'dynamodb', 'rds']
        create_baseline_with_services(dynamodb_table, initial_services)

        # Simulate new services (add 1 new service)
        current_services = initial_services + ['sagemaker']
        mock_fetch_services.return_value = set(current_services)
        mock_send_email.return_value = True

        # Invoke Lambda
        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        # Assertions
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert 'new_services' in body
        assert 'sagemaker' in body['new_services']
        assert body['scp_status'] == 'disabled'
        assert mock_send_email.called

        # Verify email was sent with correct status
        call_args = mock_send_email.call_args
        assert call_args[0][0] == ['sagemaker']  # new_services
        assert call_args[0][1] == 'disabled'  # scp_status

    @patch('index.MANAGE_SCP_POLICY', False)
    @patch('index.fetch_aws_services')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_detect_multiple_new_services_no_scp(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_fetch_services,
        dynamodb_table
    ):
        """Test detection of multiple new services without SCP management."""
        initial_services = ['ec2', 's3', 'lambda']
        create_baseline_with_services(dynamodb_table, initial_services)

        # Add 3 new services
        new_additions = ['sagemaker', 'bedrock', 'textract']
        current_services = initial_services + new_additions
        mock_fetch_services.return_value = set(current_services)
        mock_send_email.return_value = True

        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert len(body['new_services']) == 3
        assert all(svc in body['new_services'] for svc in new_additions)
        assert body['scp_status'] == 'disabled'


class TestNewServiceDetectionWithSCP:
    """Test new service detection when SCP management is enabled."""

    @patch('index.MANAGE_SCP_POLICY', True)
    @patch('index.REQUIRE_APPROVAL', False)
    @patch('index.fetch_aws_services')
    @patch('index.get_scp_policy')
    @patch('index.update_scp_with_services')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_detect_new_service_with_scp_success(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_update_scp,
        mock_get_scp,
        mock_fetch_services,
        dynamodb_table
    ):
        """Test detection and SCP update succeeds."""
        # Setup
        initial_services = ['ec2', 's3', 'lambda', 'dynamodb']
        create_baseline_with_services(dynamodb_table, initial_services)

        # Mock AWS service fetch
        current_services = initial_services + ['sagemaker']
        mock_fetch_services.return_value = set(current_services)

        # Mock SCP operations
        mock_get_scp.return_value = {
            'id': 'p-test123',
            'name': 'blacklist',
            'content': {
                'Version': '2012-10-17',
                'Statement': [{'Sid': 'DenyServices', 'Effect': 'Deny', 'Action': '*', 'Resource': '*'}]
            }
        }
        mock_update_scp.return_value = (True, 'SCP updated successfully')
        mock_send_email.return_value = True

        # Invoke
        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        # Verify
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['scp_status'] == 'success'
        assert 'sagemaker' in body['new_services']

        # Verify email was sent with success status
        mock_send_email.assert_called_once()
        assert mock_send_email.call_args[0][1] == 'success'

    @patch('index.MANAGE_SCP_POLICY', True)
    @patch('index.REQUIRE_APPROVAL', False)
    @patch('index.fetch_aws_services')
    @patch('index.get_scp_policy')
    @patch('index.update_scp_with_services')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_detect_new_service_scp_update_fails(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_update_scp,
        mock_get_scp,
        mock_fetch_services,
        dynamodb_table
    ):
        """Test detection works but SCP update fails - should send warning email."""
        initial_services = ['ec2', 's3', 'lambda']
        create_baseline_with_services(dynamodb_table, initial_services)

        current_services = initial_services + ['bedrock']
        mock_fetch_services.return_value = set(current_services)

        # Mock SCP operations
        mock_get_scp.return_value = {
            'id': 'p-test123',
            'name': 'blacklist',
            'content': {'Version': '2012-10-17', 'Statement': []}
        }
        # SCP update fails
        mock_update_scp.return_value = (False, 'Permission denied on UpdatePolicy')
        mock_send_email.return_value = True

        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        # Verify - detection still succeeds, services are stored, but SCP status is failed
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['scp_status'] == 'failed'
        assert 'scp_error' in body
        assert 'bedrock' in body['new_services']

        # Verify email was sent with failed status (warning)
        mock_send_email.assert_called_once()
        assert mock_send_email.call_args[0][1] == 'failed'

    @patch('index.MANAGE_SCP_POLICY', True)
    @patch('index.REQUIRE_APPROVAL', False)
    @patch('index.fetch_aws_services')
    @patch('index.get_scp_policy')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_detect_new_service_scp_not_found(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_get_scp,
        mock_fetch_services,
        dynamodb_table
    ):
        """Test SCP policy not found - sends warning email."""
        initial_services = ['ec2', 's3']
        create_baseline_with_services(dynamodb_table, initial_services)

        current_services = initial_services + ['textract']
        mock_fetch_services.return_value = set(current_services)

        # SCP not found
        mock_get_scp.return_value = None
        mock_send_email.return_value = True

        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['scp_status'] == 'not_found'

        # Email should still be sent indicating SCP not found
        mock_send_email.assert_called_once()
        assert mock_send_email.call_args[0][1] == 'not_found'


class TestEmailNotifications:
    """Test email notification sending for different scenarios."""

    @patch('index.ses')
    @patch('index.sns')
    def test_success_email_with_scp_enabled(self, mock_sns, mock_ses):
        """Test success email contains SCP-related content when enabled."""
        mock_ses.send_email = MagicMock()

        with patch('index.EMAIL_RECIPIENTS', ['ops@example.com']):
            with patch('index.SENDER_EMAIL', 'monitor@example.com'):
                result = send_notification_email(['sagemaker', 'bedrock'], 'success')

        assert result is True
        assert mock_ses.send_email.called
        call_args = mock_ses.send_email.call_args
        email_data = call_args[1]

        # Verify email structure
        assert email_data['Source'] == 'monitor@example.com'
        assert email_data['Destination']['ToAddresses'] == ['ops@example.com']
        assert '2 New Service(s) Detected' in email_data['Message']['Subject']['Data']

        # Verify HTML body contains service names and SCP info
        html_body = email_data['Message']['Body']['Html']['Data']
        assert 'sagemaker' in html_body
        assert 'bedrock' in html_body

    @patch('index.ses')
    @patch('index.sns')
    def test_warning_email_with_scp_failed(self, mock_sns, mock_ses):
        """Test warning email when SCP update fails."""
        mock_ses.send_email = MagicMock()

        with patch('index.EMAIL_RECIPIENTS', ['ops@example.com']):
            with patch('index.SENDER_EMAIL', 'monitor@example.com'):
                result = send_notification_email(['textract'], 'failed')

        assert result is True
        assert mock_ses.send_email.called

        email_data = mock_ses.send_email.call_args[1]
        html_body = email_data['Message']['Body']['Html']['Data']
        text_body = email_data['Message']['Body']['Text']['Data']

        # Should contain warning/failure indication
        assert 'textract' in html_body

    @patch('index.ses')
    @patch('index.sns')
    def test_notification_email_disabled_scp_mode(self, mock_sns, mock_ses):
        """Test email when SCP management is disabled (notifications-only mode)."""
        mock_ses.send_email = MagicMock()

        with patch('index.EMAIL_RECIPIENTS', ['ops@example.com']):
            with patch('index.SENDER_EMAIL', 'monitor@example.com'):
                result = send_notification_email(['service1', 'service2'], 'disabled')

        assert result is True
        email_data = mock_ses.send_email.call_args[1]
        html_body = email_data['Message']['Body']['Html']['Data']
        text_body = email_data['Message']['Body']['Text']['Data']

        # Should indicate notifications-only mode
        assert 'service1' in html_body
        assert 'service2' in html_body

    @patch('index.ses')
    @patch('index.sns')
    def test_email_to_multiple_recipients(self, mock_sns, mock_ses):
        """Test email is sent to all configured recipients."""
        mock_ses.send_email = MagicMock()
        recipients = ['ops@example.com', 'security@example.com', 'devops@example.com']

        with patch('index.EMAIL_RECIPIENTS', recipients):
            with patch('index.SENDER_EMAIL', 'monitor@example.com'):
                result = send_notification_email(['service1'], 'success')

        assert result is True
        # Verify send_email called once per recipient
        assert mock_ses.send_email.call_count == len(recipients)

        # Verify each recipient got an email
        sent_to = [call_obj[1]['Destination']['ToAddresses'][0]
                   for call_obj in mock_ses.send_email.call_args_list]
        assert sent_to == recipients


class TestBaselineIntegrity:
    """Test baseline integrity checking and tampering detection."""

    @patch('index.fetch_aws_services')
    @patch('index.send_tamper_alert_email')
    @patch('index.send_integrity_alert_sns')
    @patch('index.publish_metrics')
    def test_baseline_tampering_detection(
        self,
        mock_publish_metrics,
        mock_alert_sns,
        mock_alert_email,
        mock_fetch_services,
        dynamodb_table
    ):
        """Test detection of baseline tampering (checksum mismatch)."""
        initial_services = ['ec2', 's3', 'lambda']
        create_baseline_with_services(dynamodb_table, initial_services)

        # Simulate tampering: remove a service without updating checksum
        table = dynamodb_table
        table.delete_item(Key={'service_name': 'lambda'})
        # Don't update checksum - this creates tampering scenario

        current_services = initial_services  # Fetch returns original
        mock_fetch_services.return_value = set(current_services)

        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        # Should detect tampering
        assert response['statusCode'] == 500
        assert 'integrity' in response['body'].lower() or 'tamper' in response['body'].lower()
        assert mock_alert_email.called
        assert mock_alert_sns.called


class TestServiceRemovalAndRediscovery:
    """Test the scenario in the requirement: remove service, trigger lambda to rediscover."""

    @patch('index.MANAGE_SCP_POLICY', True)
    @patch('index.REQUIRE_APPROVAL', False)
    @patch('index.fetch_aws_services')
    @patch('index.get_scp_policy')
    @patch('index.update_scp_with_services')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_remove_service_and_rediscover_with_scp(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_update_scp,
        mock_get_scp,
        mock_fetch_services,
        dynamodb_table
    ):
        """
        Test the full workflow:
        1. Remove a service from baseline
        2. Trigger Lambda
        3. Verify new service detection
        4. Verify email sent with success status
        """
        # Step 1: Initialize baseline with known services
        initial_services = ['ec2', 's3', 'lambda', 'dynamodb', 'rds', 'sagemaker']
        create_baseline_with_services(dynamodb_table, initial_services)

        # Step 2: Remove one service from DynamoDB (simulate removal)
        dynamodb_table.delete_item(Key={'service_name': 'sagemaker'})

        # Step 3: Update baseline checksum to match the new state (without sagemaker)
        services_after_removal = ['ec2', 's3', 'lambda', 'dynamodb', 'rds']
        new_checksum = calculate_baseline_checksum(set(services_after_removal))
        update_baseline_checksum(dynamodb_table, new_checksum)

        # Step 4: Mock AWS service fetch - it returns original services (sagemaker is back)
        mock_fetch_services.return_value = set(initial_services)

        # Step 5: Mock SCP operations
        mock_get_scp.return_value = {
            'id': 'p-blacklist-123',
            'name': 'blacklist',
            'content': {
                'Version': '2012-10-17',
                'Statement': [{
                    'Sid': 'DenyServices',
                    'Effect': 'Deny',
                    'Action': ['ec2:*', 's3:*', 'lambda:*', 'dynamodb:*', 'rds:*'],
                    'Resource': '*'
                }]
            }
        }
        mock_update_scp.return_value = (True, 'SCP updated with sagemaker:*')
        mock_send_email.return_value = True

        # Step 6: Invoke Lambda
        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        # Step 7: Verify results
        assert response['statusCode'] == 200
        body = json.loads(response['body'])

        # Verify service was rediscovered
        assert 'sagemaker' in body['new_services']
        assert len(body['new_services']) == 1

        # Verify SCP was updated
        assert body['scp_status'] == 'success'
        assert mock_update_scp.called

        # Verify success email was sent
        assert mock_send_email.called
        call_args = mock_send_email.call_args
        assert call_args[0][0] == ['sagemaker']  # new_services
        assert call_args[0][1] == 'success'  # scp_status

    @patch('index.MANAGE_SCP_POLICY', False)
    @patch('index.fetch_aws_services')
    @patch('index.send_notification_email')
    @patch('index.publish_metrics')
    def test_remove_service_and_rediscover_without_scp(
        self,
        mock_publish_metrics,
        mock_send_email,
        mock_fetch_services,
        dynamodb_table
    ):
        """
        Test removal and rediscovery WITHOUT SCP management:
        1. Remove a service from baseline
        2. Trigger Lambda
        3. Verify new service detection
        4. Verify email sent with 'disabled' status (no SCP action)
        """
        # Initialize baseline
        initial_services = ['ec2', 's3', 'lambda', 'dynamodb', 'rds', 'bedrock']
        create_baseline_with_services(dynamodb_table, initial_services)

        # Remove bedrock service
        dynamodb_table.delete_item(Key={'service_name': 'bedrock'})

        # Update checksum
        services_after_removal = ['ec2', 's3', 'lambda', 'dynamodb', 'rds']
        new_checksum = calculate_baseline_checksum(set(services_after_removal))
        update_baseline_checksum(dynamodb_table, new_checksum)

        # Mock service fetch returns original (bedrock is back)
        mock_fetch_services.return_value = set(initial_services)
        mock_send_email.return_value = True

        # Invoke
        with patch('index.dynamodb') as mock_ddb:
            mock_ddb.Table.return_value = dynamodb_table
            with patch('index.organizations'):
                with patch('index.ses'):
                    with patch('index.cloudwatch'):
                        with patch('index.sns'):
                            response = lambda_handler({}, {})

        # Verify
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert 'bedrock' in body['new_services']
        assert body['scp_status'] == 'disabled'

        # Verify email was sent with disabled status
        mock_send_email.assert_called_once()
        assert mock_send_email.call_args[0][1] == 'disabled'


if __name__ == '__main__':
    pytest.main([__file__, '-v', '--tb=short'])
