import json
import os
import boto3
import urllib3
from datetime import datetime
from typing import List, Dict, Set

dynamodb = boto3.resource('dynamodb')
organizations = boto3.client('organizations')
ses = boto3.client('ses')

DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
SCP_NAME = os.environ['SCP_NAME']
EMAIL_RECIPIENTS = json.loads(os.environ['EMAIL_RECIPIENTS'])
SENDER_EMAIL = os.environ['SENDER_EMAIL']

SERVICE_REFERENCE_URL = "https://servicereference.us-east-1.amazonaws.com/"

http = urllib3.PoolManager()


def fetch_aws_services() -> Set[str]:
    """Fetch the list of AWS services from the service reference."""
    try:
        response = http.request('GET', SERVICE_REFERENCE_URL, timeout=30)
        if response.status != 200:
            print(f"Failed to fetch services: HTTP {response.status}")
            return set()

        data = json.loads(response.data.decode('utf-8'))

        # Extract service names from the reference
        # The structure typically contains services as keys
        services = set()
        if isinstance(data, dict):
            if 'services' in data:
                services = set(data['services'].keys())
            else:
                # If services are at the top level
                services = set(data.keys())

        print(f"Fetched {len(services)} services from AWS reference")
        return services

    except Exception as e:
        print(f"Error fetching AWS services: {str(e)}")
        return set()


