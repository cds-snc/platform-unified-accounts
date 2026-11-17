# Annual Backup Test & Contingency Plan Runbook

- **System:** Platform Unified Accounts — SSO/IdP. 
- **Cadence:** Annual (minimum). 
- **Controls satisfied:** CP-9(1), CP-9(2), supports CP-10. 

---

## 1. Purpose

This runbook describes the annual procedure to:

1. Verify the **reliability and integrity** of the automated backups taken of the Platform Unified Accounts SSO/IdP system (CP-9(1)).
2. Exercise the **contingency restoration** of system functions from a sample of backup data (CP-9(2)).
3. Capture **evidence** (date, executor, outcome, deviations) that can be linked from the Plan of Action and Milestones (PoAM) and provided to assessors.

The system stores all persistent state in Aurora PostgreSQL:

| Data store | What it holds | Backup mechanism | Retention |
|------------|--------------|------------------|-----------|
| Aurora PostgreSQL | Zitadel relational state: users, orgs, projects, OIDC apps, sessions, MFA factors, audit log table | RDS automated backups (continuous + daily snapshot) configured in [platform-unified-accounts/terraform/aws/database.tf](platform-unified-accounts/terraform/aws/database.tf#L25-L26) | 14 days |

A successful test must restore the **database** within the Staging account alongside the live infrastructure and show the Zitadel IdP comes up and serves an authentication flow against the restored data.

---

## 2. Scope & Sampling

A full DR cutover is **not** required. The test uses a sample-based approach (CP-9(2)):

- **Database:** the most recent successful automated snapshot of staging data.
- **Functional:** the health check endpoint plus a single end-to-end OIDC authorization-code login using a test user.

The test is performed entirely within the **Staging AWS account**: a new Aurora cluster is restored from backup alongside the live resources, the IdP ECS service is temporarily switched to the restored database, the application is validated, and the restored cluster is then deleted.

> **Important:** this procedure temporarily redirects the Staging IdP ECS service to the restored database. Co-ordinate with the team to ensure the Staging environment is not being actively used for integration testing during the maintenance window.

---

## 3. Prerequisites

Before starting, confirm:

- [ ] You have `AdministratorAccess` (or equivalent) to the Staging AWS account.
- [ ] A maintenance window has been agreed with the team for the Staging environment.

---

## 4. Procedure

### 4.1 Identify the source backup

```bash
# Aurora — latest automated snapshot for the staging cluster
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier idp-staging \
  --snapshot-type automated \
  --query 'reverse(sort_by(DBClusterSnapshots,&SnapshotCreateTime))[0].[DBClusterSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output table
```

Record the snapshot identifier in the test record (§5).

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

### 4.3 Update the IdP ECS service to use the restored database

1. Create a new `idp` task definition that uses the restored RDS cluster endpoint.
2. Update the `idp` service to use the new task definition.
3. Wait for the service deployment to complete.

### 4.4 Validate application function

With the IdP ECS service now running against the restored database, perform the following checks against the Staging ALB:

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

### 4.5 Revert the IdP ECS service and tear down the restored cluster

Restore the IdP ECS service to its original task definition, then delete the temporary Aurora cluster.

Confirm via the AWS Console or `aws ecs describe-services` that the IdP ECS service is `RUNNING` against its original task definition and that the live Staging health check returns `200 OK`.

---

## 5. Test Record

Append a new row to the table below for each annual run. Link the row to any screenshots, console output, or ticket numbers stored in the team's evidence repository (Google Drive / Navigator).

| Test date | Executor | Snapshot ID | Restored cluster endpoint | OIDC flow result | Outcome (Pass / Partial / Fail) | Deviations & follow-ups | Evidence link |
|-----------|----------|-------------|---------------------------|------------------|--------------------------------|-------------------------|---------------|
| *YYYY-MM-DD* | *name* | *snap-id* | *endpoint* | Pass / Fail | | | |

A `Partial` or `Fail` outcome must open a PoAM item within five business days describing the cause, blast-radius assessment, and remediation plan.
