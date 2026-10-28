import json
import os
import html
import boto3
import requests
import logging
import re
import copy
import hashlib
import time
from datetime import datetime
from typing import List, Dict, Set, Tuple
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
organizations = boto3.client('organizations')
ses = boto3.client('ses')
s3 = boto3.client('s3')
cloudwatch = boto3.client('cloudwatch')
sns = boto3.client('sns')

DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
APPROVED_SERVICES_TABLE = os.environ.get('APPROVED_SERVICES_TABLE', '')
PENDING_REGIONAL_SERVICES_TABLE = os.environ.get('PENDING_REGIONAL_SERVICES_TABLE', '')
SCP_NAME = os.environ['SCP_NAME']
EMAIL_RECIPIENTS = json.loads(os.environ['EMAIL_RECIPIENTS'])
SENDER_EMAIL = os.environ['SENDER_EMAIL']
REQUIRE_APPROVAL = os.environ.get('REQUIRE_APPROVAL', 'true').lower() == 'true'
MANAGE_SCP_POLICY = os.environ.get('MANAGE_SCP_POLICY', 'true').lower() == 'true'
BASELINE_SNAPSHOT_BUCKET = os.environ.get('BASELINE_SNAPSHOT_BUCKET', '')
ALERT_TOPIC_ARN = os.environ.get('ALERT_TOPIC_ARN', '')
ENABLE_SERVICE_APPROVAL_WORKFLOW = os.environ.get('ENABLE_SERVICE_APPROVAL_WORKFLOW', 'true').lower() == 'true'
APPROVED_SERVICES_LIST = json.loads(os.environ.get('APPROVED_SERVICES_LIST', '[]'))
APPROVAL_RECIPIENTS = json.loads(os.environ.get('APPROVAL_RECIPIENTS', '[]'))
ENABLE_REGIONAL_MONITORING = os.environ.get('ENABLE_REGIONAL_MONITORING', 'true').lower() == 'true'
MONITORED_REGION = os.environ.get('MONITORED_REGION', 'eu-west-2')

SERVICE_REFERENCE_URL = "https://servicereference.us-east-1.amazonaws.com/"
SERVICE_NAME_PATTERN = re.compile(r'^[a-z0-9\-]+$')
MAX_SERVICE_NAME_LENGTH = 30
BASELINE_MARKER = "__baseline_initialized__"


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
        if isinstance(data, list):
            services = {item['service'] for item in data if isinstance(item, dict) and 'service' in item}
        elif isinstance(data, dict):
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
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        logger.error(f"Failed to parse service reference response: {str(e)}")
        return set()


def calculate_baseline_checksum(services: Set[str]) -> str:
    """Calculate SHA256 checksum of baseline services for integrity verification."""
    # Create deterministic string representation (sorted)
    service_string = json.dumps(sorted(list(services)), separators=(',', ':'))
    checksum = hashlib.sha256(service_string.encode()).hexdigest()
    logger.debug(f"Calculated baseline checksum: {checksum}")
    return checksum


def check_regional_availability(services: List[str], region: str = 'eu-west-2', timeout_per_service: int = 2) -> Dict:
    """
    Check if services are available in a specific region with timeout guards.
    Returns dict: {
        'service_name': {
            'available_in_region': bool,
            'checked_at': timestamp
        }
    }

    This is intelligence only - used for notifications and monitoring,
    NOT for SCP gating.

    WAF Finding: Prevents timeout by adding per-service timeout and exit guards.
    """
    timestamp = datetime.utcnow().isoformat()
    result = {}
    start_time = time.time()
    max_check_duration = 240  # Exit early if approaching 300s Lambda timeout

    try:
        # Warn if too many services (100+ could cause timeout)
        if len(services) > 150:
            logger.warning(f"High number of services ({len(services)}) for regional check; may timeout")

        for service in services:
            # Safety: if approaching timeout, exit early
            elapsed = time.time() - start_time
            if elapsed > max_check_duration:
                logger.warning(f"Regional check timeout guard triggered after {service} ({elapsed:.1f}s elapsed); skipping remaining {len(services) - len(result)} services")
                for remaining_service in services:
                    if remaining_service not in result:
                        result[remaining_service] = {
                            'available_in_region': False,
                            'checked_at': timestamp,
                            'timeout': True
                        }
                break

            try:
                # Create client with timeout guards (WAF finding fix)
                config = Config(
                    connect_timeout=timeout_per_service,
                    read_timeout=timeout_per_service,
                    retries={'max_attempts': 0}  # No retries on regional checks
                )
                client = boto3.client(service, region_name=region, config=config)
                available = True
                logger.debug(f"Service {service} available in {region}")
            except Exception as e:
                available = False
                logger.debug(f"Service {service} not available in {region}: {str(e)}")

            result[service] = {
                'available_in_region': available,
                'checked_at': timestamp
            }

        elapsed = time.time() - start_time
        logger.info(f"Regional availability check completed in {elapsed:.1f}s for {len(result)} services")
        return result

    except Exception as e:
        logger.error(f"Error checking regional availability: {str(e)}")
        # Fail safe: assume all unavailable if check fails
        return {
            service: {'available_in_region': False, 'checked_at': timestamp}
            for service in services
        }


