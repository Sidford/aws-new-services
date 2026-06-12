# Baseline Initialization - Security Analysis

## Summary

**Risk Level**: 🟡 **LOW-MEDIUM**

The baseline initialization feature introduces some security considerations that should be understood and mitigated. Most are manageable with proper operational procedures.

---

## 1. Baseline Reset / Reinitialization Attack 🟡 MEDIUM

### Risk Description
An attacker or privileged user could:
1. Delete the `__baseline_initialized__` marker from DynamoDB
2. Trigger Lambda manually
3. Reinitialize baseline with a different set of services
4. Cause system to miss detection of newly added services

### Scenario
```
Attacker Action:
├─ Delete __baseline_initialized__ from DynamoDB
├─ Wait or trigger Lambda
├─ Lambda sees "no baseline" and reinitializes
├─ New baseline is established (potentially without malicious services)
└─ Original baseline history is lost

Impact:
├─ Lost detection of services added between original and new baseline
├─ No alert if attacker-controlled service was added
├─ Audit trail broken
└─ Possible compliance violation
```

### Current Mitigations ✅
- DynamoDB encrypted by default (AWS managed keys)
- Lambda IAM role restricted to specific table
- CloudTrail logs all DynamoDB delete operations

### Recommended Enhancements

**Option 1: DynamoDB Backup (Easy)**
```hcl
resource "aws_dynamodb_table" "service_registry" {
  point_in_time_recovery_specification {
    enabled = true  # Already added in v1
  }
}
```
Benefits:
- Can restore to any point in last 35 days
- Detects if baseline was deleted
- Can compare before/after

**Option 2: DynamoDB Versioning (Medium Effort)**
```python
def initialize_baseline(services: Set[str]) -> bool:
    """Store baseline with version control."""
    table = dynamodb.Table(DYNAMODB_TABLE)
    timestamp = datetime.utcnow().isoformat()
    
    # Store versioned baseline marker
    table.put_item(Item={
        'service_name': '__baseline_initialized__',
        'baseline_version': 1,  # Increment on each reset
        'previous_count': 0,    # Previous service count
        'service_count': len(services),
        'first_seen': timestamp,
        'last_updated': timestamp,
        'created_by': context.invoked_function_arn  # Track who created it
    })
```

**Option 3: Immutable Baseline (Strong)**
```python
# Use DynamoDB backup/snapshot after baseline initialization
# Make snapshot immutable with S3 object lock
# Create alert if baseline is deleted

def initialize_baseline(services: Set[str]) -> bool:
    # ... existing code ...
    
    # Create immutable snapshot
    snapshot = {
        'timestamp': datetime.utcnow().isoformat(),
        'service_count': len(services),
        'services': sorted(list(services)),
        'checksum': hashlib.sha256(json.dumps(...).encode()).hexdigest()
    }
    
    s3.put_object(
        Bucket=BACKUP_BUCKET,
        Key=f'baseline-snapshots/{timestamp}.json',
        Body=json.dumps(snapshot),
        ServerSideEncryption='AES256',
        # S3 Object Lock: Retain-until-date
        ObjectLockMode='GOVERNANCE',
        ObjectLockRetainUntilDate=datetime.utcnow() + timedelta(days=90)
    )
    
    return True
```

---

## 2. Data Visibility in DynamoDB 🟡 MEDIUM

### Risk Description
All service names stored in DynamoDB are visible to users with `dynamodb:Scan` or `dynamodb:GetItem` access.

### Who Could See It
- AWS account users with DynamoDB permissions
- IAM roles with `dynamodb:*` permissions
- Cross-account access if granted

### Information Leaked
- All AWS services your organization uses
- Timeline of when services were first detected
- Which services are part of baseline vs. new

### Example Attack
```bash
# User with DynamoDB access could do:
aws dynamodb scan --table-name aws-service-monitor-registry

# Returns:
# - acm (baseline)
# - lambda (baseline)  
# - s3 (baseline)
# - new-ml-service (first_seen: 2026-04-25)  <- Recent addition!
```

### Current Mitigations ✅
- DynamoDB encrypted at rest (AWS managed)
- TLS encryption in transit
- IAM role scoped to specific table
- CloudTrail logs all access

### Recommended Enhancements

