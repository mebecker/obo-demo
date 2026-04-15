require("dotenv").config({ path: "../.env" });
const express = require("express");
const cors = require("cors");
const { ConfidentialClientApplication } = require("@azure/msal-node");

const app = express();
app.use(cors({ origin: "http://localhost:3000" }));
app.use(express.json());

// ── MSAL Confidential Client (backend) ──────────────────────────
const msalConfig = {
  auth: {
    clientId: process.env.SERVER_CLIENT_ID,
    authority: `https://login.microsoftonline.com/${process.env.TENANT_ID}`,
    clientSecret: process.env.SERVER_CLIENT_SECRET,
  },
};
const cca = new ConfidentialClientApplication(msalConfig);

// ── Middleware: validate incoming bearer token ──────────────────
function extractToken(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid Authorization header" });
  }
  req.userToken = authHeader.split(" ")[1];
  next();
}

// ── POST /api/query — execute a DAX query via Fabric REST API ──
app.post("/api/query", extractToken, async (req, res) => {
  const { query } = req.body;
  if (!query) {
    return res.status(400).json({ error: "A DAX query is required in the request body" });
  }

  try {
    // 1. On-Behalf-Of: exchange the user's SPA token for a Fabric token
    const oboRequest = {
      oboAssertion: req.userToken,
      scopes: ["https://analysis.windows.net/powerbi/api/Dataset.Read.All"],
    };
    const oboResponse = await cca.acquireTokenOnBehalfOf(oboRequest);

    // Debug: log token audience & scopes (remove in production)
    const [, payload] = oboResponse.accessToken.split(".");
    const claims = JSON.parse(Buffer.from(payload, "base64").toString());
    console.log("OBO token aud:", claims.aud);
    console.log("OBO token scp:", claims.scp);
    console.log("OBO token appid:", claims.appid);

    // 2. Call the Fabric / Power BI REST API to execute the DAX query
    const workspaceId = process.env.FABRIC_WORKSPACE_ID;
    const datasetId = process.env.FABRIC_DATASET_ID;
    console.log("Calling Fabric API — workspace:", workspaceId, "dataset:", datasetId);
    const url = `https://api.powerbi.com/v1.0/myorg/groups/${workspaceId}/datasets/${datasetId}/executeQueries`;

    const fabricRes = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${oboResponse.accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        queries: [{ query }],
        serializerSettings: { includeNulls: true },
      }),
    });

    if (!fabricRes.ok) {
      const errBody = await fabricRes.text();
      return res.status(fabricRes.status).json({ error: errBody });
    }

    const data = await fabricRes.json();
    res.json(data);
  } catch (err) {
    console.error("OBO / Fabric error:", err);
    res.status(500).json({ error: err.message });
  }
});

// ── Health check ────────────────────────────────────────────────
app.get("/api/health", (_req, res) => res.json({ status: "ok" }));

const PORT = process.env.PORT || 5000;
app.listen(PORT, () => console.log(`Server listening on http://localhost:${PORT}`));