def get_tracked_services() -> Set[str]:
    """Get the set of previously tracked services from DynamoDB."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.scan()

        tracked = set()
        for item in response.get('Items', []):
            tracked.add(item['service_name'])

        # Handle pagination
        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            for item in response.get('Items', []):
                tracked.add(item['service_name'])

        print(f"Retrieved {len(tracked)} tracked services from DynamoDB")
        return tracked

    except Exception as e:
        print(f"Error getting tracked services: {str(e)}")
        return set()


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


def update_scp_with_services(scp_policy: Dict, new_services: List[str]) -> bool:
    """Update the SCP to deny new services."""
    try:
        policy_content = scp_policy['content']

        # Ensure the policy has a Statement
        if 'Statement' not in policy_content:
            policy_content['Statement'] = []

        # Find or create the deny statement for services
        deny_statement = None
        for statement in policy_content['Statement']:
            if statement.get('Effect') == 'Deny' and 'Service' in statement.get('Action', []):
                deny_statement = statement
                break

        if not deny_statement:
            deny_statement = {
                'Sid': 'DenyNewServices',
                'Effect': 'Deny',
                'Action': '*',
                'Resource': '*',
                'Condition': {
                    'StringEquals': {
                        'aws:PrincipalOrgID': '*'
                    }
                }
            }
            policy_content['Statement'].append(deny_statement)

        # Add new services to the deny list
        updated = False
        for service in new_services:
            service_action = f"{service.lower()}:*"
            if 'Action' not in deny_statement:
                deny_statement['Action'] = [service_action]
                updated = True
            elif service_action not in deny_statement['Action']:
                if isinstance(deny_statement['Action'], str):
                    deny_statement['Action'] = [deny_statement['Action']]
                deny_statement['Action'].append(service_action)
                updated = True

        if updated:
            organizations.update_policy(
                PolicyId=scp_policy['id'],
                Content=json.dumps(policy_content)
            )
            print(f"Updated SCP with {len(new_services)} new services")
            return True

        return False

    except Exception as e:
        print(f"Error updating SCP: {str(e)}")
        return False


def send_notification_email(new_services: List[str]) -> bool:
    """Send a formatted email notification about new services."""
    try:
        timestamp = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')

        html_body = generate_html_email(new_services, timestamp)
        text_body = generate_text_email(new_services, timestamp)

        for recipient in EMAIL_RECIPIENTS:
            ses.send_email(
                Source=SENDER_EMAIL,
                Destination={'ToAddresses': [recipient]},
                Message={
                    'Subject': {
                        'Data': f'AWS Service Monitor: {len(new_services)} New Service(s) Detected',
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

        print(f"Sent email notification to {len(EMAIL_RECIPIENTS)} recipient(s)")
        return True

    except Exception as e:
        print(f"Error sending email: {str(e)}")
        return False


def generate_html_email(services: List[str], timestamp: str) -> str:
    """Generate a formatted HTML email."""
    services_html = '\n'.join([f'                <li>{service}</li>' for service in sorted(services)])

    html = f"""
    <html>
    <head>
        <style>
            body {{ font-family: Arial, sans-serif; color: #333; }}
            .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
            .header {{ background-color: #FF9900; color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }}
            .content {{ background-color: #f5f5f5; padding: 20px; border-radius: 5px; }}
            .service-list {{ background-color: white; padding: 15px; border-left: 4px solid #FF9900; margin: 15px 0; }}
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

                <p>These services have been added to the <strong>'{SCP_NAME}'</strong> Service Control Policy.</p>

                <div class="service-list">
                    <h3>New Services:</h3>
                    <ul>
{services_html}
                    </ul>
                </div>

                <p><strong>Actions Taken:</strong></p>
                <ul>
                    <li>Services added to SCP '{SCP_NAME}'</li>
                    <li>Service registry updated in DynamoDB</li>
                    <li>Notification email sent</li>
                </ul>

                <p><strong>Next Steps:</strong></p>
                <ul>
                    <li>Review the new services in the SCP</li>
                    <li>Verify organization policies are applied correctly</li>
                    <li>Monitor CloudWatch logs for any policy enforcement issues</li>
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


def generate_text_email(services: List[str], timestamp: str) -> str:
    """Generate a plain text email."""
    services_text = '\n'.join([f'  - {service}' for service in sorted(services)])

    text = f"""AWS SERVICE MONITOR ALERT
{"="*50}

New AWS Services Detected

The AWS service monitoring job has identified {len(services)} new service(s) as of {timestamp}.

These services have been added to the '{SCP_NAME}' Service Control Policy.

NEW SERVICES:
{services_text}

ACTIONS TAKEN:
  - Services added to SCP '{SCP_NAME}'
  - Service registry updated in DynamoDB
  - Notification email sent

NEXT STEPS:
  - Review the new services in the SCP
  - Verify organization policies are applied correctly
  - Monitor CloudWatch logs for any policy enforcement issues

{"="*50}
This is an automated notification from AWS Service Monitor.
Scan Time: {timestamp}
"""

    return text


def lambda_handler(event, context):
    """Main Lambda handler function."""
    print(f"Starting AWS service monitor at {datetime.utcnow().isoformat()}")

    try:
        # Fetch current services from AWS reference
        current_services = fetch_aws_services()
        if not current_services:
            print("Warning: No services fetched from AWS reference")
            return {
                'statusCode': 500,
                'body': json.dumps('Failed to fetch AWS services')
            }

        # Get previously tracked services
        tracked_services = get_tracked_services()

        # Identify new services
        new_services = current_services - tracked_services

        print(f"Total services: {len(current_services)}")
        print(f"Tracked services: {len(tracked_services)}")
        print(f"New services: {len(new_services)}")

        if new_services:
            new_services_list = sorted(list(new_services))

            # Store new services in DynamoDB
            store_new_services(new_services_list)

            # Get and update SCP
            scp_policy = get_scp_policy()
            if scp_policy:
                update_scp_with_services(scp_policy, new_services_list)
            else:
                print(f"Warning: SCP '{SCP_NAME}' not found. Services will be tracked but not added to SCP.")

            # Send notification email
            send_notification_email(new_services_list)

            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': f'Successfully processed {len(new_services)} new services',
                    'new_services': new_services_list
                })
            }
        else:
            print("No new services detected")
            return {
                'statusCode': 200,
                'body': json.dumps('No new services detected')
            }

    except Exception as e:
        print(f"Error in lambda_handler: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }
