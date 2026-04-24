import json
import os
import boto3
import requests
import logging
import re
import copy
from datetime import datetime
from typing import List, Dict, Set, Tuple

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
organizations = boto3.client('organizations')
ses = boto3.client('ses')

DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
SCP_NAME = os.environ['SCP_NAME']
EMAIL_RECIPIENTS = json.loads(os.environ['EMAIL_RECIPIENTS'])
SENDER_EMAIL = os.environ['SENDER_EMAIL']
REQUIRE_APPROVAL = os.environ.get('REQUIRE_APPROVAL', 'true').lower() == 'true'

SERVICE_REFERENCE_URL = "https://servicereference.us-east-1.amazonaws.com/"
SERVICE_NAME_PATTERN = re.compile(r'^[a-z0-9\-]+$')
MAX_SERVICE_NAME_LENGTH = 30


def fetch_aws_services() -> Set[str]:
    """Fetch AWS services with HTTPS certificate validation."""
    try:
        response = requests.get(
            SERVICE_REFERENCE_URL,
            timeout=30,
            verify=True  # Enforce HTTPS certificate validation
        )
        response.raise_for_status()
        data = response.json()

        services = set()
        if isinstance(data, dict):
            if 'services' in data:
                services = set(data['services'].keys())
            else:
                services = set(data.keys())

        logger.info(f"Fetched {len(services)} services from AWS reference")
        return services

    except requests.exceptions.SSLError as e:
        logger.error(f"SSL certificate validation failed: {str(e)}")
        return set()
    except requests.exceptions.RequestException as e:
        logger.error(f"Failed to fetch AWS services: {str(e)}")
        return set()
    except (json.JSONDecodeError, KeyError) as e:
        logger.error(f"Failed to parse service reference response: {str(e)}")
        return set()


def get_tracked_services() -> Set[str]:
    """Get the set of previously tracked services from DynamoDB."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.scan()

        tracked = set()
        for item in response.get('Items', []):
            tracked.add(item['service_name'])

        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            for item in response.get('Items', []):
                tracked.add(item['service_name'])

        logger.info(f"Retrieved {len(tracked)} tracked services from DynamoDB")
        return tracked

    except Exception as e:
        logger.error(f"Error getting tracked services: {str(e)}")
        return set()


def validate_service_names(services: Set[str]) -> Tuple[Set[str], List[str]]:
    """Validate service names against AWS naming conventions."""
    valid_services = set()
    invalid_services = []

    for service in services:
        # Check format: lowercase alphanumeric + hyphens
        if not SERVICE_NAME_PATTERN.match(service):
            invalid_services.append(f"{service} (invalid format)")
            continue

        # Check length
        if len(service) > MAX_SERVICE_NAME_LENGTH:
            invalid_services.append(f"{service} (exceeds max length {MAX_SERVICE_NAME_LENGTH})")
            continue

        # Check minimum length (avoid very short names)
        if len(service) < 2:
            invalid_services.append(f"{service} (too short)")
            continue

        valid_services.add(service)

    if invalid_services:
        logger.warning(f"Found {len(invalid_services)} invalid services: {invalid_services}")

    return valid_services, invalid_services


def validate_policy_document(policy_document: Dict) -> Tuple[bool, str]:
    """Validate IAM policy document syntax and structure."""
    try:
        # Check required fields
        if 'Statement' not in policy_document:
            return False, "Missing 'Statement' field"

        if not isinstance(policy_document['Statement'], list):
            return False, "'Statement' must be a list"

        if len(policy_document['Statement']) == 0:
            return False, "'Statement' cannot be empty"

        # Validate each statement
        for idx, statement in enumerate(policy_document['Statement']):
            if not isinstance(statement, dict):
                return False, f"Statement {idx} is not a dictionary"

            if 'Effect' not in statement:
                return False, f"Statement {idx} missing 'Effect'"

            if statement['Effect'] not in ['Allow', 'Deny']:
                return False, f"Statement {idx} invalid Effect: {statement['Effect']}"

            if 'Action' not in statement:
                return False, f"Statement {idx} missing 'Action'"

            if 'Resource' not in statement:
                return False, f"Statement {idx} missing 'Resource'"

        # Validate JSON serializability
        json.dumps(policy_document)

        return True, "Valid"

    except json.JSONDecodeError as e:
        return False, f"Policy not JSON serializable: {str(e)}"
    except Exception as e:
        return False, f"Validation error: {str(e)}"


def store_new_services(services: List[str]) -> None:
    """Store new services in DynamoDB."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        timestamp = datetime.utcnow().isoformat()

        with table.batch_writer(batch_size=25) as batch:
            for service in services:
                batch.put_item(Item={
                    'service_name': service,
                    'first_seen': timestamp,
                    'last_updated': timestamp
                })

        print(f"Stored {len(services)} new services in DynamoDB")

    except Exception as e:
        print(f"Error storing services: {str(e)}")


