# IAM Login Client Recovery Runbook

- **System:** Platform Unified Accounts — SSO/IdP.
- **Trigger:** Emergency break-glass — existing User Portal `IAM_LOGIN_CLIENT` PAT is lost, expired, or the machine user must be recreated.
- **Controls satisfied:** CP-10(4), SC-12(1)

---

## 1. Purpose

This runbook describes how to:

1. Authenticate to Zitadel using the break-glass `SystemAPIUsers` mechanism, which is available when the user portal's PAT is unavailable.
2. Provision a new machine user with the `IAM_LOGIN_CLIENT` role.
3. Generate a Personal Access Token (PAT) and update the user portal's ECS task with the new value.

The break-glass mechanism relies on an RSA keypair whose public half is declared in the Zitadel runtime `config.yaml`:

| Component | What it is | Location |
|-----------|------------|----------|
| Break-glass public key | Registered in Zitadel config under `SystemAPIUsers` | Secrets Manager / CDS Password Manager |
| Break-glass private key | Used to sign the JWT assertion that mints a bearer token | CDS Password Manager |
| `IAM_LOGIN_CLIENT` PAT | Long-lived token read by the User Portal at startup | Secrets Manager / CDS Password Manager |

A successful recovery ends with the user portal ECS task restarting and serving authenticated requests.

---

## 2. Scope

This procedure targets the live Zitadel instance. It does not require a full DR failover.

Steps 4.2–4.6 can be run from any system with network access to Zitadel. The break-glass private key must be retrieved from the CDS Password Manager before starting.

---

## 3. Prerequisites

Before starting, confirm:

- [ ] The `SystemAPIUsers` block in the Zitadel `config.yaml` is already populated with the break-glass public key (see §4.1 for the required format).
- [ ] You have retrieved the corresponding break-glass private key PEM.
- [ ] [`zitadel-tools`](https://github.com/zitadel/zitadel-tools) is installed locally (`zitadel-tools --version`).
- [ ] `jq` is installed locally (`jq --version`).

---

## 4. Procedure

### 4.1 Verify the `SystemAPIUsers` configuration

Add the following block to the Zitadel runtime `config.yaml` and then create and merge a PR to trigger an IdP ECS task redeploy. 

> **Important** The [IdP ECS Task's container command must be `start-from-setup`](https://github.com/cds-snc/platform-unified-accounts/blob/15683153392acb3217e8f7c09b380e79639469a8/terraform/aws/ecs.tf#L148) to create the new user.

```yaml
SystemAPIUsers:
  # The identifier key must match the 'iss' and 'sub' claims of your generated JWT
  breakglass-system-admin:
    # Option A: Mount a file path containing the public key
    Path: "/etc/zitadel/keys/breakglass-admin.pub"

    # Option B: Alternatively, embed key directly (Base64-encoded or raw PEM string)
    # KeyData: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A..."

    Memberships:
      # System-level membership grants cross-instance administrative operations
      - MemberType: System
        Roles:
          - "SYSTEM_OWNER"
          - "IAM_OWNER"
          - "ORG_OWNER"
```

### 4.2 Mint a System API access token

Use `zitadel-tools` to sign a JWT assertion with the break-glass private key.

```bash
# Set the Zitadel host for the target environment
export Zitadel_HOST="https://auth.cdssandbox.xyz"

# Mint a client assertion bearer token using the break-glass private key
export BEARER_TOKEN=$(zitadel-tools key2jwt \
  --audience="${Zitadel_HOST}" \
  --key="/path/to/breakglass-admin.pem" \
  --issuer="breakglass-system-admin")

echo "Bearer token obtained (first 20 chars): ${BEARER_TOKEN:0:20}..."
```

Confirm a non-empty token is printed before continuing.

### 4.3 Retrieve the default organization ID

The machine user must be created within an organization. Retrieve the default org for the instance:

```bash
export ORG_ID=$(curl -s --request GET \
  --url "${Zitadel_HOST}/management/v1/orgs/me" \
  --header "Authorization: Bearer ${BEARER_TOKEN}" \
  | jq -r '.org.id')

echo "Target Org ID: ${ORG_ID}"
```

Confirm a numeric ID is printed before continuing.

### 4.4 Create the machine user

Create a new machine user via the Zitadel Users API:

```bash
export USER_ID=$(curl -s --request POST \
  --url "${Zitadel_HOST}/v2/users/machine" \
  --header "Authorization: Bearer ${BEARER_TOKEN}" \
  --header "Content-Type: application/json" \
  --header "x-zitadel-orgid: ${ORG_ID}" \
  --data '{
    "username": "emergency-login-client",
    "name": "Emergency Login Client Service Account",
    "accessTokenType": "ACCESS_TOKEN_TYPE_BEARER"
  }' | jq -r '.userId')

echo "Created Machine User ID: ${USER_ID}"
```

### 4.5 Assign the `IAM_LOGIN_CLIENT` role

Assign the required role to the new service account:

```bash
curl -s --request POST \
  --url "${Zitadel_HOST}/admin/v1/members" \
  --header "Authorization: Bearer ${BEARER_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{
    "userId": "'"${USER_ID}"'",
    "roles": ["IAM_LOGIN_CLIENT"]
  }'
```

### 4.6 Generate a Personal Access Token (PAT)

Generate a long-lived PAT for the machine user:

```bash
export NEW_PAT=$(curl -s --request POST \
  --url "${Zitadel_HOST}/management/v1/users/${USER_ID}/pats" \
  --header "Authorization: Bearer ${BEARER_TOKEN}" \
  --header "Content-Type: application/json" \
  --header "x-zitadel-orgid: ${ORG_ID}" \
  --data '{
    "expirationDate": "2030-01-01T00:00:00Z"
  }' | jq -r '.token')

echo "PAT created (first 20 chars): ${NEW_PAT:0:20}..."
```

> **Important:** Copy `NEW_PAT` to the CDS Password Manager.

### 4.7 Restore the PAT and validate the User Portal

1. Update the GitHub `<ENV>_IDP_LOGINCLIENT_PAT` secret. 
2. This new value will be deployed and update the user portal ECS task on next `terraform apply` operation.
