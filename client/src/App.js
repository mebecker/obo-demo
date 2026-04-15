import React, { useState, useCallback } from "react";
import {
  useIsAuthenticated,
  useMsal,
  AuthenticatedTemplate,
  UnauthenticatedTemplate,
} from "@azure/msal-react";
import { loginRequest, apiScope } from "./authConfig";

const DEFAULT_DAX = `EVALUATE TOPN(10, 'Table')`;

export default function App() {
  const { instance, accounts } = useMsal();
  const isAuthenticated = useIsAuthenticated();
  const [daxQuery, setDaxQuery] = useState(DEFAULT_DAX);
  const [results, setResults] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  const handleLogin = () => instance.loginPopup(loginRequest);
  const handleLogout = () => instance.logoutPopup();

  const executeQuery = useCallback(async () => {
    setLoading(true);
    setError(null);
    setResults(null);

    try {
      // Silently acquire a token scoped to the backend API
      const tokenResponse = await instance.acquireTokenSilent({
        scopes: [apiScope],
        account: accounts[0],
      });

      // Call the backend, which will perform the OBO exchange
      const res = await fetch("http://localhost:5000/api/query", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${tokenResponse.accessToken}`,
        },
        body: JSON.stringify({ query: daxQuery }),
      });

      if (!res.ok) {
        const errData = await res.json();
        throw new Error(errData.error || `HTTP ${res.status}`);
      }

      const data = await res.json();
      setResults(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [instance, accounts, daxQuery]);

  return (
    <div style={styles.container}>
      <h1>Fabric Semantic Model — OBO Demo</h1>

      <UnauthenticatedTemplate>
        <p>Sign in to query your Fabric semantic model.</p>
        <button onClick={handleLogin} style={styles.button}>
          Sign in with Microsoft
        </button>
      </UnauthenticatedTemplate>

      <AuthenticatedTemplate>
        <p>
          Signed in as <strong>{accounts[0]?.username}</strong>{" "}
          <button onClick={handleLogout} style={styles.linkButton}>
            Sign out
          </button>
        </p>

        <label htmlFor="dax">DAX Query</label>
        <textarea
          id="dax"
          rows={5}
          value={daxQuery}
          onChange={(e) => setDaxQuery(e.target.value)}
          style={styles.textarea}
        />

        <button onClick={executeQuery} disabled={loading} style={styles.button}>
          {loading ? "Running…" : "Execute Query"}
        </button>

        {error && <pre style={styles.error}>{error}</pre>}

        {results && (
          <div style={styles.resultsContainer}>
            <h3>Results</h3>
            {results.results?.map((r, ri) => {
              const rows = r.tables?.[0]?.rows;
              if (!rows || rows.length === 0) {
                return <p key={ri}>No rows returned.</p>;
              }
              const columns = Object.keys(rows[0]);
              return (
                <table key={ri} style={styles.table}>
                  <thead>
                    <tr>
                      {columns.map((col) => (
                        <th key={col} style={styles.th}>{col}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((row, i) => (
                      <tr key={i}>
                        {columns.map((col) => (
                          <td key={col} style={styles.td}>
                            {row[col] != null ? String(row[col]) : "null"}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              );
            })}
          </div>
        )}
      </AuthenticatedTemplate>
    </div>
  );
}

const styles = {
  container: {
    maxWidth: 800,
    margin: "2rem auto",
    fontFamily: "system-ui, sans-serif",
    padding: "0 1rem",
  },
  button: {
    padding: "0.6rem 1.2rem",
    fontSize: "1rem",
    cursor: "pointer",
    background: "#0078d4",
    color: "#fff",
    border: "none",
    borderRadius: 4,
    marginTop: "0.5rem",
  },
  linkButton: {
    background: "none",
    border: "none",
    color: "#0078d4",
    cursor: "pointer",
    textDecoration: "underline",
    fontSize: "0.9rem",
  },
  textarea: {
    width: "100%",
    fontFamily: "monospace",
    fontSize: "0.95rem",
    padding: "0.5rem",
    boxSizing: "border-box",
    marginTop: "0.25rem",
  },
  error: {
    background: "#fdd",
    color: "#900",
    padding: "0.75rem",
    borderRadius: 4,
    marginTop: "1rem",
    whiteSpace: "pre-wrap",
  },
  resultsContainer: { marginTop: "1rem" },
  table: {
    width: "100%",
    borderCollapse: "collapse",
    marginTop: "0.5rem",
  },
  th: {
    textAlign: "left",
    borderBottom: "2px solid #ccc",
    padding: "0.4rem 0.6rem",
    background: "#f5f5f5",
  },
  td: {
    borderBottom: "1px solid #eee",
    padding: "0.4rem 0.6rem",
  },
};