def get_scp_policy() -> Dict:
    """Get the blacklist SCP policy."""
    try:
        policies = organizations.list_policies(Filter='SERVICE_CONTROL_POLICY')

        scp_id = None
        for policy in policies.get('Policies', []):
            if policy['Name'] == SCP_NAME:
                scp_id = policy['Id']
                break

        if not scp_id:
            print(f"SCP '{SCP_NAME}' not found")
            return None

        policy_details = organizations.describe_policy(PolicyId=scp_id)
        policy_content = json.loads(policy_details['Policy']['Content'])

        return {'id': scp_id, 'content': policy_content}

    except Exception as e:
        print(f"Error getting SCP policy: {str(e)}")
        return None


def generate_scp_preview(scp_policy: Dict, new_services: List[str]) -> Dict:
    """Generate a preview of SCP changes without updating."""
    policy_content = copy.deepcopy(scp_policy['content'])

    if 'Statement' not in policy_content:
        policy_content['Statement'] = []

    deny_statement = None
    for statement in policy_content['Statement']:
        if statement.get('Effect') == 'Deny':
            deny_statement = statement
            break

    if not deny_statement:
        deny_statement = {
            'Sid': 'DenyNewServices',
            'Effect': 'Deny',
            'Action': '*',
            'Resource': '*'
        }
        policy_content['Statement'].append(deny_statement)

    actions_before = len(deny_statement.get('Action', [])
                         if isinstance(deny_statement.get('Action'), list)
                         else [deny_statement.get('Action')])

    for service in new_services:
        service_action = f"{service.lower()}:*"
        if 'Action' not in deny_statement:
            deny_statement['Action'] = [service_action]
        elif service_action not in deny_statement['Action']:
            if isinstance(deny_statement['Action'], str):
                deny_statement['Action'] = [deny_statement['Action']]
            if service_action not in deny_statement['Action']:
                deny_statement['Action'].append(service_action)

    actions_after = len(deny_statement.get('Action', [])
                        if isinstance(deny_statement.get('Action'), list)
                        else [deny_statement.get('Action')])

    return {
        'policy_id': scp_policy['id'],
        'policy_name': SCP_NAME,
        'services_to_add': new_services,
        'actions_before': actions_before,
        'actions_after': actions_after,
        'preview_content': policy_content
    }


def update_scp_with_services(scp_policy: Dict, new_services: List[str]) -> Tuple[bool, str]:
    """Update SCP with validation and error handling."""
    try:
        policy_content = copy.deepcopy(scp_policy['content'])

        if 'Statement' not in policy_content:
            policy_content['Statement'] = []

        deny_statement = None
        for statement in policy_content['Statement']:
            if statement.get('Effect') == 'Deny':
                deny_statement = statement
                break

        if not deny_statement:
            deny_statement = {
                'Sid': 'DenyNewServices',
                'Effect': 'Deny',
                'Action': '*',
                'Resource': '*'
            }
            policy_content['Statement'].append(deny_statement)

        updated = False
        for service in new_services:
            service_action = f"{service.lower()}:*"
            if 'Action' not in deny_statement:
                deny_statement['Action'] = [service_action]
                updated = True
            elif service_action not in deny_statement['Action']:
                if isinstance(deny_statement['Action'], str):
                    deny_statement['Action'] = [deny_statement['Action']]
                if service_action not in deny_statement['Action']:
                    deny_statement['Action'].append(service_action)
                    updated = True

        if not updated:
            return False, "No changes needed"

        # Validate policy before updating
        is_valid, error = validate_policy_document(policy_content)
        if not is_valid:
            logger.error(f"Policy validation failed: {error}")
            return False, f"Policy validation failed: {error}"

        # Update policy
        organizations.update_policy(
            PolicyId=scp_policy['id'],
            Content=json.dumps(policy_content)
        )
        logger.info(f"Successfully updated SCP with {len(new_services)} new services")
        return True, "SCP updated successfully"

    except Exception as e:
        logger.error(f"Error updating SCP: {str(e)}")
        return False, f"Error updating SCP: {str(e)}"


