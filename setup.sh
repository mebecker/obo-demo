#!/usr/bin/env bash
#
# setup.sh — Create Entra ID app registrations for the OBO demo and write .env files.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - jq installed
#
# Usage:
#   ./setup.sh <FABRIC_WORKSPACE_ID> <FABRIC_DATASET_ID>
#
set -euo pipefail

# ── Validate inputs ──────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <FABRIC_WORKSPACE_ID> <FABRIC_DATASET_ID>"
  echo ""
  echo "  FABRIC_WORKSPACE_ID  GUID of your Fabric workspace"
  echo "  FABRIC_DATASET_ID    GUID of your semantic model (dataset)"
  exit 1
fi

FABRIC_WORKSPACE_ID="$1"
FABRIC_DATASET_ID="$2"

# Verify prerequisites
command -v az  >/dev/null 2>&1 || { echo "Error: Azure CLI (az) is not installed."; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "Error: jq is not installed."; exit 1; }

# ── Resolve tenant ───────────────────────────────────────────────
echo "Resolving tenant ID..."
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "  Tenant ID: $TENANT_ID"

# ── Power BI Service API ID (well-known) ─────────────────────────
# This is the globally-fixed service principal ID for the Power BI Service API.
POWERBI_API_ID="00000009-0000-0000-c000-000000000000"

echo ""
echo "Looking up Power BI Service service principal..."
POWERBI_SP_ID=$(az ad sp show --id "$POWERBI_API_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$POWERBI_SP_ID" ]]; then
  echo "  Power BI Service principal not found — creating it..."
  POWERBI_SP_ID=$(az ad sp create --id "$POWERBI_API_ID" --query id -o tsv)
fi
echo "  Power BI Service SP object ID: $POWERBI_SP_ID"

# Find the Dataset.Read.All permission ID
DATASET_READ_ALL_ID=$(az ad sp show --id "$POWERBI_API_ID" \
  --query "oauth2PermissionScopes[?value=='Dataset.Read.All'].id" -o tsv)
echo "  Dataset.Read.All permission ID: $DATASET_READ_ALL_ID"

# ═══════════════════════════════════════════════════════════════════
# 1. Backend API app registration (confidential client)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Creating backend app registration (obo-demo-api)..."
API_APP=$(az ad app create \
  --display-name "obo-demo-api" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId: appId, id: id}" -o json)

API_CLIENT_ID=$(echo "$API_APP" | jq -r '.appId')
API_OBJECT_ID=$(echo "$API_APP" | jq -r '.id')
echo "  App ID (client ID): $API_CLIENT_ID"

# Set the Application ID URI
echo "  Setting Application ID URI..."
az ad app update --id "$API_OBJECT_ID" \
  --identifier-uris "api://$API_CLIENT_ID"

# Expose an API scope: access_as_user
echo "  Adding scope: access_as_user..."
SCOPE_ID=$(cat /proc/sys/kernel/random/uuid)
az ad app update --id "$API_OBJECT_ID" \
  --set "api.oauth2PermissionScopes=[{
    \"id\": \"$SCOPE_ID\",
    \"adminConsentDescription\": \"Allows the SPA to call the backend API on behalf of the signed-in user\",
    \"adminConsentDisplayName\": \"Access the OBO Demo API as the signed-in user\",
    \"isEnabled\": true,
    \"type\": \"User\",
    \"userConsentDescription\": \"Allow the app to access the OBO Demo API on your behalf\",
    \"userConsentDisplayName\": \"Access OBO Demo API\",
    \"value\": \"access_as_user\"
  }]"

# Add Power BI delegated permission (Dataset.Read.All)
echo "  Adding Power BI Dataset.Read.All delegated permission..."
az ad app permission add \
  --id "$API_CLIENT_ID" \
  --api "$POWERBI_API_ID" \
  --api-permissions "$DATASET_READ_ALL_ID=Scope"

