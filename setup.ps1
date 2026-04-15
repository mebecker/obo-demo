<#
.SYNOPSIS
  Create Entra ID app registrations for the OBO demo and write .env files.

.DESCRIPTION
  Creates two app registrations (backend API + SPA), configures scopes,
  permissions, known-client authorization, and writes both .env files.

.PARAMETER FabricWorkspaceId
  GUID of your Fabric workspace.

.PARAMETER FabricDatasetId
  GUID of your semantic model (dataset).

.EXAMPLE
  .\setup.ps1 -FabricWorkspaceId "aaaaaaaa-..." -FabricDatasetId "bbbbbbbb-..."
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$FabricWorkspaceId,

    [Parameter(Mandatory = $true)]
    [string]$FabricDatasetId
)

$ErrorActionPreference = "Stop"

# ── Verify prerequisites ─────────────────────────────────────────
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) is not installed."
}

# ── Resolve tenant ───────────────────────────────────────────────
Write-Host "Resolving tenant ID..."
$TenantId = az account show --query tenantId -o tsv
Write-Host "  Tenant ID: $TenantId"

# ── Power BI Service API ID (well-known) ─────────────────────────
$PowerBIApiId = "00000009-0000-0000-c000-000000000000"

Write-Host ""
Write-Host "Looking up Power BI Service service principal..."
$PowerBISpId = az ad sp show --id $PowerBIApiId --query id -o tsv 2>$null
if (-not $PowerBISpId) {
    Write-Host "  Power BI Service principal not found — creating it..."
    $PowerBISpId = az ad sp create --id $PowerBIApiId --query id -o tsv
}
Write-Host "  Power BI Service SP object ID: $PowerBISpId"

$DatasetReadAllId = az ad sp show --id $PowerBIApiId `
    --query "oauth2PermissionScopes[?value=='Dataset.Read.All'].id" -o tsv
Write-Host "  Dataset.Read.All permission ID: $DatasetReadAllId"

# ═══════════════════════════════════════════════════════════════════
# 1. Backend API app registration (confidential client)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Creating backend app registration (obo-demo-api)..."
$ApiAppJson = az ad app create `
    --display-name "obo-demo-api" `
    --sign-in-audience "AzureADMyOrg" `
    --query "{appId: appId, id: id}" -o json | ConvertFrom-Json

$ApiClientId = $ApiAppJson.appId
$ApiObjectId = $ApiAppJson.id
Write-Host "  App ID (client ID): $ApiClientId"

# Set the Application ID URI
Write-Host "  Setting Application ID URI..."
az ad app update --id $ApiObjectId --identifier-uris "api://$ApiClientId"

# Expose an API scope: access_as_user
Write-Host "  Adding scope: access_as_user..."
$ScopeId = [guid]::NewGuid().ToString()
$ScopeJson = @"
[{
    "id": "$ScopeId",
    "adminConsentDescription": "Allows the SPA to call the backend API on behalf of the signed-in user",
    "adminConsentDisplayName": "Access the OBO Demo API as the signed-in user",
    "isEnabled": true,
    "type": "User",
    "userConsentDescription": "Allow the app to access the OBO Demo API on your behalf",
    "userConsentDisplayName": "Access OBO Demo API",
    "value": "access_as_user"
}]
"@
az ad app update --id $ApiObjectId --set "api.oauth2PermissionScopes=$ScopeJson"