**Option 1: Encryption with KMS (Easy)**
```hcl
resource "aws_kms_key" "dynamodb" {
  description = "KMS key for DynamoDB encryption"
  enable_key_rotation = true
}

resource "aws_dynamodb_table" "service_registry" {
  # ... existing config ...
  
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }
}
```
Benefits:
- Customer-managed encryption keys
- Rotation enabled automatically
- Can audit key usage via CloudTrail

**Option 2: Hash Service Names (Medium Effort)**
```python
import hashlib

def hash_service_name(service_name: str) -> str:
    """Hash service names to hide identities."""
    return hashlib.sha256(service_name.encode()).hexdigest()[:16]

def initialize_baseline(services: Set[str]) -> bool:
    """Store baseline with hashed service names."""
    table = dynamodb.Table(DYNAMODB_TABLE)
    
    # Store mapping table separately (protected)
    mapping_table = dynamodb.Table('service-name-mapping')
    
    with table.batch_writer() as batch:
        for service in services:
            hashed = hash_service_name(service)
            
            # Store hashed name in main table
            batch.put_item(Item={
                'service_name': hashed,
                'is_baseline': True
            })
            
            # Store mapping in separate protected table (read-only)
            mapping_table.put_item(Item={
                'hash': hashed,
                'service': service,  # Only accessible to specific role
                'created': datetime.utcnow().isoformat()
            })
```

**Option 3: Service Name Tokenization (Strong)**
```python
def tokenize_service(service_name: str, token_key: str) -> str:
    """Generate non-reversible token for service name."""
    import hmac
    token = hmac.new(
        token_key.encode(),
        service_name.encode(),
        hashlib.sha256
    ).hexdigest()[:16]
    return token

# In Lambda initialization
SERVICE_TOKEN_KEY = os.environ.get('SERVICE_TOKEN_KEY')  # From Secrets Manager

# Store: token-abc123def456 instead of service name
# Query: Always use tokenized names
```

---

## 3. DynamoDB Scan Performance/Information Disclosure 🟡 MEDIUM

### Risk Description
The code scans entire DynamoDB table to get tracked services:

```python
def get_tracked_services() -> Set[str]:
    table = dynamodb.Table(DYNAMODB_TABLE)
    response = table.scan()  # Scans ALL items
    
    # This reveals:
    # - __baseline_initialized__ marker
    # - __pending_scp_update__xxx entries
    # - All service names and timestamps
```

### What's Leaked
- Baseline marker presence/absence
- All pending SCP updates (could show what changes are staged)
- Timing information

### Current Mitigation ✅
Already implemented - entries starting with `__` are filtered out:
```python
if not item['service_name'].startswith('__'):
    tracked.add(item['service_name'])
```

### Recommended Enhancement

Use DynamoDB Query instead of Scan (more efficient):
```python
def get_tracked_services() -> Set[str]:
    """Get services using Query instead of Scan."""
    table = dynamodb.Table(DYNAMODB_TABLE)
    
    # Option 1: Use GSI (Global Secondary Index)
    # More efficient, doesn't scan entire table
    response = table.query(
        IndexName='is_baseline-service_name-index',
        KeyConditionExpression='is_baseline = :baseline',
        ExpressionAttributeValues={':baseline': False},
        ProjectionExpression='service_name'
    )
    
    # Option 2: Use explicit exclusion
    response = table.scan(
        FilterExpression='attribute_not_exists(service_name) OR NOT begins_with(service_name, :prefix)',
        ExpressionAttributeValues={':prefix': '__'}
    )
```

---

## 4. Race Condition on Baseline Initialization 🟡 MEDIUM

### Risk Description
Multiple simultaneous Lambda invocations could both see "no baseline" and try to initialize:

```
Timeline:
T1: Lambda-1 checks baseline (not found)
T2: Lambda-2 checks baseline (not found)
T3: Lambda-1 initializes baseline (first init wins)
T4: Lambda-2 initializes baseline (overwrites Lambda-1's init)
T5: Result: Baseline contains mix of services from different times
```

### Current State
Unlikely because:
- EventBridge typically guarantees single execution per trigger time
- Lambda concurrent execution limit is per-account
- DynamoDB writes are atomic

### Recommended Mitigation

