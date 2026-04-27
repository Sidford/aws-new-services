# AWS Service Monitor - Operational Guide

Complete operational procedures and incident response runbooks for the AWS Service Monitor solution.

---

## Quick Links

### System Status
- **CloudWatch Dashboard**: [AWS Service Monitor Dashboard](https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=aws-service-monitor)
- **CloudWatch Logs**: [Lambda Logs](/aws/lambda/aws-service-monitor)
- **SNS Topic**: For operational alerts and alarms

### Runbooks by Topic

#### Emergency Response
1. **[Baseline Integrity Violation](./BASELINE_INTEGRITY_VIOLATION.md)** - Detection and recovery from tampering attempts
2. **[SCP Policy Rollback](./SCP_POLICY_ROLLBACK.md)** - Reverse incorrect SCP updates

#### Maintenance & Troubleshooting
3. **[Lambda Timeout Recovery](./LAMBDA_TIMEOUT_RECOVERY.md)** - Fix slow/timeout executions
4. **[DynamoDB Recovery](./DYNAMODB_RECOVERY.md)** - Restore from point-in-time recovery
5. **[Baseline Reset Procedure](./BASELINE_RESET.md)** - Reinitialize baseline safely
6. **[Service Registry Cleanup](./SERVICE_REGISTRY_CLEANUP.md)** - Remove stale or invalid entries

#### Response & Investigation
7. **[Incident Response](./INCIDENT_RESPONSE.md)** - Consolidated response guide

---

## Alert Mapping

### Severity Levels

| Level | Alarm | Runbook | Response Time |
|-------|-------|---------|---|
| **CRITICAL** | Lambda Errors | [Incident Response](./INCIDENT_RESPONSE.md) | < 15 min |
| **CRITICAL** | Baseline Integrity Violation | [Baseline Integrity](./BASELINE_INTEGRITY_VIOLATION.md) | < 5 min |
| **CRITICAL** | Lambda Timeout | [Lambda Timeout](./LAMBDA_TIMEOUT_RECOVERY.md) | < 30 min |
| **CRITICAL** | EventBridge Rule Disabled | [Incident Response](./INCIDENT_RESPONSE.md) | < 15 min |
| **WARNING** | Lambda Duration High | [Lambda Timeout](./LAMBDA_TIMEOUT_RECOVERY.md) | < 1 hour |
| **WARNING** | DynamoDB Throttles | [DynamoDB Recovery](./DYNAMODB_RECOVERY.md) | < 1 hour |
| **WARNING** | Missed Execution | [Incident Response](./INCIDENT_RESPONSE.md) | < 2 hours |

---

## Key Metrics to Monitor

### Lambda Performance
- **Duration**: Expected 10-20 seconds under normal conditions
  - Alert: > 270 seconds (90% of 300s timeout)
  - Action: Follow [Lambda Timeout Recovery](./LAMBDA_TIMEOUT_RECOVERY.md)
- **Error Rate**: Should be zero in normal operation
  - Alert: ≥ 1 error per hour
  - Action: Check logs and follow [Incident Response](./INCIDENT_RESPONSE.md)
- **Invocations**: Should occur once daily
  - Alert: 0 invocations in 24 hours
  - Action: Verify EventBridge rule and check [Incident Response](./INCIDENT_RESPONSE.md)

### DynamoDB Performance
- **Consumed Capacity**: Typically < 10 units per day
  - Alert: Throttles detected (UserErrors)
  - Action: Follow [DynamoDB Recovery](./DYNAMODB_RECOVERY.md)
- **Service Count**: 200-350 services typical for AWS
  - Trend: Should be stable with occasional additions
  - Increase: New AWS services being released

### Application Metrics
- **Baseline Integrity Status**: Should always be 1 (OK)
  - Alert: Value = 0 (Failed)
  - Action: Follow [Baseline Integrity Violation](./BASELINE_INTEGRITY_VIOLATION.md)
