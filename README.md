# Fabric Semantic Model – OAuth On-Behalf-Of (OBO) Demo

A React + Express demo that authenticates a user via MSAL, performs the **OAuth 2.0 On-Behalf-Of (OBO)** flow on the backend, and queries a **Microsoft Fabric semantic model** using the Power BI REST API.

---

## Why the OBO Flow?

A React SPA (single-page application) runs entirely in the browser — it's a **public client** and cannot securely store secrets. It can authenticate the user, but it shouldn't directly call APIs that require elevated or downstream permissions on behalf of that user.

The OBO flow solves this by introducing a **backend API** (a **confidential client** that _can_ hold a secret). The SPA obtains a token scoped only to the backend API, and the backend exchanges that token for a new one scoped to the downstream resource (Fabric / Power BI) — acting _on behalf of_ the signed-in user.

**Key benefits:**

- The SPA never sees a Fabric token — it only holds a token for your own API.
- The backend can apply server-side validation, rate-limiting, or logging before forwarding requests.
- The downstream call still carries the user's identity, so Fabric enforces row-level security and per-user permissions.

---

## Why Two App Registrations?

Each app registration represents a distinct security boundary in Entra ID:

| | SPA (public client) | Backend API (confidential client) |
|---|---|---|
| **Runs in** | Browser | Server |
| **Can hold secrets?** | No | Yes (client secret or certificate) |
| **Token audience** | `api://<backend-client-id>` | `https://analysis.windows.net/powerbi/api` |
| **Permissions** | Delegated: `access_as_user` (your custom scope) | Delegated: `Dataset.Read.All` (Power BI) |
| **Role in OBO** | Obtains the _initial_ user token | Exchanges it for a _downstream_ Fabric token |

If you used a single registration, the SPA would need direct access to Power BI scopes, and there would be no confidential client to perform the OBO exchange. The two-registration model follows the **least-privilege** principle: each app only requests the permissions it actually needs.

---

## Architecture

```
┌─────────────┐                         ┌──────────────┐
│  React SPA  │  1. Auth Code + PKCE    │   Entra ID   │
│  (browser)  │ ───────────────────────►│              │
│             │◄─────────────────────── │              │
│             │  2. Access token        │              │
│             │     aud: api://<backend>│              │
│             │     scp: access_as_user │              │
│             │                         └──────┬───────┘
│             │                                │
│             │  3. POST /api/query             │
│             │     Authorization: Bearer <A>   │
│             │ ──────────────────────►         │
│             │                        ┌───────┴────────┐
│             │                        │  Express API   │
│             │                        │  (Node.js)     │
│             │                        │                │
│             │                        │ 4. OBO request │
│             │                        │    assertion=A │
│             │                        │    scope=      │
│             │                        │    Dataset.    │
│             │                        │    Read.All    │
│             │                        │       │        │
│             │                        │ 5. Receives    │
│             │                        │    token <B>   │
│             │                        │    aud: Power  │
│             │                        │    BI API      │
│             │                        │       │        │
│             │                        │ 6. POST        │
│             │                        │  executeQueries│
│             │                        │  Bearer <B>    │
│             │◄───────────────────────│                │
│             │  7. DAX query results  │                │
└─────────────┘                        └────────────────┘
```

### Step-by-step

1. The user clicks **Sign in**. MSAL in the SPA starts an **Authorization Code + PKCE** flow with Entra ID.
2. Entra ID returns an access token to the SPA. This token's **audience** is the backend API (`api://<backend-client-id>`) and its **scope** is `access_as_user`. The SPA _cannot_ use this token to call Fabric directly.
3. The SPA sends a DAX query to the Express backend, attaching the token as a `Bearer` header.
4. The Express backend calls `acquireTokenOnBehalfOf()` (MSAL Node), passing the user's token as the `oboAssertion` and requesting the scope `https://analysis.windows.net/powerbi/api/Dataset.Read.All`.
5. Entra ID validates the assertion, verifies the backend's client secret, and issues a **new** access token — this time with audience `https://analysis.windows.net/powerbi/api` and the user's identity embedded.
6. The backend calls the Fabric **executeQueries** REST endpoint with the new token.
7. Results flow back through the backend to the SPA, which renders them in a table.

---

## Prerequisites

- **Node.js 18+**
- A **Microsoft Fabric workspace** on a Premium, PPU, or Fabric (F-SKU) capacity  
  _(the `executeQueries` API is not available on Pro-only workspaces)_
