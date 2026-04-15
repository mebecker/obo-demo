import { PublicClientApplication } from "@azure/msal-browser";

const msalConfig = {
  auth: {
    clientId: process.env.REACT_APP_CLIENT_ID,
    authority: `https://login.microsoftonline.com/${process.env.REACT_APP_TENANT_ID}`,
    redirectUri: "http://localhost:3000",
  },
  cache: {
    cacheLocation: "sessionStorage",
    storeAuthStateInCookie: false,
  },
};

export const msalInstance = new PublicClientApplication(msalConfig);

// The scope exposed by the backend API app registration
export const apiScope = process.env.REACT_APP_API_SCOPE || "";

if (!apiScope) {
  console.warn(
    "REACT_APP_API_SCOPE is not set. " +
      "Create a client/.env file with REACT_APP_CLIENT_ID, REACT_APP_TENANT_ID, and REACT_APP_API_SCOPE."
  );
}

export const loginRequest = {
  scopes: apiScope ? [apiScope] : [],
};