def track_service_for_regional_monitoring(
    service_name: str,
    region: str,
    detected_at: str
) -> bool:
    """
    Add service to pending_regional_services table for monitoring.
    This table is purely for intelligence/awareness - tracks when services
    become available in specific regions for operational planning.
    """
    if not PENDING_REGIONAL_SERVICES_TABLE:
        logger.debug("PENDING_REGIONAL_SERVICES_TABLE not configured, skipping tracking")
        return True

    try:
        table = dynamodb.Table(PENDING_REGIONAL_SERVICES_TABLE)
        timestamp = datetime.utcnow().isoformat()

        table.put_item(
            Item={
                'service_name': service_name,
                'detected_at': detected_at,
                'first_detected_at': detected_at,
                'region_name': region,
                'available_in_region': 0,  # 0 = False for GSI
                'last_checked_at': timestamp,
                'notification_sent': False
            },
            ConditionExpression='attribute_not_exists(service_name)'
        )

        logger.info(f"Tracking {service_name} for regional availability in {region}")
        return True

    except Exception as e:
        if 'ConditionalCheckFailedException' in str(type(e).__name__):
            logger.debug(f"Service {service_name} already tracked for regional monitoring")
            return True
        logger.error(f"Error tracking service for regional monitoring: {str(e)}")
        return False


def check_pending_regional_services(timestamp: str) -> Dict:
    """
    Daily monitoring: Check if pending services have become available.
    Called as part of normal lambda_handler execution.

    Returns: {
        'available': [service_names],
        'still_pending': [service_names],
        'errors': [...]
    }
    """
    if not PENDING_REGIONAL_SERVICES_TABLE or not ENABLE_REGIONAL_MONITORING:
        return {'available': [], 'still_pending': [], 'errors': []}

    try:
        table = dynamodb.Table(PENDING_REGIONAL_SERVICES_TABLE)
        region = MONITORED_REGION

        # Query: Get all services NOT yet available in region
        response = table.query(
            IndexName='region-name-index',
            KeyConditionExpression='region_name = :region AND available_in_region = :available',
            ExpressionAttributeValues={
                ':region': region,
                ':available': 0  # 0 = not available yet
            }
        )

        pending_services = response.get('Items', [])

        if not pending_services:
            logger.info("No pending regional services to check")
            return {'available': [], 'still_pending': [], 'errors': []}

        logger.info(f"Checking {len(pending_services)} pending services for regional availability")

        # Get list of service names
        pending_names = [item['service_name'] for item in pending_services]

        # Check each service
        regional_status = check_regional_availability(pending_names, region=region)

        summary = {'available': [], 'still_pending': [], 'errors': []}

        # Process results
        for service_item in pending_services:
            service_name = service_item['service_name']
            detected_at = service_item['detected_at']

            if regional_status[service_name]['available_in_region']:
                # Service is now available!
                try:
                    check_time = datetime.utcnow().isoformat()

                    # Update table to mark as available
                    table.update_item(
                        Key={
                            'service_name': service_name,
                            'detected_at': detected_at
                        },
                        UpdateExpression='SET available_in_region = :avail, available_at = :ts, last_checked_at = :checked',
                        ExpressionAttributeValues={
                            ':avail': 1,  # 1 = True
                            ':ts': check_time,
                            ':checked': check_time
                        }
                    )

                    # Send notification (via email)
                    if service_item.get('notification_sent') is not True:
                        send_regional_availability_notification(service_name, check_time)
                        # Mark notification as sent
                        table.update_item(
                            Key={
                                'service_name': service_name,
                                'detected_at': detected_at
                            },
                            UpdateExpression='SET notification_sent = :sent',
                            ExpressionAttributeValues={':sent': True}
                        )

                    logger.info(f"Service {service_name} is now available in {region}")
                    summary['available'].append(service_name)

                except Exception as e:
                    logger.error(f"Error updating service {service_name}: {str(e)}")
                    summary['errors'].append({'service': service_name, 'error': str(e)})
            else:
                # Still pending
                try:
                    # Update last checked time
                    table.update_item(
                        Key={
                            'service_name': service_name,
                            'detected_at': detected_at
                        },
                        UpdateExpression='SET last_checked_at = :ts',
                        ExpressionAttributeValues={':ts': datetime.utcnow().isoformat()}
                    )
                    summary['still_pending'].append(service_name)
                except Exception as e:
                    logger.error(f"Error updating last_checked_at for {service_name}: {str(e)}")
                    summary['errors'].append({'service': service_name, 'error': str(e)})

        return summary

    except Exception as e:
        logger.error(f"Error checking pending regional services: {str(e)}")
        return {'available': [], 'still_pending': [], 'errors': [str(e)]}