def send_notification_email(new_services: List[str], scp_status: str = 'unknown') -> bool:
    """Send formatted email notification about new services."""
    try:
        timestamp = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')

        html_body = generate_html_email(new_services, timestamp, scp_status)
        text_body = generate_text_email(new_services, timestamp, scp_status)

        subject = f'AWS Service Monitor: {len(new_services)} New Service(s) Detected'

        for recipient in EMAIL_RECIPIENTS:
            ses.send_email(
                Source=SENDER_EMAIL,
                Destination={'ToAddresses': [recipient]},
                Message={
                    'Subject': {
                        'Data': subject,
                        'Charset': 'UTF-8'
                    },
                    'Body': {
                        'Text': {
                            'Data': text_body,
                            'Charset': 'UTF-8'
                        },
                        'Html': {
                            'Data': html_body,
                            'Charset': 'UTF-8'
                        }
                    }
                }
            )

        logger.info(f"Sent email notification to {len(EMAIL_RECIPIENTS)} recipient(s)")
        return True

    except Exception as e:
        logger.error(f"Error sending email: {str(e)}")
        return False


def get_scp_status_message(status: str) -> Tuple[str, str]:
    """Get status message and color for email."""
    status_messages = {
        'success': ('✅ SCP Updated', 'Services have been added to the SCP policy'),
        'pending_approval': ('⏳ Pending Approval', 'Changes are pending manual approval'),
        'failed': ('❌ SCP Update Failed', 'SCP update encountered an error'),
        'not_found': ('⚠️ SCP Not Found', 'Service Control Policy not found'),
        'not_attempted': ('ℹ️ Not Attempted', 'SCP update was not attempted'),
        'unknown': ('ℹ️ Unknown', 'SCP status unknown')
    }
    return status_messages.get(status, status_messages['unknown'])


def generate_html_email(services: List[str], timestamp: str, scp_status: str = 'unknown') -> str:
    """Generate formatted HTML email with proper escaping."""
    from html import escape
    services_html = '\n'.join([f'                <li>{escape(service)}</li>' for service in sorted(services)])
    status_title, status_message = get_scp_status_message(scp_status)

    html = f"""
    <html>
    <head>
        <style>
            body {{ font-family: Arial, sans-serif; color: #333; }}
            .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
            .header {{ background-color: #FF9900; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }}
            .content {{ background-color: #f5f5f5; padding: 20px; border-radius: 5px; }}
            .service-list {{ background-color: white; padding: 15px; border-left: 4px solid #FF9900; margin: 15px 0; }}
            .status-box {{ background-color: white; padding: 15px; border-left: 4px solid #007bff; margin: 15px 0; }}
            .status-title {{ font-weight: bold; font-size: 16px; }}
            .footer {{ color: #666; font-size: 12px; margin-top: 20px; }}
            h2 {{ color: #FF9900; margin-top: 0; }}
            ul {{ list-style-type: none; padding-left: 0; }}
            li {{ padding: 8px 0; border-bottom: 1px solid #eee; }}
            li:last-child {{ border-bottom: none; }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>AWS Service Monitor Alert</h1>
            </div>

            <div class="content">
                <h2>New AWS Services Detected</h2>

                <p>The AWS service monitoring job has identified <strong>{len(services)} new service(s)</strong> as of {timestamp}.</p>

                <div class="status-box">
                    <div class="status-title">{status_title}</div>
                    <p>{status_message}</p>
                </div>

                <div class="service-list">
                    <h3>New Services:</h3>
                    <ul>
{services_html}
                    </ul>
                </div>

                <p><strong>Actions Taken:</strong></p>
                <ul>
                    <li>✓ Service names validated</li>
                    <li>✓ Service registry updated in DynamoDB</li>
                    <li>✓ SCP change preview generated</li>
                    <li>✓ Notification email sent</li>
                </ul>

                <p><strong>Next Steps:</strong></p>
                <ul>
                    <li>Review the new services in the SCP</li>
                    <li>Verify organization policies are applied correctly</li>
                    <li>Monitor CloudWatch logs for any policy enforcement issues</li>
                    <li>Check AWS CloudTrail for policy modification events</li>
                </ul>
            </div>

            <div class="footer">
                <p>This is an automated notification from AWS Service Monitor running in your management account.</p>
                <p>Scan Time: {timestamp}</p>
            </div>
        </div>
    </body>
    </html>
    """

    return html