Add conditional write to prevent race conditions:
```python
def initialize_baseline(services: Set[str]) -> bool:
    """Atomically initialize baseline (fail if already exists)."""
    table = dynamodb.Table(DYNAMODB_TABLE)
    timestamp = datetime.utcnow().isoformat()
    
    try:
        # Use ConditionExpression to prevent overwrite
        table.put_item(
            Item={
                'service_name': BASELINE_MARKER,
                'first_seen': timestamp,
                'service_count': len(services),
                'status': 'initialized'
            },
            ConditionExpression='attribute_not_exists(service_name)'
            # Fails if marker already exists
        )
        
        # ... store services ...
        logger.info("Baseline initialized successfully (first init)")
        return True
        
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        logger.warning("Baseline already exists, skipping initialization")
        return True  # Not an error - baseline already initialized
```

---

## 5. Baseline Immutability / Integrity 🟡 MEDIUM

### Risk Description
Once baseline is initialized, there's no way to verify it hasn't been tampered with.

### Attack Scenario
```
1. Attacker gains temporary access to DynamoDB
2. Modifies baseline entries (removes unwanted services)
3. Deletes CloudWatch logs
4. System thinks baseline is legitimate
5. New services are not detected (attacker's service appears "old")
```

### Current Mitigations ✅
- CloudTrail logs all DynamoDB modifications
- DynamoDB PITR enabled (35-day restore window)
- Encrypted at rest

### Recommended Enhancements

**Option 1: Checksum Verification (Easy)**
```python
import hashlib

def calculate_baseline_checksum(services: Set[str]) -> str:
    """Generate checksum of baseline services."""
    service_string = json.dumps(sorted(list(services)))
    return hashlib.sha256(service_string.encode()).hexdigest()

def initialize_baseline(services: Set[str]) -> bool:
    """Store baseline with integrity checksum."""
    table = dynamodb.Table(DYNAMODB_TABLE)
    
    checksum = calculate_baseline_checksum(services)
    
    table.put_item(Item={
        'service_name': BASELINE_MARKER,
        'checksum': checksum,  # Detect tampering
        'service_count': len(services),
        'first_seen': datetime.utcnow().isoformat()
    })
    
    # Store immutable copy in S3
    s3.put_object(
        Bucket='audit-bucket',
        Key=f'baseline-checksum-{datetime.utcnow().isoformat()}',
        Body=checksum,
        ServerSideEncryption='AES256'
    )
```

**Option 2: Digital Signature (Strong)**
```python
import cryptography.hazmat.primitives.asymmetric.rsa as rsa
import cryptography.hazmat.primitives.hashes as hashes

def sign_baseline(services: Set[str], private_key) -> str:
    """Sign baseline with private key for tamper detection."""
    service_string = json.dumps(sorted(list(services)))
    
    signature = private_key.sign(
        service_string.encode(),
        rsa.PKCS1v15(),
        hashes.SHA256()
    )
    
    return signature.hex()

def verify_baseline_signature(services: Set[str], signature: str, public_key) -> bool:
    """Verify baseline signature hasn't been modified."""
    try:
        service_string = json.dumps(sorted(list(services)))
        public_key.verify(
            bytes.fromhex(signature),
            service_string.encode(),
            rsa.PKCS1v15(),
            hashes.SHA256()
        )
        return True
    except:
        return False
```

---

## 6. Operational Risks 🟡 MEDIUM

### Risk: Baseline Reset During Maintenance
**Scenario**: Operations team accidentally deletes baseline during table maintenance

**Mitigation**:
- Add confirmation prompt to delete baseline
- Store backup copy in S3
- Create CloudWatch alarm on baseline deletion

### Risk: Baseline Lost Due to DynamoDB Failure
**Scenario**: DynamoDB table is deleted, baseline lost

**Mitigation**:
- ✅ Already enabled: DynamoDB point-in-time recovery
- Can restore to any point in 35 days
- Document recovery procedure

### Risk: First Run Takes Too Long
**Scenario**: Initializing baseline with 1000+ services times out

**Mitigation**:
```python
def initialize_baseline(services: Set[str]) -> bool:
    """Initialize baseline with pagination for large service sets."""
    table = dynamodb.Table(DYNAMODB_TABLE)
    
    # Use batch write (more efficient than individual puts)
    with table.batch_writer(batch_size=25) as batch:
        # First, mark that initialization is in progress
        batch.put_item(Item={
            'service_name': '__baseline_initializing__',
            'status': 'in_progress'
        })
    
    # Then write services in chunks
    chunk_size = 100
    services_list = sorted(list(services))
    
    for i in range(0, len(services_list), chunk_size):
        chunk = services_list[i:i + chunk_size]
        with table.batch_writer(batch_size=25) as batch:
            for service in chunk:
                batch.put_item(Item={...})
    
    # Mark initialization complete
    table.put_item(Item={
        'service_name': '__baseline_initialized__',
        'status': 'initialized'
    })
```