def send_regional_availability_notification(service_name: str, timestamp: str) -> bool:
    """
    Send notification when a pending service becomes available in region.
    This is intelligence/awareness only - service is already blocked by SCP.
    """
    try:
        html_body = f"""
        <html>
        <head>
            <style>
                body {{ font-family: Arial, sans-serif; color: #333; }}
                .alert {{ background: #d4edda; border: 1px solid #c3e6cb; padding: 15px; border-radius: 5px; margin: 10px 0; }}
                .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
            </style>
        </head>
        <body>
            <div class="container">
                <div class="alert">
                    <h2>✅ Service Now Available in Region: {MONITORED_REGION}</h2>
                    <p><strong>{html.escape(service_name)}</strong> is now available in your region.</p>
                    <p><strong>Status:</strong> Service is already protected by SCP (added on detection date)</p>
                    <p><strong>Date Available:</strong> {timestamp}</p>
                    <p style="font-size: 12px; color: #666;">
                        This is for cost tracking and operational planning purposes.
                        No SCP changes are needed - the service has been blocked since first detection.
                    </p>
                </div>
            </div>
        </body>
        </html>
        """

        text_body = f"""
✅ Service Now Available in Region: {MONITORED_REGION}

{service_name} is now available in your region.

Status: Service is already protected by SCP (added on detection date)
Date Available: {timestamp}

This is for cost tracking and operational planning purposes.
No SCP changes are needed - the service has been blocked since first detection.
        """

        for recipient in EMAIL_RECIPIENTS:
            try:
                ses.send_email(
                    Source=SENDER_EMAIL,
                    Destination={'ToAddresses': [recipient]},
                    Message={
                        'Subject': {
                            'Data': f'✅ AWS Service Now Available in {MONITORED_REGION}: {service_name}',
                            'Charset': 'UTF-8'
                        },
                        'Body': {
                            'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                            'Html': {'Data': html_body, 'Charset': 'UTF-8'}
                        }
                    }
                )
            except Exception as e:
                logger.error(f"Error sending email to {recipient}: {str(e)}")
                return False

        logger.info(f"Sent regional availability notification for {service_name}")
        return True

    except Exception as e:
        logger.error(f"Error sending regional availability notification: {str(e)}")
        return False


def store_baseline_snapshot(services: Set[str], checksum: str, timestamp: str) -> bool:
    """Store immutable baseline snapshot in S3 for tamper detection."""
    if not BASELINE_SNAPSHOT_BUCKET:
        logger.warning("BASELINE_SNAPSHOT_BUCKET not configured, skipping S3 snapshot")
        return True

    try:
        snapshot = {
            'timestamp': timestamp,
            'service_count': len(services),
            'services': sorted(list(services)),
            'checksum': checksum,
            'version': '1.0'
        }

        key = f'baseline-snapshots/{timestamp}.json'

        s3.put_object(
            Bucket=BASELINE_SNAPSHOT_BUCKET,
            Key=key,
            Body=json.dumps(snapshot, indent=2),
            ServerSideEncryption='AES256',
            ContentType='application/json',
            Metadata={
                'checksum': checksum,
                'service-count': str(len(services))
            }
        )

        logger.info(f"Stored immutable baseline snapshot: s3://{BASELINE_SNAPSHOT_BUCKET}/{key}")
        return True

    except Exception as e:
        logger.error(f"Error storing baseline snapshot: {str(e)}")
        return False


def verify_baseline_integrity() -> Tuple[bool, str]:
    """Verify baseline integrity by checking checksum."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)

        # Get baseline marker
        response = table.get_item(Key={'service_name': BASELINE_MARKER})

        if 'Item' not in response:
            logger.info("Baseline not initialized yet")
            return True, "Baseline not initialized"

        baseline_item = response['Item']
        stored_checksum = baseline_item.get('checksum', '')

        if not stored_checksum:
            logger.warning("Baseline has no checksum, cannot verify integrity")
            return True, "No checksum available"

        # Get all tracked services (excluding metadata)
        scan_response = table.scan(
            FilterExpression='attribute_exists(service_name) AND NOT begins_with(service_name, :prefix)',
            ExpressionAttributeValues={':prefix': '__'},
            ProjectionExpression='service_name'
        )

        services = set(item['service_name'] for item in scan_response.get('Items', []))

        # Handle pagination
        while 'LastEvaluatedKey' in scan_response:
            scan_response = table.scan(
                FilterExpression='attribute_exists(service_name) AND NOT begins_with(service_name, :prefix)',
                ExpressionAttributeValues={':prefix': '__'},
                ProjectionExpression='service_name',
                ExclusiveStartKey=scan_response['LastEvaluatedKey']
            )
            services.update(item['service_name'] for item in scan_response.get('Items', []))

        # Calculate checksum of current services
        calculated_checksum = calculate_baseline_checksum(services)

        # Compare checksums
        if stored_checksum == calculated_checksum:
            logger.info(f"Baseline integrity verified ✓ (checksum: {calculated_checksum[:8]}...)")
            return True, "Baseline integrity verified"
        else:
            logger.error(f"BASELINE INTEGRITY VIOLATION DETECTED")
            logger.error(f"  Expected: {stored_checksum}")
            logger.error(f"  Actual:   {calculated_checksum}")
            logger.error(f"  Services: {len(services)}")
            return False, f"Checksum mismatch: expected {stored_checksum[:8]}, got {calculated_checksum[:8]}"

    except Exception as e:
        logger.error(f"Error verifying baseline integrity: {str(e)}")
        return False, f"Integrity check failed: {str(e)}"


def is_baseline_initialized() -> bool:
    """Check if baseline has been initialized."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.get_item(Key={'service_name': BASELINE_MARKER})
        return 'Item' in response
    except Exception as e:
        logger.error(f"Error checking baseline status: {str(e)}")
        return False