- **New Services Detected**: Variable, typically 0-5 per execution
  - Pattern: Increases during AWS product launches
  - Action: Review and approve SCP changes

---

## Operational Procedures

### Daily Checks (Automated)
- EventBridge triggers Lambda once daily
- Lambda validates baseline integrity
- Lambda scans for new services
- Metrics published to CloudWatch
- Alarms monitored automatically

### Weekly Checks (Manual)
```bash
# Check CloudWatch Dashboard for anomalies
# Review CloudWatch Logs for errors
# Verify SNS subscriptions are active
# Test alarm notifications (optional)
```

### Monthly Reviews (Manual)
- Review service additions and SCP changes
- Validate DynamoDB point-in-time recovery works
- Verify S3 immutable snapshots are present
- Audit CloudTrail logs for unauthorized access

---

## Common Issues & Quick Fixes

### Issue: Alarm fires repeatedly
**Diagnosis**: Check CloudWatch Logs for root cause
**Quick Fix**: 
1. Review the specific error in logs
2. Follow appropriate runbook above
3. Apply fix
4. Monitor for resolution

### Issue: High Lambda duration
**Diagnosis**: Service reference endpoint slow or large service list
**Fix**: Follow [Lambda Timeout Recovery](./LAMBDA_TIMEOUT_RECOVERY.md)

### Issue: Missed execution
**Diagnosis**: EventBridge rule disabled or Lambda permission removed
**Fix**: Follow [Incident Response](./INCIDENT_RESPONSE.md) Step 3

### Issue: DynamoDB throttling
**Diagnosis**: On-demand billing may need increase
**Fix**: Follow [DynamoDB Recovery](./DYNAMODB_RECOVERY.md)

---

## Escalation Paths

**Level 1 (Immediate)**: On-call engineer
- Review alert and logs
- Follow appropriate runbook
- Document actions taken

**Level 2 (30 min+)**: Team lead
- If Level 1 cannot resolve
- Authorization for major changes
- Root cause analysis

**Level 3 (2 hour+)**: Architecture review
- If systemic issues identified
- Design changes needed
- Change control process

---

## Preventive Maintenance

### Weekly
- [ ] Verify dashboard displays recent data
- [ ] Confirm SNS subscriptions deliver alerts
- [ ] Check for any WARN/ERROR logs

### Monthly
- [ ] Test alarm response by triggering test alarm
- [ ] Verify CloudTrail logs are being recorded
- [ ] Review IAM permissions for required access

### Quarterly
- [ ] Audit baseline snapshot storage
- [ ] Review and update runbooks
- [ ] Capacity planning for service growth
- [ ] Security assessment

---

## Performance Baseline

### Expected Metrics
- Lambda execution time: 10-20 seconds
- DynamoDB consumed units: < 10 per day
- CloudWatch metric latency: 1-2 minutes
- Service detection latency: < 1 minute

### Capacity Planning
- Services per baseline: ~300
- New services per month: ~5-10
- DynamoDB storage: ~100 KB per 100 services
- CloudWatch Logs: ~1 MB per day

---

## Contacts & Resources

### AWS Support
- Service status: https://status.aws.amazon.com
- AWS Support Console: https://console.aws.amazon.com/support
- Security reporting: https://aws.amazon.com/security/vulnerability-reporting/

### Documentation
- [README.md](../README.md) - Project overview
- [SECURITY.md](../SECURITY.md) - Security controls
- [ARCHITECTURE.md](../ARCHITECTURE.md) - Architecture diagrams
- [threat-model/THREAT_MODEL.md](../threat-model/THREAT_MODEL.md) - Threat analysis

---

## Change Log

### v2.0 (2026-04-24)
- ✅ Added CloudWatch Dashboard for monitoring
- ✅ Added CloudWatch Alarms with SNS notifications
- ✅ Published comprehensive operational runbooks
- ✅ Baseline integrity monitoring (T004)

### v1.0 (2026-04-20)
- ✅ Initial release

---

**Last Updated**: 2026-04-24  
**Next Review**: 2026-05-24
