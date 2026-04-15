require("dotenv").config({ path: "../.env" });
const express = require("express");
const cors = require("cors");
const jwt = require("jsonwebtoken");
const jwksRsa = require("jwks-rsa");
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

// ── JWKS client for fetching Microsoft signing keys ─────────────
const jwksClient = jwksRsa({
  jwksUri: `https://login.microsoftonline.com/${process.env.TENANT_ID}/discovery/v2.0/keys`,
  cache: true,
  cacheMaxAge: 600000, // 10 minutes
  rateLimit: true,
});

function getSigningKey(header, callback) {
  jwksClient.getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    callback(null, key.getPublicKey());
  });
}

// ── Middleware: validate incoming bearer token ──────────────────
function validateToken(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid Authorization header" });
  }
  const token = authHeader.split(" ")[1];

  const verifyOptions = {
    audience: `api://${process.env.SERVER_CLIENT_ID}`,
    issuer: [
      `https://login.microsoftonline.com/${process.env.TENANT_ID}/v2.0`,
      `https://sts.windows.net/${process.env.TENANT_ID}/`,
    ],
    algorithms: ["RS256"],
  };

  jwt.verify(token, getSigningKey, verifyOptions, (err, decoded) => {
    if (err) {
      console.error("JWT validation failed:", err.message);
      return res.status(401).json({ error: "Invalid token" });
    }
    req.userToken = token;
    req.tokenClaims = decoded;
    next();
  });
}

// ── POST /api/query — execute a DAX query via Fabric REST API ──
app.post("/api/query", validateToken, async (req, res) => {
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