- A published **semantic model** in that workspace
- The signed-in user must have at least **Build** permission on the semantic model
- **Two Entra ID app registrations** (setup below)

---

## Entra ID Setup

### Option A: Automated Setup (recommended)

The setup scripts create both app registrations, configure scopes, permissions, and known-client authorization, then write the `.env` files automatically.

**Prerequisites:**

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and logged in (`az login`)
- `jq` installed (bash script only — not needed for PowerShell)
- Sufficient Entra ID permissions (Application Developer + Privileged Role Admin for admin consent)

You'll need your **Fabric workspace ID** and **semantic model (dataset) ID** — both are GUIDs found in the Fabric portal URL.

**Bash (Linux / macOS / WSL):**

```bash
./setup.sh <FABRIC_WORKSPACE_ID> <FABRIC_DATASET_ID>
```

**PowerShell (Windows / cross-platform):**

```powershell
.\setup.ps1 -FabricWorkspaceId "<FABRIC_WORKSPACE_ID>" -FabricDatasetId "<FABRIC_DATASET_ID>"
```

The script will:

1. Create the **backend API** app registration (`obo-demo-api`) with:
   - An `access_as_user` scope exposed under `api://<client-id>`
   - A 1-year client secret
   - Power BI `Dataset.Read.All` delegated permission (with admin consent)
2. Create the **SPA** app registration (`obo-demo-spa`) with:
   - A SPA platform redirect URI (`http://localhost:3000`)
   - Permission to call `obo-demo-api/access_as_user`
3. Add the SPA as a **known (pre-authorized) client** of the backend API
4. Write `/.env` and `/client/.env` with all the correct values

> **Note:** If admin consent fails (requires Global Admin or Privileged Role Admin), the script will warn you. Grant consent manually in **Azure Portal → App registrations → obo-demo-api → API permissions → Grant admin consent**.