def generate_text_email(services: List[str], timestamp: str, scp_status: str = 'unknown') -> str:
    """Generate plain text email with proper escaping."""
    services_text = '\n'.join([f'  - {service}' for service in sorted(services)])
    status_title, status_message = get_scp_status_message(scp_status)

    text = f"""AWS SERVICE MONITOR ALERT
{"="*50}

New AWS Services Detected

The AWS service monitoring job has identified {len(services)} new service(s) as of {timestamp}.

STATUS: {status_title}
{status_message}

NEW SERVICES:
{services_text}

ACTIONS TAKEN:
  ✓ Service names validated
  ✓ Service registry updated in DynamoDB
  ✓ SCP change preview generated
  ✓ Notification email sent

NEXT STEPS:
  - Review the new services in the SCP
  - Verify organization policies are applied correctly
  - Monitor CloudWatch logs for any policy enforcement issues
  - Check AWS CloudTrail for policy modification events

{"="*50}
This is an automated notification from AWS Service Monitor.
Scan Time: {timestamp}
"""

    return text


def lambda_handler(event, context):
    """Main Lambda handler with security validation and approval workflows."""
    start_time = datetime.utcnow().isoformat()
    logger.info(f"Starting AWS service monitor at {start_time}")

    try:
        # Fetch current services from AWS reference
        current_services = fetch_aws_services()
        if not current_services:
            logger.error("No services fetched from AWS reference")
            return {
                'statusCode': 500,
                'body': json.dumps({'error': 'Failed to fetch AWS services'})
            }

        # Get previously tracked services
        tracked_services = get_tracked_services()

        # Identify new services
        new_services = current_services - tracked_services

        logger.info(f"Total services: {len(current_services)}")
        logger.info(f"Tracked services: {len(tracked_services)}")
        logger.info(f"New services: {len(new_services)}")

        if new_services:
            # Validate service names
            valid_services, invalid_services = validate_service_names(new_services)

            if not valid_services:
                logger.error(f"All services failed validation: {invalid_services}")
                return {
                    'statusCode': 400,
                    'body': json.dumps({
                        'error': 'All services failed validation',
                        'invalid_services': invalid_services
                    })
                }

            new_services_list = sorted(list(valid_services))

            # Store new services in DynamoDB
            store_new_services(new_services_list)

            # Get SCP policy
            scp_policy = get_scp_policy()
            scp_update_status = 'not_attempted'
            scp_error = None

            if scp_policy:
                # Generate preview first
                preview = generate_scp_preview(scp_policy, new_services_list)

                if REQUIRE_APPROVAL:
                    logger.info("Approval required - storing preview for manual review")
                    scp_update_status = 'pending_approval'
                    # Store preview in DynamoDB for approval workflow
                    store_pending_scp_update(preview)
                else:
                    # Update SCP with validation
                    success, message = update_scp_with_services(scp_policy, new_services_list)
                    scp_update_status = 'success' if success else 'failed'
                    scp_error = message if not success else None
                    logger.info(f"SCP update result: {message}")
            else:
                logger.warning(f"SCP '{SCP_NAME}' not found")
                scp_update_status = 'not_found'

            # Send notification email
            send_notification_email(new_services_list, scp_update_status)

            response = {
                'statusCode': 200,
                'body': {
                    'message': f'Processed {len(new_services_list)} new services',
                    'new_services': new_services_list,
                    'scp_status': scp_update_status,
                    'invalid_services': invalid_services if invalid_services else None,
                    'scan_time': start_time
                }
            }

            if scp_error:
                response['body']['scp_error'] = scp_error

            return {
                'statusCode': response['statusCode'],
                'body': json.dumps(response['body'])
            }
        else:
            logger.info("No new services detected")
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'No new services detected',
                    'scan_time': start_time
                })
            }

    except Exception as e:
        logger.exception(f"Unexpected error in lambda_handler: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': 'Internal server error',
                'details': str(e)
            })
        }


def store_pending_scp_update(preview: Dict) -> None:
    """Store pending SCP update for approval workflow."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        timestamp = datetime.utcnow().isoformat()

        table.put_item(Item={
            'service_name': f"__pending_scp_update__{timestamp}",
            'first_seen': timestamp,
            'last_updated': timestamp,
            'preview': preview,
            'status': 'pending_approval'
        })

        logger.info(f"Stored pending SCP update for approval")

    except Exception as e:
        logger.error(f"Error storing pending SCP update: {str(e)}")
