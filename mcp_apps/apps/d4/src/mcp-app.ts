import { App } from "@modelcontextprotocol/ext-apps";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

interface EventRow {
  id?: string;
  name?: string;
  starts_at?: string | null;
  venue_name?: string | null;
  venue_location?: string | null;
  image_url?: string | null;
  from_price?: number | null;
}

const statusEl = document.getElementById("status")!;
const list = document.getElementById("list") as HTMLUListElement;

const price = (n: number | null | undefined) =>
  n == null ? "" : `from ${n.toLocaleString(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 })}`;

function when(iso: string | null | undefined): string {
  if (!iso) return "Date TBD";
  const d = new Date(iso);
  return isNaN(d.getTime())
    ? "Date TBD"
    : d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", year: "numeric" });
}

function parse(result: CallToolResult | undefined): { count: number; events: EventRow[] } | null {
  const text = result?.content?.find((c) => c.type === "text")?.text;
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function render(data: { count: number; events: EventRow[] } | null): void {
  if (!data || !Array.isArray(data.events)) {
    statusEl.textContent = "No data.";
    return;
  }
  statusEl.textContent = data.count === 0 ? "No published events." : `${data.count} event${data.count === 1 ? "" : "s"}`;
  list.replaceChildren(
    ...data.events.map((e) => {
      const li = document.createElement("li");

      if (e.image_url) {
        const img = document.createElement("img");
        img.src = e.image_url;
        img.alt = "";
        li.appendChild(img);
      }

      const meta = document.createElement("div");
      meta.className = "meta";
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = e.name ?? "Untitled event";
      const sub = document.createElement("div");
      sub.className = "sub";
      sub.textContent = [when(e.starts_at), e.venue_name, e.venue_location].filter(Boolean).join(" · ");
      meta.append(name, sub);

      const p = document.createElement("div");
      p.className = "price";
      p.textContent = price(e.from_price);

      li.append(meta, p);
      return li;
    }),
  );
}

const app = new App({ name: "d4-events", version: "0.1.0" });
app.ontoolresult = (params) => render(parse(params as CallToolResult));

document.getElementById("refresh")!.addEventListener("click", async () => {
  statusEl.textContent = "Refreshing…";
  const result = await app.callServerTool({ name: "d4-events", arguments: {} });
  render(parse(result));
});

// Create-event / sell-ticket are deferred: the buttons are disabled in markup and
// wired to no tool. Deferral is enforced by the absence of any write tool, not UI state.

await app.connect();
