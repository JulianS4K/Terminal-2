import { App } from "@modelcontextprotocol/ext-apps";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

interface League {
  league?: string;
  total_revenue?: number | null;
  tickets_sold?: number | null;
  weighted_median_price?: number | null;
}

const statusEl = document.getElementById("status")!;
const tbody = document.querySelector("#tbl tbody") as HTMLTableSectionElement;

const money = (n: number | null | undefined) =>
  n == null ? "—" : n.toLocaleString(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 });
const num = (n: number | null | undefined) => (n == null ? "—" : n.toLocaleString());

function parse(result: CallToolResult | undefined): { count: number; leagues: League[] } | null {
  const text = result?.content?.find((c) => c.type === "text")?.text;
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function render(data: { count: number; leagues: League[] } | null): void {
  if (!data || !Array.isArray(data.leagues)) {
    statusEl.textContent = "No data.";
    return;
  }
  statusEl.textContent = `${data.count} league${data.count === 1 ? "" : "s"}`;
  tbody.replaceChildren(
    ...data.leagues.map((r) => {
      const tr = document.createElement("tr");
      const cells = [r.league ?? "—", money(r.total_revenue), num(r.tickets_sold), money(r.weighted_median_price)];
      cells.forEach((v, i) => {
        const td = document.createElement("td");
        if (i > 0) td.className = "num";
        td.textContent = String(v);
        tr.appendChild(td);
      });
      return tr;
    }),
  );
}

const app = new App({ name: "d0-data", version: "0.1.0" });
app.ontoolresult = (params) => render(parse(params as CallToolResult));

document.getElementById("refresh")!.addEventListener("click", async () => {
  statusEl.textContent = "Refreshing…";
  const result = await app.callServerTool({ name: "d0-data", arguments: {} });
  render(parse(result));
});

await app.connect();
