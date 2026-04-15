import React from "react";
import ReactDOM from "react-dom/client";
import { MsalProvider } from "@azure/msal-react";
import { msalInstance } from "./authConfig";
import App from "./App";

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(
  <React.StrictMode>
    <MsalProvider instance={msalInstance}>
      <App />
    </MsalProvider>
  </React.StrictMode>
);