# Add Power BI delegated permission (Dataset.Read.All)
Write-Host "  Adding Power BI Dataset.Read.All delegated permission..."
az ad app permission add `
    --id $ApiClientId `
    --api $PowerBIApiId `
    --api-permissions "${DatasetReadAllId}=Scope"

# Create a client secret (1-year expiry)
Write-Host "  Creating client secret..."
$SecretJson = az ad app credential reset `
    --id $ApiClientId `
    --display-name "obo-demo-secret" `
    --years 1 `
    --query "{password: password}" -o json | ConvertFrom-Json
$ApiClientSecret = $SecretJson.password
Write-Host "  Client secret created."

# Create service principal for the backend app
Write-Host "  Creating service principal..."
az ad sp create --id $ApiClientId -o none

# Grant admin consent for the Power BI permission
Write-Host "  Granting admin consent for Power BI permissions..."
try {
    az ad app permission admin-consent --id $ApiClientId 2>$null
} catch {
    Write-Warning "Admin consent requires Global Admin or Privileged Role Admin. Grant it manually in the Azure Portal."
}

# ═══════════════════════════════════════════════════════════════════
# 2. Frontend SPA app registration (public client)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Creating SPA app registration (obo-demo-spa)..."
$SpaAppJson = az ad app create `
    --display-name "obo-demo-spa" `
    --sign-in-audience "AzureADMyOrg" `
    --query "{appId: appId, id: id}" -o json | ConvertFrom-Json

$SpaClientId = $SpaAppJson.appId
$SpaObjectId = $SpaAppJson.id
Write-Host "  App ID (client ID): $SpaClientId"

# Add SPA platform with redirect URI
Write-Host "  Configuring SPA platform with redirect URI..."
$SpaBody = @{ spa = @{ redirectUris = @("http://localhost:3000") } } | ConvertTo-Json -Compress
az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$SpaObjectId" `
    --headers "Content-Type=application/json" `
    --body $SpaBody

# Add API permission for the backend's access_as_user scope
Write-Host "  Adding permission for obo-demo-api/access_as_user..."
az ad app permission add `
    --id $SpaClientId `
    --api $ApiClientId `
    --api-permissions "${ScopeId}=Scope"

# Create service principal for the SPA
Write-Host "  Creating service principal..."
az ad sp create --id $SpaClientId -o none

# ═══════════════════════════════════════════════════════════════════
# 3. Add SPA as an authorized (known) client of the backend API
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Authorizing SPA as a known client of the backend API..."
$PreAuthBody = @{
    api = @{
        preAuthorizedApplications = @(
            @{
                appId = $SpaClientId
                delegatedPermissionIds = @($ScopeId)
            }
        )
    }
} | ConvertTo-Json -Depth 4 -Compress

az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$ApiObjectId" `
    --headers "Content-Type=application/json" `
    --body $PreAuthBody

# ═══════════════════════════════════════════════════════════════════
# 4. Write .env files
# ═══════════════════════════════════════════════════════════════════
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host ""
Write-Host "Writing .env files..."

@"
# ── Entra ID App Registration (Backend / Confidential Client) ──
TENANT_ID=$TenantId
SERVER_CLIENT_ID=$ApiClientId
SERVER_CLIENT_SECRET=$ApiClientSecret

# ── Fabric Semantic Model ──
FABRIC_WORKSPACE_ID=$FabricWorkspaceId
FABRIC_DATASET_ID=$FabricDatasetId

# ── Server ──
PORT=5000
"@ | Set-Content -Path (Join-Path $ScriptDir ".env") -Encoding UTF8

@"
# ── Frontend / SPA (read by Create React App) ──
REACT_APP_CLIENT_ID=$SpaClientId
REACT_APP_TENANT_ID=$TenantId
REACT_APP_API_SCOPE=api://$ApiClientId/access_as_user
"@ | Set-Content -Path (Join-Path $ScriptDir "client/.env") -Encoding UTF8

Write-Host "  ✔ .env (server)"
Write-Host "  ✔ client/.env (SPA)"

# ── Summary ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════"
Write-Host "  Setup complete!"
Write-Host "══════════════════════════════════════════════════════════"
Write-Host ""
Write-Host "  Backend API app:  $ApiClientId"
Write-Host "  SPA app:          $SpaClientId"
Write-Host "  Tenant:           $TenantId"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. npm install"
Write-Host "    2. cd server && npm run dev"
Write-Host "    3. cd client && npm start"
Write-Host ""