---

## 7. Audit and Logging Gaps 🟡 MEDIUM

### Current Logging
```python
logger.info(f"Baseline initialized with {len(services)} services")
```

### Gaps
- No logging of WHO triggered baseline (if manual)
- No logging of baseline modifications
- Limited tampering detection

### Recommended Enhancements

```python
def initialize_baseline(services: Set[str], context=None) -> bool:
    """Initialize baseline with comprehensive audit logging."""
    
    # Get invocation context
    invoked_by = context.invoked_function_arn if context else 'unknown'
    
    # Log baseline initialization
    logger.info({
        'action': 'baseline_initialized',
        'service_count': len(services),
        'timestamp': datetime.utcnow().isoformat(),
        'invoked_by': invoked_by,
        'checksum': hashlib.sha256(
            json.dumps(sorted(list(services))).encode()
        ).hexdigest()
    })
    
    # Send to Audit Trail (CloudWatch Logs)
    audit_logger = logging.getLogger('audit')
    audit_logger.info({
        'event_type': 'BASELINE_INITIALIZED',
        'user_identity': invoked_by,
        'timestamp': datetime.utcnow().isoformat(),
        'service_count': len(services)
    })
    
    # Store audit record in DynamoDB
    audit_table = dynamodb.Table('service-monitor-audit')
    audit_table.put_item(Item={
        'audit_id': f"baseline-{datetime.utcnow().isoformat()}",
        'event': 'baseline_initialized',
        'timestamp': datetime.utcnow().isoformat(),
        'invoked_by': invoked_by,
        'service_count': len(services),
        'ttl': int((datetime.utcnow() + timedelta(days=90)).timestamp())
    })
```

---

## Security Risk Summary Table

| Issue | Severity | Likelihood | Impact | Current Mitigation | Enhancement |
|-------|----------|------------|--------|-------------------|-------------|
| Baseline Reset | 🟡 MEDIUM | Low | High | CloudTrail, PITR | Immutable marker, S3 snapshot |
| Service Name Visibility | 🟡 MEDIUM | Medium | Medium | DynamoDB encryption | KMS, hashing, tokenization |
| Scan Information Leak | 🟡 MEDIUM | Low | Low | Filter `__` entries | Use Query instead of Scan |
| Race Condition | 🟡 MEDIUM | Very Low | Medium | Single trigger | Conditional write |
| Baseline Tampering | 🟡 MEDIUM | Low | High | CloudTrail, PITR | Checksum, signatures |
| Operational Errors | 🟡 MEDIUM | Low | Medium | CloudWatch logs | Backup procedure |
| Audit Gaps | 🟡 MEDIUM | Low | Medium | CloudTrail | Comprehensive audit table |

---

## Recommended Implementation Priority

### Phase 1 (Immediate) - Cost: None
```
✅ Add conditional write for race condition protection
✅ Improve audit logging (metadata about who triggered)
✅ Document baseline reset procedure
```

### Phase 2 (Soon) - Cost: ~$50/month
```
✅ KMS encryption for DynamoDB (already enabled PITR)
✅ S3 immutable baseline snapshot (retention lock)
✅ Enhanced CloudWatch alarm on baseline changes
```

### Phase 3 (Optional) - Cost: ~$100/month
```
✅ Service name hashing/tokenization
✅ Separate audit table with TTL
✅ Digital signature verification
✅ Multi-region baseline replication
```

---

## Conclusion

**Baseline initialization is SAFE for production** with existing mitigations:
- ✅ DynamoDB encryption at rest
- ✅ CloudTrail logging of all changes
- ✅ DynamoDB PITR for recovery
- ✅ IAM role restricted access
- ✅ Automatic filtering of metadata entries

**Recommended enhancements**:
1. Add conditional write (prevent race condition)
2. KMS encryption (customer-managed keys)
3. S3 baseline snapshot with object lock
4. Enhanced audit logging

**Not critical but good to have**:
- Service name hashing
- Digital signature verification
- Separate audit table

The baseline initialization feature follows security best practices and introduces no new critical vulnerabilities beyond those already present in the overall solution.