# Create a client secret (1-year expiry)
echo "  Creating client secret..."
SECRET_JSON=$(az ad app credential reset \
  --id "$API_CLIENT_ID" \
  --display-name "obo-demo-secret" \
  --years 1 \
  --query "{password: password}" -o json)
API_CLIENT_SECRET=$(echo "$SECRET_JSON" | jq -r '.password')
echo "  Client secret created."

# Create service principal for the backend app
echo "  Creating service principal..."
az ad sp create --id "$API_CLIENT_ID" -o none

# Grant admin consent for the Power BI permission
echo "  Granting admin consent for Power BI permissions..."
az ad app permission admin-consent --id "$API_CLIENT_ID" 2>/dev/null || \
  echo "  ⚠ Admin consent requires Global Admin or Privileged Role Admin. Grant it manually in the Azure Portal."

# ═══════════════════════════════════════════════════════════════════
# 2. Frontend SPA app registration (public client)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Creating SPA app registration (obo-demo-spa)..."
SPA_APP=$(az ad app create \
  --display-name "obo-demo-spa" \
  --sign-in-audience "AzureADMyOrg" \
  --web-redirect-uris "" \
  --query "{appId: appId, id: id}" -o json)

SPA_CLIENT_ID=$(echo "$SPA_APP" | jq -r '.appId')
SPA_OBJECT_ID=$(echo "$SPA_APP" | jq -r '.id')
echo "  App ID (client ID): $SPA_CLIENT_ID"

# Add SPA platform with redirect URI
echo "  Configuring SPA platform with redirect URI..."
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$SPA_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"spa\": {\"redirectUris\": [\"http://localhost:3000\"]}}"

# Add API permission for the backend's access_as_user scope
echo "  Adding permission for obo-demo-api/access_as_user..."
az ad app permission add \
  --id "$SPA_CLIENT_ID" \
  --api "$API_CLIENT_ID" \
  --api-permissions "$SCOPE_ID=Scope"

# Create service principal for the SPA
echo "  Creating service principal..."
az ad sp create --id "$SPA_CLIENT_ID" -o none

# ═══════════════════════════════════════════════════════════════════
# 3. Add SPA as an authorized (known) client of the backend API
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "Authorizing SPA as a known client of the backend API..."
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$API_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"api\": {
      \"preAuthorizedApplications\": [{
        \"appId\": \"$SPA_CLIENT_ID\",
        \"delegatedPermissionIds\": [\"$SCOPE_ID\"]
      }]
    }
  }"

# ═══════════════════════════════════════════════════════════════════
# 4. Write .env files
# ═══════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "Writing .env files..."

cat > "$SCRIPT_DIR/.env" <<EOF
# ── Entra ID App Registration (Backend / Confidential Client) ──
TENANT_ID=$TENANT_ID
SERVER_CLIENT_ID=$API_CLIENT_ID
SERVER_CLIENT_SECRET=$API_CLIENT_SECRET

# ── Fabric Semantic Model ──
FABRIC_WORKSPACE_ID=$FABRIC_WORKSPACE_ID
FABRIC_DATASET_ID=$FABRIC_DATASET_ID

# ── Server ──
PORT=5000
EOF

cat > "$SCRIPT_DIR/client/.env" <<EOF
# ── Frontend / SPA (read by Create React App) ──
REACT_APP_CLIENT_ID=$SPA_CLIENT_ID
REACT_APP_TENANT_ID=$TENANT_ID
REACT_APP_API_SCOPE=api://$API_CLIENT_ID/access_as_user
EOF

echo "  ✔ .env (server)"
echo "  ✔ client/.env (SPA)"

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Setup complete!"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Backend API app:  $API_CLIENT_ID"
echo "  SPA app:          $SPA_CLIENT_ID"
echo "  Tenant:           $TENANT_ID"
echo ""
echo "  Next steps:"
echo "    1. npm install"
echo "    2. cd server && npm run dev"
echo "    3. cd client && npm start"
echo ""
