# 🏗️ Architecture Overview

Comprehensive architecture documentation for the AWS Service Monitor system, including detailed diagrams and explanations.

---

## 📑 Contents

1. [System Architecture](#system-architecture) - High-level system design
2. [Data Flow Diagram](#data-flow-diagram) - Request/response sequences
3. [Component Interactions](#component-interactions) - Service interactions
4. [Infrastructure Stack](#infrastructure-stack) - Terraform resources
5. [Request/Response Flow](#requestresponse-flow) - API-level details
6. [AWS Services](#aws-services-interaction) - Service dependencies
7. [Security Architecture](#security-architecture) - Security controls
8. [Deployment](#deployment-architecture) - Deployment process
9. [Scaling](#scaling-characteristics) - Performance & scaling
10. [Costs](#cost-architecture) - Cost breakdown
11. [Disaster Recovery](#disaster-recovery) - Backup & recovery

---

## System Architecture

**Overview**: Complete system architecture showing all AWS services and their relationships.

```mermaid
graph TB
    subgraph "External Data Sources"
        AWS["🌐 AWS Service Reference<br/>(servicereference.eu-west-2.amazonaws.com)"]
    end
    
    subgraph "AWS Management Account"
        subgraph "Orchestration"
            EB["📅 EventBridge<br/>Schedule Rule<br/>cron(0 8 * * ? *)"]
        end
        
        subgraph "Compute & Logic"
            Lambda["⚡ Lambda Function<br/>aws-service-monitor<br/>Python 3.11"]
        end
        
        subgraph "Data Layer"
            DB["💾 DynamoDB Table<br/>aws-service-monitor-registry<br/>PAY_PER_REQUEST<br/>+ Baseline Integrity"]
            S3["📦 S3 Bucket<br/>Immutable Snapshots<br/>Object Lock (90d)"]
        end
        
        subgraph "Policy Management"
            ORG["🏢 AWS Organizations<br/>Service Control Policies<br/>blacklist SCP"]
        end
        
        subgraph "Notification & Monitoring"
            SES["📧 Amazon SES<br/>Email Service<br/>Verified Addresses"]
            CW["📊 CloudWatch<br/>Logs & Metrics<br/>Dashboard & Alarms"]
            SNS["📢 SNS Topic<br/>Alert Distribution"]
        end
    end
    
    subgraph "Recipients"
        EMAIL["✉️ Email Recipients<br/>(verified in SES)"]
    end
    
    AWS -->|"HTTPS GET<br/>Fetch JSON"| Lambda
    EB -->|"Trigger<br/>Invoke"| Lambda
    Lambda -->|"Read/Write<br/>Service Registry<br/>+ Baseline"| DB
    Lambda -->|"Store<br/>Snapshots"| S3
    Lambda -->|"Query & Update<br/>SCP Policy"| ORG
    Lambda -->|"Send Email<br/>HTML + Text"| SES
    Lambda -->|"Write Logs<br/>Put Metrics"| CW
    SNS -->|"Alert Topic"| EMAIL
    SES -->|"Email<br/>Notification"| EMAIL
```

```mermaid
graph TB
    subgraph "External Data Sources"
        AWS["AWS Service Reference<br/>(servicereference.eu-west-2.amazonaws.com)"]
    end
    
    subgraph "AWS Management Account"
        subgraph "Orchestration"
            EB["EventBridge<br/>Schedule Rule<br/>cron(0 8 * * ? *)"]
        end
        
        subgraph "Compute & Logic"
            Lambda["Lambda Function<br/>aws-service-monitor<br/>Python 3.11"]
        end
        
        subgraph "Data Layer"
            DB["DynamoDB Table<br/>aws-service-monitor-registry<br/>PAY_PER_REQUEST"]
        end
        
        subgraph "Policy Management"
            ORG["AWS Organizations<br/>Service Control Policies<br/>blacklist SCP"]
        end
        
        subgraph "Notification"
            SES["Amazon SES<br/>Email Service<br/>Verified Addresses"]
        end
        
        subgraph "Monitoring"
            CW["CloudWatch<br/>Logs & Metrics<br/>14-day retention"]
        end
    end
    
    subgraph "Recipients"
        EMAIL["Email Recipients<br/>(verified in SES)"]
    end
    
    AWS -->|"HTTPS GET<br/>Fetch JSON"| Lambda
    EB -->|"Trigger Invoke"| Lambda
    Lambda -->|"Read/Write<br/>Service Registry"| DB
    Lambda -->|"Query Policy<br/>Update Policy"| ORG
    Lambda -->|"Send Email<br/>HTML + Text"| SES
    Lambda -->|"Write Logs<br/>Put Metrics"| CW
    SES -->|"Email Notification"| EMAIL
```

**Key Components**:
- **EventBridge**: Triggers Lambda on daily schedule (8 AM UTC)
- **Lambda**: Orchestrates all operations (10-20s typical execution)
- **DynamoDB**: Maintains service registry with baseline integrity checksums
- **S3**: Stores immutable snapshots with Object Lock for forensics
- **Organizations**: Manages SCP policy with new service additions
- **SES/SNS**: Sends email notifications and alerts
- **CloudWatch**: Logs all executions and publishes custom metrics

---

## Data Flow Diagram

**Execution Timeline**: Complete sequence of operations from trigger to completion.

```mermaid
sequenceDiagram
    participant EB as EventBridge
    participant Lambda as Lambda Function
    participant Web as Service Reference
    participant DB as DynamoDB
    participant ORG as Organizations
    participant SES as SES
    participant Email as Recipients
    
    EB->>Lambda: Invoke (scheduled)
    
    activate Lambda
    Lambda->>Web: Fetch services (HTTPS GET)
    Web-->>Lambda: Return JSON with services
    
    Lambda->>DB: Scan tracked services
    DB-->>Lambda: Return tracked services
    
    Note over Lambda: Calculate new services<br/>current - tracked
    
    alt Has new services
        Lambda->>ORG: List policies (blacklist)
        ORG-->>Lambda: Return policy details
        
        Lambda->>ORG: Get policy content
        ORG-->>Lambda: Return policy JSON
        
        Lambda->>Lambda: Add services to policy
        
        Lambda->>ORG: Update policy
        ORG-->>Lambda: Confirm update
        
        Lambda->>DB: Store new services
        DB-->>Lambda: Confirm write
        
        Lambda->>SES: Send email
        SES-->>Lambda: Message ID
        SES->>Email: Deliver notification
        Email-->>SES: Delivery confirmed
    else No new services
        Note over Lambda: Log and exit
    end
    
    Lambda->>DB: Write completion status
    deactivate Lambda
```

**Flow Details**:
1. EventBridge triggers Lambda function (scheduled)
2. Lambda fetches current services from AWS service reference (HTTPS GET)
3. Lambda scans DynamoDB for previously tracked services
4. Compares current vs. tracked to identify new services
5. **If new services**: Updates SCP policy, stores new entries, sends email notification
6. **If no changes**: Logs result and exits
7. Publishes execution metrics to CloudWatch

---

## Component Interactions

**Step-by-Step Logic**: Detailed view of Lambda function operations and their sequence.

```mermaid
graph LR
    subgraph "AWS Service Reference"
        SVCREF["Service Reference JSON<br/>- Service names<br/>- Metadata<br/>- Updates daily"]
    end
    
    subgraph "Lambda Function Logic"
        FETCH["1. Fetch Services<br/>urllib3.PoolManager<br/>HTTPS GET"]
        COMPARE["2. Compare Services<br/>Set difference<br/>new = current - tracked"]
        UPDATE_SCP["3. Update SCP<br/>Add to policy document<br/>Call Organizations API"]
        STORE["4. Store Services<br/>Write to DynamoDB<br/>with timestamp"]
        EMAIL["5. Send Notification<br/>Render HTML/Text<br/>Call SES SendEmail"]
        LOG["6. Log Execution<br/>CloudWatch Logs<br/>Debug info"]
    end
    
    subgraph "State & Policy"
        DDB["DynamoDB Table<br/>- service_name (PK)<br/>- first_seen<br/>- last_updated"]
        SCP["SCP Policy<br/>- Deny statements<br/>- Service actions<br/>- Conditions"]
    end
    
    subgraph "Notifications"
        RECIPIENTS["Email Recipients<br/>- HTML version<br/>- Plain text<br/>- Timestamp<br/>- Service list"]
    end
    
    SVCREF -->|JSON| FETCH
    FETCH --> COMPARE
    COMPARE --> UPDATE_SCP
    COMPARE --> STORE
    COMPARE --> EMAIL
    COMPARE --> LOG
    
    COMPARE -->|"Get current state"| DDB
    STORE -->|"Write new services"| DDB
    UPDATE_SCP -->|"Read/Update policy"| SCP
    EMAIL -->|"HTML + Text"| RECIPIENTS
```

**Six-Step Process**:
1. **Fetch**: Get current services from AWS
2. **Compare**: Identify new services (set difference)
3. **Update SCP**: Add new services to blacklist policy
4. **Store**: Write new services to DynamoDB with timestamps
5. **Notify**: Send HTML + Text email to recipients
6. **Log**: Write execution details to CloudWatch

---

## Infrastructure Stack

**IaC Resources**: All AWS resources managed by Terraform.

```mermaid
graph TD
    subgraph "Terraform Modules"
        TF["Terraform Configuration"]
    end
    
    subgraph "IAM Layer"
        ROLE["Lambda Execution Role<br/>aws-service-monitor-lambda-role"]
        POLICY_DDB["DynamoDB Policy<br/>- GetItem<br/>- PutItem<br/>- Scan"]
        POLICY_ORG["Organizations Policy<br/>- ListPolicies<br/>- DescribePolicy<br/>- UpdatePolicy"]
        POLICY_SES["SES Policy<br/>- SendEmail<br/>- SendRawEmail"]
        POLICY_LOGS["Logs Policy<br/>- CreateLogGroup<br/>- PutLogEvents"]
    end
    
    subgraph "Lambda Layer"
        FUNC["Lambda Function<br/>aws-service-monitor<br/>Python 3.11<br/>Timeout: 300s"]
        LAYER["Dependencies<br/>- boto3<br/>- urllib3<br/>- json"]
    end
    
    subgraph "Data Layer"
        DDB["DynamoDB Table<br/>aws-service-monitor-registry<br/>Pay-per-request<br/>Retention: Unlimited"]
        LOGS["CloudWatch Log Group<br/>/aws/lambda/aws-service-monitor<br/>Retention: 14 days"]
    end
    
    subgraph "Orchestration Layer"
        RULE["EventBridge Rule<br/>aws-service-monitor-daily<br/>Schedule: cron(0 8 * * ? *)"]
        PERM["Lambda Permission<br/>Allow EventBridge invoke"]
    end
    
    TF --> ROLE
    ROLE --> POLICY_DDB
    ROLE --> POLICY_ORG
    ROLE --> POLICY_SES
    ROLE --> POLICY_LOGS
    TF --> FUNC
    TF --> LAYER
    TF --> DDB
    TF --> LOGS
    TF --> RULE
    TF --> PERM
    
    POLICY_DDB --> FUNC
    POLICY_ORG --> FUNC
    POLICY_SES --> FUNC
    POLICY_LOGS --> FUNC
    RULE --> PERM
    PERM --> FUNC
```

**Hierarchy**:
- **IAM Layer**: Execution role with minimal required permissions
- **Lambda Layer**: Function configuration, timeout, memory, runtime
- **Data Layer**: DynamoDB table and CloudWatch log group
- **Orchestration**: EventBridge rule and Lambda invocation permission

All managed declaratively via Terraform for reproducibility.

---

## Request/Response Flow

**Detailed API Interactions**: Low-level view of all API calls made during execution.

```mermaid
graph TD
    subgraph "Service Reference Fetch"
        REQ1["GET /"]
        RESP1["JSON: services object"]
        PARSE["Parse JSON<br/>Extract service names"]
        RESULT1["Set[str]"]
    end
    
    subgraph "DynamoDB Operations"
        REQ2["Scan operation"]
        RESP2["Item[]"]
        EXTRACT["Extract service_name<br/>from items"]
        RESULT2["Set[str]"]
    end
    
    subgraph "Organizations API"
        REQ3["ListPolicies filter=SCP"]
        RESP3["Policy[]"]
        FIND["Find blacklist policy"]
        GET_POLICY["DescribePolicy PolicyId"]
        RESP4["Policy content JSON"]
        UPDATE["UpdatePolicy with<br/>new statements"]
    end
    
    subgraph "SES Email"
        RENDER["Render HTML template<br/>Render text template"]
        SEND["SendEmail<br/>Source: sender<br/>To: recipients"]
        RESULT3["MessageId"]
    end
    
    REQ1 --> RESP1
    RESP1 --> PARSE
    PARSE --> RESULT1
    
    REQ2 --> RESP2
    RESP2 --> EXTRACT
    EXTRACT --> RESULT2
    
    REQ3 --> RESP3
    RESP3 --> FIND
    FIND --> GET_POLICY
    GET_POLICY --> RESP4
    RESP4 --> UPDATE
    UPDATE --> RESULT3
    
    RENDER --> SEND
    SEND --> RESULT3
```

**API Calls**:
- **Service Reference**: GET / → JSON response with services
- **DynamoDB**: Scan → Item[] → Extract service names
- **Organizations**: ListPolicies → Find blacklist → DescribePolicy → UpdatePolicy
- **SES**: SendEmail → MessageId response
- **CloudWatch**: PutMetricData → Success response

---

## AWS Services Interaction

**Service Dependencies**: Which AWS services are used and why.

```mermaid
graph LR
    subgraph "AWS Services Used"
        EB["EventBridge<br/>(Scheduling)"]
        Lambda["Lambda<br/>(Compute)"]
        DDB["DynamoDB<br/>(State)"]
        ORG["Organizations<br/>(SCP)"]
        SES["SES<br/>(Email)"]
        CW["CloudWatch<br/>(Monitoring)"]
        IAM["IAM<br/>(Auth)"]
    end
    
    Lambda -->|Scheduled Invocation| EB
    EB -->|Invoke| Lambda
    Lambda -->|Assume Role| IAM
    IAM -->|Permissions| Lambda
    Lambda -->|Read/Write| DDB
    Lambda -->|Query/Update| ORG
    Lambda -->|Send Email| SES
    Lambda -->|Write Logs| CW
```

## Security Architecture

```mermaid
graph TD
    subgraph "Identity & Access"
        ROLE["Execution Role<br/>aws-service-monitor-lambda-role"]
        TRUST["Trust Policy<br/>Principal: lambda.amazonaws.com"]
        PERMS["Resource Policies<br/>- DynamoDB table policy<br/>- SES send permission<br/>- Org read/update"]
    end
    
    subgraph "Data Protection"
        HTTPS["HTTPS TLS 1.2+<br/>Service Reference"]
        KMS["AWS KMS Default<br/>CloudWatch Logs"]
        DDB_ENC["DynamoDB Encryption<br/>AWS Managed Keys"]
    end
    
    subgraph "Network Isolation"
        VPC["No VPC Required<br/>Lambda Internet Access"]
        SGNET["Security Group<br/>Outbound HTTPS"]
    end
    
    subgraph "Audit & Logging"
        CWLOGS["CloudWatch Logs<br/>All executions"]
        CLOUDTRAIL["CloudTrail<br/>API calls"]
        METRICS["CloudWatch Metrics<br/>Invocations/Errors"]
    end
    
    ROLE --> TRUST
    ROLE --> PERMS
    HTTPS -->|Encrypted| CWLOGS
    KMS --> CWLOGS
    KMS --> DDB_ENC
    VPC --> SGNET
    CWLOGS --> METRICS
    CLOUDTRAIL --> METRICS
```

## Deployment Architecture

```mermaid
graph TD
    subgraph "Local Development"
        TF["Terraform Files<br/>- *.tf<br/>- variables.tfvars"]
        LAMBDA["Lambda Code<br/>- lambda/index.py<br/>- lambda/requirements.txt"]
    end
    
    subgraph "Terraform Backend"
        STATE["Terraform State<br/>(Local or Remote)"]
    end
    
    subgraph "AWS Management Account"
        PLAN["Terraform Plan"]
        APPLY["Terraform Apply"]
        RESOURCES["Resources Created<br/>- Lambda<br/>- DynamoDB<br/>- EventBridge<br/>- IAM<br/>- CloudWatch"]
    end
    
    TF --> PLAN
    LAMBDA --> PLAN
    PLAN --> STATE
    STATE --> APPLY
    APPLY --> RESOURCES
```

## Scaling Characteristics

### Horizontal Scaling
- **EventBridge**: Unlimited invocations (AWS managed)
- **Lambda**: Auto-scales (concurrent execution limit: 1000 by default)
- **DynamoDB**: On-demand (auto-scales with pay-per-request)

### Vertical Scaling
- **Lambda Memory**: 128 MB - 10,240 MB (adjust in main.tf)
- **Lambda Timeout**: 300 seconds (configurable)
- **DynamoDB**: Unlimited storage (pay-per-request)

### Performance Characteristics

```
Service Fetch:     ~2-5 seconds
DynamoDB Scan:     ~1-2 seconds (depends on table size)
Service Comparison: <100 ms
SCP Update:        ~3-5 seconds
Email Send:        ~2-3 seconds
Total Execution:   ~10-20 seconds (typically)
```

## Cost Architecture

```
Component               | Cost Factor        | Estimated Monthly
------------------------|--------------------|-----------------
Lambda Execution        | 30 invocations     | $0.20
DynamoDB (on-demand)    | Scan + writes      | $1.00
CloudWatch Logs         | Log storage        | $0.50
SES Email              | Recipients count   | $0.10
EventBridge Rule       | 30 invocations     | Free
CloudWatch Metrics     | API calls          | Free
IAM Roles              | No cost            | Free
Organizations API      | API calls          | Free
```

## High Availability Considerations

### Current Architecture
- **Single Region**: Management account (eu-west-2)
- **Single Schedule**: Daily at 8 AM UTC
- **No Backup Lambda**: Single function invocation

### High Availability Options
1. **Multi-region Replication**: Deploy to multiple regions with cross-region state sync
2. **Backup Invocation**: Add secondary EventBridge rule as backup
3. **Lambda Concurrency**: Set reserved concurrency > 1
4. **DynamoDB Backup**: Enable point-in-time recovery
5. **Dead Letter Queue**: Send failed invocations to SQS

## Disaster Recovery

### Recovery Objectives
- **RTO** (Recovery Time Objective): < 1 hour (manual redeployment)
- **RPO** (Recovery Point Objective): 1 day (daily monitoring schedule)

### Backup Strategy
```
Service Registry State:
  - DynamoDB on-demand billing (pay for what you use)
  - Enable point-in-time recovery (optional)
  - Export to S3 daily (optional)

Lambda Code:
  - Stored in Git repository
  - Terraform manages versioning
  - Easy redeployment

SCP Policy:
  - Managed by Organizations API
  - Tracked in Terraform state
  - Version history in CloudTrail
```

## Related Documentation

- See [README.md](./README.md) for project overview
- See [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) for setup instructions
- See [DEVELOPMENT.md](./DEVELOPMENT.md) for customization guidance