After the script completes, skip ahead to [Running](#running).

---

### Option B: Manual Setup

If you prefer to create the app registrations manually in the Azure Portal, follow the steps below.

#### 1. Backend API app registration (confidential client)

Create a new app registration in **Azure Portal → Entra ID → App registrations → New registration**:

| Setting | Value |
|---------|-------|
| Name | `obo-demo-api` |
| Supported account types | Accounts in this organizational directory only (Single tenant) |
| Redirect URI | _(leave blank — the backend doesn't receive redirects)_ |

After creation, configure three things:

#### a) Expose an API scope

1. Go to **Expose an API**.
2. Click **Set** next to Application ID URI — accept the default `api://<client-id>` or customize it.
3. Click **Add a scope**:
   - Scope name: `access_as_user`
   - Who can consent: **Admins and users**
   - Admin consent display name: _Access the OBO Demo API as the signed-in user_
   - Admin consent description: _Allows the SPA to call the backend API on behalf of the signed-in user_
4. Save.

#### b) Create a client secret

1. Go to **Certificates & secrets → Client secrets → New client secret**.
2. Add a description, pick an expiry, and click **Add**.
3. **Copy the secret value immediately** — it is only shown once.

#### c) Add Power BI delegated permission

1. Go to **API permissions → Add a permission**.
2. Select **APIs my organization uses** → search for **Power BI Service**.
3. Choose **Delegated permissions** → check **Dataset.Read.All**.
4. Click **Add permissions**.
5. Click **Grant admin consent for \<your tenant\>** (requires Global Admin or Privileged Role Admin).

> **Why `Dataset.Read.All` and not `.default`?**  
> The OBO flow requires _specific delegated scopes_, not the `.default` shorthand. Using `.default` in an OBO request causes Entra ID to issue a token with application-level permissions, which Fabric's `executeQueries` endpoint rejects because it needs a delegated (user-context) token to open the MSOLAP connection.

#### 2. Frontend SPA app registration (public client)

Create another app registration:

| Setting | Value |
|---------|-------|
| Name | `obo-demo-spa` |
| Supported account types | Accounts in this organizational directory only (Single tenant) |
| Platform | **Single-page application** |
| Redirect URI | `http://localhost:3000` |

After creation:

1. Go to **API permissions → Add a permission → My APIs**.
2. Select **obo-demo-api** → Delegated → check **access_as_user**.
3. Click **Add permissions**.

> **Note:** No client secret is created for the SPA — it is a public client and uses PKCE for security instead.

#### 3. Authorize the SPA as a known client

This step enables the SPA to request the backend's scope _without a separate admin-consent prompt_:

1. Go back to the **backend** app registration → **Expose an API**.
2. Under **Authorized client applications**, click **Add a client application**.
3. Enter the **SPA's client ID**.
4. Check the `access_as_user` scope.
5. Save.

---

## Configuration

There are two `.env` files — one for the server, one for the client. They are separated because Create React App can only read `REACT_APP_*` variables from a `.env` inside its own directory.

### Server (`/.env` — repo root)

```bash
cp .env.example .env
```

| Variable | Description | Where to find it |
|----------|-------------|-----------------|
| `TENANT_ID` | Your Entra ID tenant | Azure Portal → Entra ID → Overview → Tenant ID |
| `SERVER_CLIENT_ID` | Backend app's Application ID | Backend app registration → Overview |
| `SERVER_CLIENT_SECRET` | Backend app's secret value | Backend app registration → Certificates & secrets |
| `FABRIC_WORKSPACE_ID` | Fabric workspace GUID | Fabric portal URL: `/groups/<this-guid>/...` |
| `FABRIC_DATASET_ID` | Semantic model GUID | Fabric portal URL: `/datasets/<this-guid>` |
| `PORT` | Express server port (default 5000) | — |

### Client (`/client/.env`)

```bash
cp client/.env.example client/.env
```

| Variable | Description |
|----------|-------------|
| `REACT_APP_CLIENT_ID` | SPA app's Application (client) ID |
| `REACT_APP_TENANT_ID` | Same Tenant ID as above |
| `REACT_APP_API_SCOPE` | `api://<SERVER_CLIENT_ID>/access_as_user` |

---

## Running

```bash
# Install all dependencies (from repo root)
npm install

# Terminal 1 — start the backend (port 5000)
cd server && npm run dev

# Terminal 2 — start the React dev server (port 3000)
cd client && npm start
```

Open `http://localhost:3000`, click **Sign in with Microsoft**, enter a DAX query, and click **Execute Query**.

### Debugging

A VS Code launch configuration is included (`.vscode/launch.json`):

- **Server: Node** — launches the Express server with the debugger attached.
- **Client: Chrome** — attaches to Chrome for SPA breakpoints (start `npm start` first).
- **Full Stack** — launches both simultaneously.

Open the **Run and Debug** panel (`Ctrl+Shift+D`) and select a configuration.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Cannot read properties of undefined (reading 'trim')` | `REACT_APP_API_SCOPE` is not set | Create `client/.env` with all `REACT_APP_*` vars; restart the React dev server |
| `Failed to open the MSOLAP connection` | Token is app-only (used `.default` scope) or user lacks permission | Use the specific delegated scope `Dataset.Read.All`; grant the user **Build** permission on the semantic model |
| `DatasetExecuteQueriesError` | Workspace is not on Premium/Fabric capacity | Move the semantic model to a PPU, P, EM, or F-SKU workspace |
| `AADSTS65001: consent required` | Admin consent not granted for Power BI permission | In the backend app → API permissions → **Grant admin consent** |
| `AADSTS700024: client assertion not valid` | Client secret expired or wrong | Rotate the secret in the backend app registration and update `.env` |

---

## Example DAX Query

```dax
EVALUATE
TOPN(
  10,
  SUMMARIZECOLUMNS(
    'Sales'[ProductName],
    "Total Revenue", SUM('Sales'[Revenue])
  ),
  [Total Revenue], DESC
)
```

---

## Security Notes

- **Never commit `.env` files** — they contain secrets. The `.gitignore` excludes them.
- **Use certificates instead of client secrets** in production for stronger security.
- **Validate tokens** on the backend — the server validates the JWT signature, issuer, audience, and expiry using `jsonwebtoken` with Microsoft's JWKS endpoint.
- **Use HTTPS** in any non-localhost deployment.

---

## Further Reading

- [OAuth 2.0 On-Behalf-Of flow — Microsoft identity platform](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [Execute Queries REST API — Power BI / Fabric](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries)
- [MSAL Node — acquireTokenOnBehalfOf](https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-node/docs/on-behalf-of.md)
- [MSAL React — Getting Started](https://github.com/AzureAD/microsoft-authentication-library-for-js/tree/dev/lib/msal-react)
