// Supabase Edge Function: notebook-llm (v1)
//
// Generic, SERVER-ONLY Claude Messages proxy for the open-notebook subsystem.
// It exists so the notebook's chat / transformations / RAG-synthesis can reach
// Claude using the platform's EXISTING Anthropic key (a Supabase secret / the
// `settings.anthropic_api_key` row) — with no per-service ANTHROPIC_API_KEY on
// Render and no new secret. Same trust model as the retail `chat` function:
// the trusted FastAPI proxy (open_notebook/providers.py) calls it with the
// service-role bearer; a browser/anon caller never can.
//
// Contract:
//   POST { system?: string, messages: [{role, content}], model?: string,
//          max_tokens?: number, temperature?: number }
//   ->   { text: string }             (200)
//        { error: string }            (4xx / 5xx)
//
// Read-only w.r.t. our data: one outbound Anthropic call, returns the
// completion text. It mutates no tables (the key lookup is a single SELECT with
// an env fallback).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const DEFAULT_MODEL = Deno.env.get("LLM_MODEL") ?? "claude-haiku-4-5-20251001";
const MAX_TOKENS_CAP = 8192;

function jsonResponse(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function resolveKey(db: any): Promise<string | null> {
  // Prefer the same secret the retail `chat` function uses, then generic envs.
  try {
    const { data } = await db.from("settings").select("value").eq("key", "anthropic_api_key").maybeSingle();
    if (data?.value) return data.value;
  } catch (_) { /* settings unreadable → fall back to env */ }
  return Deno.env.get("ANTHROPIC_API_KEY") ?? Deno.env.get("LLM_API_KEY") ?? null;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function callAnthropic(apiKey: string, payload: any, attempt = 0): Promise<Response> {
  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  if ((resp.status === 429 || resp.status === 529) && attempt < 3) {
    const ra = resp.headers.get("retry-after");
    const waitSec = ra ? Math.max(parseInt(ra, 10) || 1, 1) : Math.min(2 ** attempt, 8);
    await sleep(waitSec * 1000);
    return callAnthropic(apiKey, payload, attempt + 1);
  }
  return resp;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "method not allowed" }, 405);

  // Server-only guard: require the service-role bearer. Only the trusted proxy
  // (which holds SERVICE_ROLE_KEY) may drive this generic LLM proxy — it must
  // never be reachable from a browser/anon caller (it would let anyone burn
  // Anthropic cost with an arbitrary system prompt).
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const auth = req.headers.get("Authorization") ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!serviceRole || bearer !== serviceRole) return jsonResponse({ error: "unauthorized" }, 401);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceRole);
  const apiKey = await resolveKey(db);
  if (!apiKey) return jsonResponse({ error: "service not configured" }, 503);

  let body: any = null;
  try { body = await req.json(); } catch (_) { return jsonResponse({ error: "expected JSON body" }, 400); }

  const messages = Array.isArray(body?.messages) ? body.messages : null;
  if (!messages || !messages.length) return jsonResponse({ error: "messages required" }, 400);

  const payload: any = {
    model: typeof body?.model === "string" && body.model ? body.model : DEFAULT_MODEL,
    max_tokens: Math.min(Math.max(parseInt(body?.max_tokens, 10) || 2048, 1), MAX_TOKENS_CAP),
    temperature: typeof body?.temperature === "number" ? body.temperature : 0.4,
    messages,
  };
  if (typeof body?.system === "string" && body.system) payload.system = body.system;

  let resp: Response;
  try { resp = await callAnthropic(apiKey, payload); }
  catch (e) { return jsonResponse({ error: `anthropic unreachable: ${(e as Error).message}` }, 502); }

  let data: any = null;
  try { data = await resp.json(); } catch (_) { return jsonResponse({ error: "malformed anthropic response" }, 502); }
  if (!resp.ok) {
    const msg = data?.error?.message ?? `anthropic error ${resp.status}`;
    return jsonResponse({ error: msg }, resp.status >= 400 && resp.status < 600 ? resp.status : 502);
  }
  const text = Array.isArray(data?.content)
    ? data.content.filter((b: any) => b?.type === "text").map((b: any) => b.text).join("")
    : "";
  return jsonResponse({ text });
});
