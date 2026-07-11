import { App } from "@modelcontextprotocol/ext-apps";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

const log = document.getElementById("log")!;
const form = document.getElementById("form") as HTMLFormElement;
const input = document.getElementById("input") as HTMLInputElement;
const send = document.getElementById("send") as HTMLButtonElement;

function addMsg(role: "user" | "bot", text: string): void {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  div.textContent = text;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
}

function replyText(result: CallToolResult | undefined): string {
  const text = result?.content?.find((c) => c.type === "text")?.text;
  if (!text) return "(no response)";
  try {
    const d = JSON.parse(text) as Record<string, unknown>;
    return String(d.reply ?? d.message ?? d.error ?? text);
  } catch {
    return text;
  }
}

const app = new App({ name: "d1-concierge", version: "0.1.0" });
// Initial tool call (if the host opened the app via a d1-concierge call) lands here.
app.ontoolresult = (params) => addMsg("bot", replyText(params as CallToolResult));

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const q = input.value.trim();
  if (!q) return;
  addMsg("user", q);
  input.value = "";
  send.disabled = true;
  try {
    const result = await app.callServerTool({ name: "d1-concierge", arguments: { message: q } });
    addMsg("bot", replyText(result));
  } catch (err) {
    addMsg("bot", `Something went wrong: ${String(err)}`);
  } finally {
    send.disabled = false;
    input.focus();
  }
});

await app.connect();