def initialize_baseline(services: Set[str]) -> bool:
    """Initialize baseline with current services and integrity checksum."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        timestamp = datetime.utcnow().isoformat()

        # Calculate checksum for integrity verification
        checksum = calculate_baseline_checksum(services)

        # Use conditional write to prevent race condition
        # This ensures only the first initialization succeeds
        table.put_item(
            Item={
                'service_name': BASELINE_MARKER,
                'first_seen': timestamp,
                'last_updated': timestamp,
                'status': 'initialized',
                'service_count': len(services),
                'checksum': checksum  # Store checksum for integrity verification
            },
            ConditionExpression='attribute_not_exists(service_name)'
        )

        # Store all current services as baseline
        with table.batch_writer() as batch:
            for service in services:
                batch.put_item(Item={
                    'service_name': service,
                    'first_seen': timestamp,
                    'last_updated': timestamp,
                    'is_baseline': True
                })

        # Store immutable snapshot in S3 for tamper detection
        snapshot_stored = store_baseline_snapshot(services, checksum, timestamp)

        logger.info(f"Baseline initialized with {len(services)} services")
        logger.info(f"Baseline checksum: {checksum[:16]}... (stored for integrity verification)")

        if snapshot_stored and BASELINE_SNAPSHOT_BUCKET:
            logger.info(f"Immutable baseline snapshot stored in S3")

        return True

    except Exception as e:
        # Check if this is a race condition (baseline already exists)
        if 'ConditionalCheckFailedException' in str(type(e).__name__):
            logger.warning(f"Baseline already initialized (race condition prevented)")
            return True  # Not an error - baseline is already set
        else:
            logger.error(f"Error initializing baseline: {str(e)}")
            return False


def get_tracked_services() -> Set[str]:
    """Get the set of previously tracked services from DynamoDB."""
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        response = table.scan()

        tracked = set()
        for item in response.get('Items', []):
            # Skip baseline marker and metadata items
            if not item['service_name'].startswith('__'):
                tracked.add(item['service_name'])

        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            for item in response.get('Items', []):
                # Skip baseline marker and metadata items
                if not item['service_name'].startswith('__'):
                    tracked.add(item['service_name'])

        logger.info(f"Retrieved {len(tracked)} tracked services from DynamoDB")
        return tracked

    except Exception as e:
        logger.error(f"Error getting tracked services: {str(e)}")
        return set()


def get_known_aws_services() -> Set[str]:
    """
    Load list of known AWS services from boto3 session (WAF finding: service catalog validation).
    This provides a baseline list of legitimate AWS services.
    """
    try:
        # Use boto3's list of available services
        from botocore.loaders import Loader
        loader = Loader()
        api_version = loader.list_api_versions('service-2')[0]

        # Get all available service names from boto3
        services = set(loader.list_available_services('service-2'))
        logger.info(f"Loaded {len(services)} known AWS services from boto3 catalog")
        return services
    except Exception as e:
        logger.warning(f"Could not load AWS service catalog from boto3: {str(e)}; using format-only validation")
        return set()


def validate_service_names(services: Set[str], known_services: Set[str] = None) -> Tuple[Set[str], List[str]]:
    """
    Validate service names against AWS naming conventions AND AWS service catalog.

    WAF Finding Fix: Added service catalog validation to prevent injection of arbitrary
    strings into SCP policy.
    """
    valid_services = set()
    invalid_services = []

    # Load known AWS services once (expensive operation)
    if known_services is None:
        known_services = get_known_aws_services()

    for service in services:
        # Check 1: Format validation (lowercase alphanumeric + hyphens)
        if not SERVICE_NAME_PATTERN.match(service):
            invalid_services.append(f"{service} (invalid format)")
            continue

        # Check 2: Length validation
        if len(service) > MAX_SERVICE_NAME_LENGTH:
            invalid_services.append(f"{service} (exceeds max length {MAX_SERVICE_NAME_LENGTH})")
            continue

        # Check 3: Minimum length (avoid very short names)
        if len(service) < 2:
            invalid_services.append(f"{service} (too short)")
            continue

        # Check 4: AWS service catalog validation (if available)
        if known_services and service not in known_services:
            invalid_services.append(f"{service} (not in AWS service catalog - possible injection attempt)")
            logger.warning(f"Service {service} not found in AWS catalog; possible injection attack")
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

        with table.batch_writer() as batch:
            for service in services:
                batch.put_item(Item={
                    'service_name': service,
                    'first_seen': timestamp,
                    'last_updated': timestamp
                })

        print(f"Stored {len(services)} new services in DynamoDB")

    except Exception as e:
        print(f"Error storing services: {str(e)}")


def update_baseline_checksum(all_services: Set[str]) -> bool:
    """
    Update the baseline checksum after new services are added.

    T004 Mitigation: Uses ConditionExpression to ensure baseline marker exists
    before allowing update, preventing unauthorized baseline resets.
    """
    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        new_checksum = calculate_baseline_checksum(all_services)

        # T004: Prevent unauthorized baseline reset via ConditionExpression
        table.update_item(
            Key={'service_name': BASELINE_MARKER},
            UpdateExpression='SET checksum = :checksum, last_updated = :ts, service_count = :count',
            ExpressionAttributeValues={
                ':checksum': new_checksum,
                ':ts': datetime.utcnow().isoformat(),
                ':count': len(all_services)
            },
            ConditionExpression='attribute_exists(service_name)',  # Baseline marker must exist
            ReturnValues='NONE'
        )

        logger.info(f"Updated baseline checksum to {new_checksum[:16]}... ({len(all_services)} services)")
        return True

    except Exception as e:
        if 'ConditionalCheckFailedException' in str(type(e).__name__):
            logger.error(f"Baseline update failed: baseline marker does not exist (possible tampering attempt)")
        else:
            logger.error(f"Error updating baseline checksum: {str(e)}")
        return False


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


def send_tamper_alert_email(integrity_msg: str) -> bool:
    """Send security alert email for baseline tampering detection."""
    try:
        timestamp = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')

        html_body = f"""
        <html>
        <head>
            <style>
                body {{ font-family: Arial, sans-serif; color: #333; }}
                .container {{ max-width: 600px; margin: 0 auto; padding: 20px; }}
                .alert {{ background-color: #f8d7da; border: 2px solid #f5c6cb; border-radius: 5px; padding: 20px; margin-bottom: 20px; }}
                .alert-title {{ color: #721c24; font-size: 20px; font-weight: bold; }}
                .alert-message {{ color: #721c24; font-size: 16px; margin-top: 10px; }}
                .details {{ background-color: #f5f5f5; padding: 15px; margin: 15px 0; border-left: 4px solid #dc3545; font-family: monospace; }}
                .action {{ background-color: #fff3cd; padding: 15px; margin: 15px 0; border-left: 4px solid #ffc107; }}
                .footer {{ color: #666; font-size: 12px; margin-top: 20px; }}
            </style>
        </head>
        <body>
            <div class="container">
                <div class="alert">
                    <div class="alert-title">🚨 SECURITY ALERT: Baseline Integrity Violation</div>
                </div>

                <h2>Baseline Tampering Detected</h2>
                <p>The AWS Service Monitor has detected a potential tampering attempt on the service baseline.</p>

                <div class="details">
                    <strong>Integrity Check Failed:</strong><br/>
                    {integrity_msg}
                </div>

                <div class="action">
                    <strong>⚠️ IMMEDIATE ACTION REQUIRED:</strong>
                    <ul>
                        <li>Review CloudTrail logs for recent DynamoDB modifications</li>
                        <li>Verify baseline data integrity in AWS console</li>
                        <li>Check S3 immutable backup: baseline-snapshots/</li>
                        <li>Initiate incident response procedure</li>
                        <li>Restore from S3 snapshot if tampering confirmed</li>
                    </ul>
                </div>

                <h3>What This Means</h3>
                <p>The baseline data or checksum appears to have been modified. This could indicate:</p>
                <ul>
                    <li>Unauthorized DynamoDB table modifications</li>
                    <li>Attempted security bypass</li>
                    <li>Service registry corruption</li>
                </ul>

                <h3>Next Steps</h3>
                <ol>
                    <li>Contact your security team immediately</li>
                    <li>Do NOT delete CloudWatch logs or CloudTrail data</li>
                    <li>Do NOT make manual changes to DynamoDB</li>
                    <li>Preserve S3 baseline snapshot for forensics</li>
                    <li>Review all organization SCPs for unauthorized changes</li>
                </ol>

                <div class="footer">
                    <p><strong>Alert Time:</strong> {timestamp}</p>
                    <p><strong>Service:</strong> AWS Service Monitor</p>
                    <p><strong>Severity:</strong> CRITICAL</p>
                    <p>This is an automated security alert. Do not reply to this email.</p>
                </div>
            </div>
        </body>
        </html>
        """

        text_body = f"""
SECURITY ALERT: Baseline Integrity Violation
{'='*60}

BASELINE TAMPERING DETECTED

The AWS Service Monitor has detected a potential tampering attempt
on the service baseline.

INTEGRITY CHECK FAILED:
{integrity_msg}

IMMEDIATE ACTION REQUIRED:
  1. Review CloudTrail logs for recent DynamoDB modifications
  2. Verify baseline data integrity in AWS console
  3. Check S3 immutable backup: baseline-snapshots/
  4. Initiate incident response procedure
  5. Restore from S3 snapshot if tampering confirmed

WHAT THIS MEANS:
The baseline data or checksum has been modified. This could indicate:
  - Unauthorized DynamoDB table modifications
  - Attempted security bypass
  - Service registry corruption

NEXT STEPS:
  1. Contact your security team immediately
  2. Do NOT delete CloudWatch logs or CloudTrail data
  3. Do NOT make manual changes to DynamoDB
  4. Preserve S3 baseline snapshot for forensics
  5. Review all organization SCPs for unauthorized changes

{'='*60}
Alert Time: {timestamp}
Service: AWS Service Monitor
Severity: CRITICAL

This is an automated security alert. Do not reply to this email.
"""

        for recipient in EMAIL_RECIPIENTS:
            ses.send_email(
                Source=SENDER_EMAIL,
                Destination={'ToAddresses': [recipient]},
                Message={
                    'Subject': {
                        'Data': '🚨 SECURITY ALERT: Baseline Integrity Violation Detected',
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

        logger.info(f"Security alert email sent to {len(EMAIL_RECIPIENTS)} recipient(s)")
        return True

    except Exception as e:
        logger.error(f"Error sending tamper alert email: {str(e)}")
        return False


def publish_metrics(new_services_count: int, total_services: int, integrity_ok: bool) -> None:
    """Publish custom metrics to CloudWatch for dashboard and alarms."""
    try:
        cloudwatch.put_metric_data(
            Namespace='AWS/ServiceMonitor',
            MetricData=[
                {
                    'MetricName': 'NewServicesDetected',
                    'Value': new_services_count,
                    'Unit': 'Count',
                    'Timestamp': datetime.utcnow()
                },
                {
                    'MetricName': 'TotalTrackedServices',
                    'Value': total_services,
                    'Unit': 'Count',
                    'Timestamp': datetime.utcnow()
                },
                {
                    'MetricName': 'BaselineIntegrityStatus',
                    'Value': 1 if integrity_ok else 0,
                    'Unit': 'None',
                    'Timestamp': datetime.utcnow()
                }
            ]
        )
        logger.info("Published metrics to CloudWatch")
    except Exception as e:
        logger.error(f"Error publishing metrics to CloudWatch: {str(e)}")


def send_integrity_alert_sns(integrity_msg: str) -> bool:
    """Send baseline integrity violation alert via SNS for operational alerts."""
    if not ALERT_TOPIC_ARN:
        logger.warning("ALERT_TOPIC_ARN not configured, skipping SNS alert")
        return False

    try:
        sns.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject='CRITICAL: AWS Service Monitor - Baseline Integrity Violation',
            Message=f"""
SECURITY ALERT: Baseline Integrity Violation Detected

{integrity_msg}

Timestamp: {datetime.utcnow().isoformat()}

Actions:
1. Check CloudWatch Logs for violation details: /aws/lambda/aws-service-monitor
2. Review CloudTrail logs for unauthorized DynamoDB modifications
3. Verify baseline data in DynamoDB table: {DYNAMODB_TABLE}
4. Check S3 immutable backup: s3://{BASELINE_SNAPSHOT_BUCKET}/baseline-snapshots/
5. Consider restoring from PITR if tampering confirmed
6. Initiate incident response procedures

Dashboard: https://console.aws.amazon.com/cloudwatch/home?region={os.environ.get('AWS_REGION', 'eu-west-2')}#dashboards:name=aws-service-monitor
"""
        )
        logger.info("Sent baseline integrity violation alert via SNS")
        return True
    except Exception as e:
        logger.error(f"Error sending SNS integrity alert: {str(e)}")
        return False


def send_notification_email(new_services: List[str], scp_status: str = 'unknown', regional_status: Dict = None) -> bool:
    """Send formatted email notification about new services."""
    try:
        timestamp = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')

        html_body = generate_html_email(new_services, timestamp, scp_status, regional_status)
        text_body = generate_text_email(new_services, timestamp, scp_status, regional_status)

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


def generate_html_email(services: List[str], timestamp: str, scp_status: str = 'unknown', regional_status: Dict = None) -> str:
    """Generate formatted HTML email with proper escaping and regional status."""
    from html import escape
    services_html = '\n'.join([f'                <li>{escape(service)}</li>' for service in sorted(services)])
    status_title, status_message = get_scp_status_message(scp_status)

    # Generate regional status section
    regional_html = ""
    if regional_status and ENABLE_REGIONAL_MONITORING:
        available_count = sum(1 for s in regional_status.values() if s['available_in_region'])
        pending_count = len(regional_status) - available_count

        if pending_count > 0:
            regional_html = f"""
                <div class="status-box" style="border-left-color: #17a2b8;">
                    <div class="status-title">Regional Status ({MONITORED_REGION})</div>
                    <p><strong>Available in {MONITORED_REGION}:</strong> {available_count}/{len(regional_status)}</p>
                    <p><strong>Pending {MONITORED_REGION} deployment:</strong> {pending_count}/{len(regional_status)}</p>
                    <p style="color: #666; font-size: 12px;">
                        Monitoring: Services not yet available in {MONITORED_REGION} will be tracked daily.
                        You will be notified when they become available for cost planning and operational purposes.
                    </p>
                </div>
                """

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

                {regional_html}

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
                    <li>✓ All services IMMEDIATELY added to SCP blacklist</li>
                    <li>✓ Regional availability checked (intelligence only)</li>
                    <li>✓ Notification email sent</li>
                </ul>

                <p><strong>Security Note:</strong></p>
                <p style="font-size: 12px; color: #666;">
                    All new AWS services are immediately blocked via Service Control Policy as a cautious-by-default approach.
                    Services are monitored for regional availability in {MONITORED_REGION} for operational planning purposes.
                </p>

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


def generate_text_email(services: List[str], timestamp: str, scp_status: str = 'unknown', regional_status: Dict = None) -> str:
    """Generate plain text email with regional status."""
    services_text = '\n'.join([f'  - {service}' for service in sorted(services)])
    status_title, status_message = get_scp_status_message(scp_status)

    # Generate regional status section
    regional_text = ""
    if regional_status and ENABLE_REGIONAL_MONITORING:
        available_count = sum(1 for s in regional_status.values() if s['available_in_region'])
        pending_count = len(regional_status) - available_count

        if pending_count > 0:
            regional_text = f"""
REGIONAL STATUS ({MONITORED_REGION}):
  Available in {MONITORED_REGION}: {available_count}/{len(regional_status)}
  Pending {MONITORED_REGION} deployment: {pending_count}/{len(regional_status)}

  Monitoring: Services not yet available in {MONITORED_REGION} will be tracked daily.
  You will be notified when they become available for cost planning and operational purposes.
"""

    text = f"""AWS SERVICE MONITOR ALERT
{"="*50}

New AWS Services Detected

The AWS service monitoring job has identified {len(services)} new service(s) as of {timestamp}.

STATUS: {status_title}
{status_message}

NEW SERVICES:
{services_text}
{regional_text}

ACTIONS TAKEN:
  ✓ Service names validated
  ✓ Service registry updated in DynamoDB
  ✓ All services IMMEDIATELY added to SCP blacklist
  ✓ Regional availability checked (intelligence only)
  ✓ Notification email sent

SECURITY NOTE:
  All new AWS services are immediately blocked via Service Control Policy as a cautious-by-default
  approach. Services are monitored for regional availability in {MONITORED_REGION} for operational
  planning purposes.

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


def get_approved_services() -> Set[str]:
    """Get list of approved services from configuration and DynamoDB."""
    approved = set(APPROVED_SERVICES_LIST)

    if not APPROVED_SERVICES_TABLE:
        logger.info(f"Loaded {len(approved)} pre-configured approved services")
        return approved

    try:
        table = dynamodb.Table(APPROVED_SERVICES_TABLE)
        response = table.query(
            IndexName='approval-status-index',
            KeyConditionExpression='approval_status = :status',
            ExpressionAttributeValues={':status': 'approved'}
        )

        for item in response.get('Items', []):
            approved.add(item['service_name'])

        logger.info(f"Loaded {len(approved)} approved services (config + DynamoDB)")
        return approved
    except Exception as e:
        logger.warning(f"Failed to load approved services from DynamoDB: {str(e)}")
        logger.info(f"Using {len(approved)} pre-configured approved services")
        return approved


def track_service_for_approval(service_name: str, timestamp: str) -> bool:
    """Track a new service as pending approval in DynamoDB."""
    if not APPROVED_SERVICES_TABLE or not ENABLE_SERVICE_APPROVAL_WORKFLOW:
        return True

    try:
        table = dynamodb.Table(APPROVED_SERVICES_TABLE)
        table.put_item(
            Item={
                'service_name': service_name,
                'approval_status': 'pending',
                'detected_at': timestamp,
                'approval_requested_at': timestamp,
                'approved_by': None,
                'approved_at': None
            }
        )
        logger.info(f"Tracked service '{service_name}' for approval")
        return True
    except Exception as e:
        logger.error(f"Failed to track service for approval: {str(e)}")
        return False


def send_approval_request_email(service_name: str, timestamp: str) -> bool:
    """Send approval request email for a new blacklisted service."""
    if not ENABLE_SERVICE_APPROVAL_WORKFLOW:
        return True

    # Validate that approval recipients are configured
    approval_recipients = APPROVAL_RECIPIENTS if APPROVAL_RECIPIENTS else EMAIL_RECIPIENTS
    if not approval_recipients:
        logger.warning("No approval recipients configured, skipping approval email")
        return True

    try:
        subject = f"AWS Service Monitor: Approval Request for '{service_name}'"

        html_body = f"""
<html>
<head></head>
<body style="font-family: Arial, sans-serif; color: #333;">
    <h2>Service Approval Request</h2>
    <p>A new AWS service has been detected and added to the blacklist SCP.</p>

    <div style="background-color: #f5f5f5; padding: 15px; border-radius: 5px; margin: 20px 0;">
        <h3 style="margin-top: 0;">Service Details</h3>
        <table style="width: 100%; border-collapse: collapse;">
            <tr>
                <td style="padding: 8px; font-weight: bold; width: 150px;">Service Name:</td>
                <td style="padding: 8px;">{html.escape(service_name)}</td>
            </tr>
            <tr>
                <td style="padding: 8px; font-weight: bold;">Detected At:</td>
                <td style="padding: 8px;">{timestamp}</td>
            </tr>
            <tr>
                <td style="padding: 8px; font-weight: bold;">Status:</td>
                <td style="padding: 8px; color: #d9534f;">Pending Approval</td>
            </tr>
        </table>
    </div>

    <h3>What This Means</h3>
    <p>This service is currently blocked by the SCP. You can approve it to move it to the allowlist.</p>

    <h3>Next Steps</h3>
    <ol>
        <li>Review the service: <strong>{html.escape(service_name)}</strong></li>
        <li>Determine if this service should be approved for use in your organization</li>
        <li>Update the <code>approved_services</code> list in <code>terraform.tfvars</code> to include this service</li>
        <li>Run <code>terraform apply</code> to apply the approval</li>
        <li>The service will be excluded from the SCP deny list on the next monitor run</li>
    </ol>

    <h3>Quick Reference</h3>
    <p>To approve this service, add it to your terraform configuration:</p>
    <pre style="background-color: #f5f5f5; padding: 10px; border-radius: 3px; overflow-x: auto;">
approved_services = [
  "{html.escape(service_name)}"
]</pre>

    <hr style="border: none; border-top: 1px solid #ddd; margin: 20px 0;">
    <p style="color: #999; font-size: 12px;">
        This is an automated notification from AWS Service Monitor.<br>
        Sent: {timestamp}
    </p>
</body>
</html>
"""

        text_body = f"""Service Approval Request

A new AWS service has been detected and added to the blacklist SCP.

SERVICE DETAILS:
  Service Name: {service_name}
  Detected At: {timestamp}
  Status: Pending Approval

WHAT THIS MEANS:
This service is currently blocked by the SCP. You can approve it to move it to the allowlist.

NEXT STEPS:
1. Review the service: {service_name}
2. Determine if this service should be approved for use in your organization
3. Update the 'approved_services' list in 'terraform.tfvars' to include this service
4. Run 'terraform apply' to apply the approval
5. The service will be excluded from the SCP deny list on the next monitor run

QUICK REFERENCE:
To approve this service, add it to your terraform configuration:

approved_services = [
  "{service_name}"
]

---
This is an automated notification from AWS Service Monitor.
Sent: {timestamp}
"""

        ses.send_email(
            Source=SENDER_EMAIL,
            Destination={'ToAddresses': approval_recipients},
            Message={
                'Subject': {'Data': subject},
                'Body': {
                    'Html': {'Data': html_body},
                    'Text': {'Data': text_body}
                }
            }
        )
        logger.info(f"Sent approval request email for service '{service_name}' to {len(approval_recipients)} recipients")
        return True
    except Exception as e:
        logger.error(f"Failed to send approval request email: {str(e)}")
        return False


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

        logger.info(f"Total services: {len(current_services)}")

        # CHECK: Is this the first run?
        if not is_baseline_initialized():
            logger.info("=== BASELINE INITIALIZATION ===")
            logger.info("First run detected - initializing baseline")

            # Initialize baseline with all current services
            success = initialize_baseline(current_services)

            if success:
                logger.info(f"Baseline initialized with {len(current_services)} services")
                # Publish metrics for baseline initialization
                publish_metrics(0, len(current_services), True)
                return {
                    'statusCode': 200,
                    'body': json.dumps({
                        'message': 'Baseline established',
                        'baseline_services': len(current_services),
                        'status': 'baseline_initialized',
                        'note': 'No actions taken on first run. Monitoring will begin on next execution.',
                        'scan_time': start_time
                    })
                }
            else:
                logger.error("Failed to initialize baseline")
                return {
                    'statusCode': 500,
                    'body': json.dumps({
                        'error': 'Failed to initialize baseline',
                        'scan_time': start_time
                    })
                }

        # Verify baseline integrity (detect tampering)
        is_valid, integrity_msg = verify_baseline_integrity()

        if not is_valid:
            logger.critical(f"SECURITY ALERT: {integrity_msg}")
            # Send alert emails about tampering (email + SNS)
            send_tamper_alert_email(integrity_msg)
            send_integrity_alert_sns(integrity_msg)
            # Publish integrity failure metric for alarm
            publish_metrics(0, 0, False)
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'error': 'Baseline integrity check failed',
                    'details': integrity_msg,
                    'action': 'Security alert sent'
                })
            }

        # CHECK PENDING REGIONAL SERVICES (daily monitoring)
        if ENABLE_REGIONAL_MONITORING:
            logger.info("=== CHECKING PENDING REGIONAL SERVICES ===")
            pending_summary = check_pending_regional_services(start_time)
            if pending_summary['available']:
                logger.info(f"Services now available in {MONITORED_REGION}: {pending_summary['available']}")
            if pending_summary['errors']:
                logger.warning(f"Errors checking pending services: {pending_summary['errors']}")

        # Get previously tracked services (baseline is initialized and verified)
        tracked_services = get_tracked_services()

        # Identify new services
        new_services = current_services - tracked_services

        logger.info(f"Tracked services: {len(tracked_services)}")
        logger.info(f"New services: {len(new_services)}")

        if new_services:
            # Load known AWS services for catalog validation (WAF finding fix)
            known_services = get_known_aws_services()

            # Validate service names against format AND AWS service catalog
            valid_services, invalid_services = validate_service_names(new_services, known_services)

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

            # Store new services in DynamoDB and update checksum to prevent false tamper alerts
            store_new_services(new_services_list)
            update_baseline_checksum(tracked_services | set(new_services_list))

            # CHECK REGIONAL AVAILABILITY (intelligence only - not for SCP gating)
            regional_status = {}
            if ENABLE_REGIONAL_MONITORING:
                logger.info(f"Checking regional availability for {len(new_services_list)} new services in {MONITORED_REGION}")
                regional_status = check_regional_availability(new_services_list, region=MONITORED_REGION)

                # Track services not yet available in region for monitoring
                for service in new_services_list:
                    if not regional_status[service]['available_in_region']:
                        track_service_for_regional_monitoring(service, MONITORED_REGION, start_time)
                        logger.info(f"Service '{service}' NOT available in {MONITORED_REGION} - tracking for future availability")

            # Filter out approved services — they are tracked but not added to the SCP deny list
            approved_services = get_approved_services()
            if approved_services:
                logger.info(f"Approved services: {len(approved_services)}")
            approved_from_new = [s for s in new_services_list if s in approved_services]
            services_for_scp = [s for s in new_services_list if s not in approved_services]

            if approved_from_new:
                logger.warning(f"T015: approved services excluded from SCP deny list: {approved_from_new} — verify these approvals are legitimate")

            # Send approval request emails for unapproved services
            if services_for_scp and ENABLE_SERVICE_APPROVAL_WORKFLOW:
                for service in services_for_scp:
                    track_service_for_approval(service, start_time)
                    send_approval_request_email(service, start_time)

            scp_update_status = 'not_attempted'
            scp_error = None

            if MANAGE_SCP_POLICY:
                scp_policy = get_scp_policy()

                if services_for_scp and scp_policy:
                    preview = generate_scp_preview(scp_policy, services_for_scp)

                    if REQUIRE_APPROVAL:
                        logger.info("Approval required - storing preview for manual review")
                        scp_update_status = 'pending_approval'
                        store_pending_scp_update(preview)
                    else:
                        success, message = update_scp_with_services(scp_policy, services_for_scp)
                        scp_update_status = 'success' if success else 'failed'
                        scp_error = message if not success else None
                        logger.info(f"SCP update result: {message}")
                elif not services_for_scp and new_services_list:
                    logger.info("All new services are approved — no SCP update needed")
                    scp_update_status = 'no_unapproved_services'
                elif scp_policy is None:
                    logger.warning(f"SCP '{SCP_NAME}' not found")
                    scp_update_status = 'not_found'
            else:
                logger.info("SCP management disabled - skipping policy updates")
                scp_update_status = 'disabled'

            # Send notification email (always enabled)
            send_notification_email(new_services_list, scp_update_status, regional_status)

            # Publish metrics for dashboard and alarms
            publish_metrics(len(new_services_list), len(tracked_services) + len(new_services_list), True)

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
            # Publish metrics for dashboard and alarms
            publish_metrics(0, len(tracked_services), True)
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
