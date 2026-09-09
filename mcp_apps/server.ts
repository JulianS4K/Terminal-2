/**
 * Terminal-2 MCP Apps service (read-only).
 *
 * Exposes three ext-apps tools, each bound to a `ui://` HTML app rendered in the
 * host (Claude / Claude Desktop):
 *   - d0-data        -> per-league sales (GET /api/mcp/d0/leagues)
 *   - d1-concierge   -> reuses the EXISTING retail chat (POST /api/store/retail-chat);
 *                       no second search path — one function (operator directive)
 *   - d4-events      -> published Exos/Bridge events (GET /api/mcp/d4/events).
 *                       Read-only: create-event / sell-ticket are DEFERRED and
 *                       have no tool here — the app renders them disabled.
 *
 * Data comes from the Python FastAPI app over HTTP; this service holds no DB
 * creds. The /api/mcp/* reads carry the shared secret (X-MCP-Read-Secret); the
 * retail-chat endpoint is the public storefront concierge (no secret).
 *
 * RULE 2 (CLAUDE.md): every outbound call is a GET read or the existing
 * retail-chat POST to our OWN host — no write path to any listing source.
 */
import http from "node:http";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  registerAppTool,
  registerAppResource,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const API_BASE = (process.env.API_BASE || "http://localhost:8000").replace(/\/$/, "");
const MCP_READ_SECRET = process.env.MCP_READ_SECRET || "";
const PORT = Number(process.env.PORT || 8787);

type Json = Record<string, unknown>;

/** GET a shared-secret-gated /api/mcp/* read endpoint. */
async function readApi(pathname: string): Promise<Json> {
  const res = await fetch(`${API_BASE}${pathname}`, {
    headers: MCP_READ_SECRET ? { "X-MCP-Read-Secret": MCP_READ_SECRET } : {},
  });
  if (!res.ok) {
    throw new Error(`read API ${pathname} -> HTTP ${res.status}`);
  }
  return (await res.json()) as Json;
}

/** A tool result carrying the JSON payload as a text block the app parses. */
function jsonResult(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data) }] };
}

function errorResult(err: unknown) {
  return {
    content: [
      { type: "text" as const, text: JSON.stringify({ error: String(err) }) },
    ],
    isError: true,
  };
}

function buildServer(): McpServer {
  const server = new McpServer({ name: "terminal-2-mcp-apps", version: "0.1.0" });

  // ---- resources: one bundled single-file HTML per lane ----
  // Read lazily so a not-yet-built app doesn't crash startup, and edits during
  // `vite build --watch` are picked up without a restart.
  const appHtml = (lane: string) =>
    readFileSync(path.join(HERE, "dist", lane, "mcp-app.html"), "utf-8");

  const RESOURCES: Array<{ lane: string; uri: string; title: string }> = [
    { lane: "d0", uri: "ui://d0-data/mcp-app.html", title: "D0 Sales" },
    { lane: "d1", uri: "ui://d1-concierge/mcp-app.html", title: "D1 Concierge" },
    { lane: "d4", uri: "ui://d4-events/mcp-app.html", title: "D4 Events" },
  ];
  for (const r of RESOURCES) {
    registerAppResource(
      server,
      r.title,
      r.uri,
      { mimeType: RESOURCE_MIME_TYPE },
      async () => ({
        contents: [{ uri: r.uri, mimeType: RESOURCE_MIME_TYPE, text: appHtml(r.lane) }],
      }),
    );
  }

  // ---- D0: sales by league (read-only) ----
  registerAppTool(
    server,
    "d0-data",
    {
      title: "D0 sales by league",
      description:
        "Show per-league sales totals and quantity-weighted median price (read-only).",
      _meta: { ui: { resourceUri: "ui://d0-data/mcp-app.html" } },
    },
    async () => {
      try {
        return jsonResult(await readApi("/api/mcp/d0/leagues"));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  // ---- D1: ticket concierge — reuses the existing retail chat ----
  registerAppTool(
    server,
    "d1-concierge",
    {
      title: "D1 ticket concierge",
      description:
        "Ask the retail concierge to find tickets. Reuses the storefront retail-chat assistant.",
      inputSchema: { message: z.string().min(1).max(2000) },
      _meta: { ui: { resourceUri: "ui://d1-concierge/mcp-app.html" } },
    },
    async ({ message }) => {
      try {
        const res = await fetch(`${API_BASE}/api/store/retail-chat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ message }),
        });
        const data = (await res.json()) as Json;
        return jsonResult(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  // ---- D4: published events (read-only; create/sell deferred) ----
  registerAppTool(
    server,
    "d4-events",
    {
      title: "D4 events",
      description:
        "List published Exos/Bridge events with starting price (read-only). Creating events and selling tickets are not available yet.",
      inputSchema: { limit: z.number().int().min(1).max(200).optional() },
      _meta: { ui: { resourceUri: "ui://d4-events/mcp-app.html" } },
    },
    async ({ limit }) => {
      try {
        const qs = limit ? `?limit=${limit}` : "";
        return jsonResult(await readApi(`/api/mcp/d4/events${qs}`));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  return server;
}

// Stateless Streamable HTTP: a fresh transport + server per request.
const httpServer = http.createServer((req, res) => {
  if (req.method !== "POST" || !req.url?.startsWith("/mcp")) {
    res.writeHead(404).end("not found");
    return;
  }
  const chunks: Buffer[] = [];
  req.on("data", (c) => chunks.push(c as Buffer));
  req.on("end", async () => {
    let body: unknown;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf-8") || "{}");
    } catch {
      res.writeHead(400).end("invalid JSON");
      return;
    }
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    res.on("close", () => transport.close());
    try {
      await buildServer().connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (err) {
      if (!res.headersSent) res.writeHead(500).end("internal error");
      // eslint-disable-next-line no-console
      console.error("mcp request failed:", err);
    }
  });
});

httpServer.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(
    `terminal-2 mcp-apps listening on http://localhost:${PORT}/mcp (API_BASE=${API_BASE})`,
  );
});
