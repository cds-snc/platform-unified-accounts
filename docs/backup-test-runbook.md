# Annual Backup Test & Contingency Plan Runbook

**System:** Platform Unified Accounts — SSO/IdP
**Cadence:** Annual (minimum)
**Controls satisfied:** CP-9(1), CP-9(2), supports CP-10

---

## 1. Purpose

This runbook describes the annual procedure to:

1. Verify the **reliability and integrity** of the automated backups taken of the Platform Unified Accounts SSO/IdP system (CP-9(1)).
2. Exercise the **contingency restoration** of system functions from a sample of backup data (CP-9(2)).
3. Capture **evidence** (date, executor, outcome, deviations) that can be linked from the Plan of Action and Milestones (PoAM) and provided to assessors.

The system stores all persistent state in two places:

| Data store | What it holds | Backup mechanism | Retention |
|------------|--------------|------------------|-----------|
| Aurora PostgreSQL | Zitadel relational state: users, orgs, projects, OIDC apps, sessions, MFA factors, audit log table | RDS automated backups (continuous + daily snapshot) configured in [platform-unified-accounts/terraform/aws/database.tf](platform-unified-accounts/terraform/aws/database.tf#L25-L26) | 14 days |
| EFS | User Portal personal access token under `/idp` | AWS Backup via `aws_efs_backup_policy` in [platform-unified-accounts/terraform/aws/efs.tf](platform-unified-accounts/terraform/aws/efs.tf#L53-L57) | 35 days |

A successful test must restore **both** stores within the Staging account alongside the live infrastructure and show the Zitadel IdP comes up and serves an authentication flow against the restored data.

---

## 2. Scope & Sampling

A full DR cutover is **not** required. The test uses a sample-based approach (CP-9(2)):

- **Database:** the most recent successful automated snapshot of staging data.
- **EFS:** the most recent recovery point in the AWS Backup vault for the corresponding EFS file system.
- **Functional:** the health check endpoint plus a single end-to-end OIDC authorization-code login using a test user.

The test is performed entirely within the **Staging AWS account**: a new Aurora cluster and EFS file system are restored from backup alongside the live resources, the ECS services are temporarily switched to the restored stores, the application is validated, and the restored stores are then deleted.

> **Important:** this procedure temporarily redirects the Staging ECS services to the restored data stores. Co-ordinate with the team to ensure the Staging environment is not being actively used for integration testing during the maintenance window.

---

## 3. Prerequisites

Before starting, confirm:

- [ ] You have `AdministratorAccess` (or equivalent) to the Staging AWS account.
- [ ] A maintenance window has been agreed with the team for the Staging environment.

---

## 4. Procedure

### 4.1 Identify the source backups

```bash
# Aurora — latest automated snapshot for the staging cluster
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier idp-staging \
  --snapshot-type automated \
  --query 'reverse(sort_by(DBClusterSnapshots,&SnapshotCreateTime))[0].[DBClusterSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table

# EFS — latest recovery point in the default backup vault
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name Default \
  --query 'reverse(sort_by(RecoveryPoints,&CreationDate))[?contains(ResourceArn,`file-system/`)] | [0].[RecoveryPointArn,CreationDate,Status]' \
  --output table
```

Record both identifiers in the test record (§5).

### 4.2 Restore the Aurora snapshot to a new cluster in Staging

Restore the snapshot to a new cluster (`idp-staging-restore-test`) in the same Staging VPC, subnet group, and security groups as the live cluster. This keeps the restored cluster isolated from the public internet while remaining accessible to the ECS tasks.

```bash
export AWS_PROFILE=idp-staging
SRC_AUTO_SNAP=<snapshot-id-from-4.1>
RESTORE_CLUSTER=idp-staging-restore-test

# Restore the cluster from the snapshot
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier "$RESTORE_CLUSTER" \
  --snapshot-identifier "$SRC_AUTO_SNAP" \
  --engine aurora-postgresql \
  --db-subnet-group-name <staging-db-subnet-group-name> \
  --vpc-security-group-ids <staging-rds-security-group-id> \
  --no-publicly-accessible

# Create a writer instance for the restored cluster
aws rds create-db-instance \
  --db-instance-identifier "${RESTORE_CLUSTER}-instance-1" \
  --db-cluster-identifier "$RESTORE_CLUSTER" \
  --db-instance-class db.t3.medium \
  --engine aurora-postgresql
```

Poll until the cluster and instance are `available`:

```bash
aws rds wait db-cluster-available --db-cluster-identifier "$RESTORE_CLUSTER"

# Capture the writer endpoint for §4.3
RESTORE_DB_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$RESTORE_CLUSTER" \
  --query 'DBClusters[0].Endpoint' \
  --output text)
echo "Restored cluster endpoint: $RESTORE_DB_ENDPOINT"
```

### 4.3 Restore the EFS recovery point to a new file system in Staging

```bash
export AWS_PROFILE=idp-staging
SRC_RP_ARN=<recovery-point-arn-from-4.1>
STAGING_ACCT_ID=$(aws sts get-caller-identity --query Account --output text)

# Start the restore job — this creates a new EFS file system from the recovery point
RESTORE_JOB_ID=$(aws backup start-restore-job \
  --recovery-point-arn "$SRC_RP_ARN" \
  --iam-role-arn "arn:aws:iam::${STAGING_ACCT_ID}:role/service-role/AWSBackupDefaultServiceRole" \
  --metadata "{\"file-system-id\":\"\",\"newFileSystem\":\"true\",\"Encrypted\":\"true\",\"KmsKeyId\":\"<efs-kms-key-arn>\",\"PerformanceMode\":\"generalPurpose\",\"CreationToken\":\"idp-staging-restore-test-$(date +%Y%m%d)\"}" \
  --query 'RestoreJobId' \
  --output text)
echo "Restore job: $RESTORE_JOB_ID"
```

Poll until the restore job status is `COMPLETED` and capture the new file system ID:

```bash
aws backup wait restore-job-successful --restore-job-id "$RESTORE_JOB_ID" 2>/dev/null || \
  watch -n 15 "aws backup describe-restore-job --restore-job-id $RESTORE_JOB_ID --query '[Status,StatusMessage]' --output text"

RESTORE_EFS_ID=$(aws backup describe-restore-job \
  --restore-job-id "$RESTORE_JOB_ID" \
  --query 'CreatedResourceArn' \
  --output text | cut -d/ -f2)
echo "Restored EFS ID: $RESTORE_EFS_ID"
```

Add the necessary mount targets in the Staging VPC subnets so ECS tasks can reach the restored file system:

```bash
for SUBNET_ID in <subnet-id-1> <subnet-id-2>; do
  aws efs create-mount-target \
    --file-system-id "$RESTORE_EFS_ID" \
    --subnet-id "$SUBNET_ID" \
    --security-groups <staging-efs-security-group-id>
done
```

Wait for all mount targets to become `available` before continuing.

### 4.4 Update the ECS services to use the restored data stores

1. Create a new `idp` task definition that uses the restored RDS cluster endpoint and EFS.
2. Create a new `idp-login` task definition that uses the restored EFS.
3. Update both the `idp` and `idp-login` services to use the new task definition.
4. Wait for both service deployments to complete.

### 4.5 Validate application function

With the ECS services now running against the restored data stores, perform the following checks against the Staging ALB:

1. **Health check** — confirm the IdP is up and connected to the restored database:
   ```bash
   curl -s https://auth.cdssandbox.xyz/debug/healthz | jq .
   # Expected: HTTP 200 with status "ok"
   ```

2. **OIDC discovery** — confirm the metadata document is served correctly:
   ```bash
   curl -s https://auth.cdssandbox.xyz/.well-known/openid-configuration | jq '{issuer,authorization_endpoint,token_endpoint}'
   # Expected: issuer matches the Staging domain
   ```

3. **End-to-end OIDC authentication flow** — using a browser or an OIDC test client:
   - Navigate to the Staging user portal login page.
   - Sign in as the pre-provisioned test user whose account exists in the restored data.
   - Complete the TOTP MFA challenge.
   - Confirm the session lands on the post-login landing page and the ID token is issued.
   - Optionally capture the token and inspect claims with `jwt decode <token>`.

Capture screenshots or `curl -i` outputs of each step as evidence.

### 4.6 Revert the ECS services and tear down the restored stores

Restore the ECS services to their original task definitions, then delete the temporary Aurora cluster and EFS file system.

Confirm via the AWS Console or `aws ecs describe-services` that both ECS services are `RUNNING` against the original task definitions and that the live Staging health check returns `200 OK`.

---

## 5. Test Record

Append a new row to the table below for each annual run. Link the row to any screenshots, console output, or ticket numbers stored in the team's evidence repository (Google Drive / Navigator).

| Test date | Executor | Snapshot ID | EFS recovery point | Restored cluster endpoint | Restored EFS ID | OIDC flow result | Outcome (Pass / Partial / Fail) | Deviations & follow-ups | Evidence link |
|-----------|----------|-------------|--------------------|-----------------------------|-----------------|-------------------------------------|---------------------------------|-------------------------|---------------|
| *YYYY-MM-DD* | *name* | *snap-id* | *rp-arn* | *endpoint* | *fs-id* | Pass / Fail | | | |

A `Partial` or `Fail` outcome must open a PoAM item within five business days describing the cause, blast-radius assessment, and remediation plan.
