// SSRF guard for outbound requests to organizer-supplied URLs (webhooks).
//
// urlIsBlocked(): https-only; refuses internal hostnames; resolves A + AAAA and
// refuses the URL if ANY address is non-public. isPrivateIp(): true for every
// address that isn't plain public unicast — private, loopback, link-local,
// CGNAT, benchmarking, multicast, reserved, documentation, and the IPv6
// transition forms that can smuggle an IPv4 target (IPv4-mapped/-compatible,
// NAT64 64:ff9b::/96, 6to4 2002::/16, Teredo 2001::/32). Malformed → blocked.
//
// Residual risk (B1, flagged in mig 20260616200000): we resolve DNS, then
// fetch() resolves again — a DNS-rebinding host could flip to an internal IP
// between the lookups. Mitigations: URLs are set only by authenticated org
// owners/managers, redirects are disabled at the call site (redirect: "manual"),
// and literal IPs + internal names are refused outright.

export async function urlIsBlocked(
  rawUrl: string,
  resolve: (host: string) => Promise<string[]> = resolveAll,
): Promise<string | null> {
  let u: URL;
  try { u = new URL(rawUrl); } catch { return "invalid url"; }
  if (u.protocol !== "https:") return "non-https";
  if (u.username || u.password) return "credentials in url";
  // WHATWG URL keeps the brackets on an IPv6 literal ("[::1]") and allows a
  // trailing root dot ("localhost.") — strip both before checking.
  const host = u.hostname.replace(/^\[|\]$/g, "").replace(/\.$/, "").toLowerCase();
  if (!host) return "invalid url";
  if (
    host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") ||
    host.endsWith(".internal") || host.endsWith(".home.arpa")
  ) return "internal host";

  // Literal IP → check directly; else resolve BOTH A and AAAA and reject if ANY
  // address is non-public (a public A must not launder a private AAAA).
  const ips = /^[0-9.]+$/.test(host) || host.includes(":") ? [host] : await resolve(host);
  if (ips.length === 0) return "dns resolution failed";
  for (const ip of ips) {
    if (isPrivateIp(ip)) return `private ip ${ip}`;
  }
  return null;
}

async function resolveAll(host: string): Promise<string[]> {
  const out: string[] = [];
  for (const kind of ["A", "AAAA"] as const) {
    try {
      out.push(...await Deno.resolveDns(host, kind));
    } catch {
      /* this record type may not exist — rely on the other */
    }
  }
  return out;
}

export function isPrivateIp(ip: string): boolean {
  const s = ip.trim().replace(/^\[|\]$/g, "");
  return s.includes(":") ? isPrivateV6(s) : isPrivateV4(s);
}

function parseV4(ip: string): number[] | null {
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) return null;
  const p = ip.split(".").map(Number);
  return p.some((n) => n > 255) ? null : p;
}

function isPrivateV4(ip: string): boolean {
  const p = parseV4(ip);
  if (!p) return true; // malformed → block
  const [a, b, c] = p;
  return (
    a === 0 ||                                  // 0.0.0.0/8 "this network"
    a === 10 ||                                 // 10/8
    (a === 100 && b >= 64 && b <= 127) ||       // 100.64/10 CGNAT
    a === 127 ||                                // loopback
    (a === 169 && b === 254) ||                 // link-local + 169.254.169.254 metadata
    (a === 172 && b >= 16 && b <= 31) ||        // 172.16/12
    (a === 192 && b === 0 && c === 0) ||        // 192.0.0.0/24 IETF protocol assignments
    (a === 192 && b === 0 && c === 2) ||        // 192.0.2.0/24 TEST-NET-1
    (a === 192 && b === 88 && c === 99) ||      // 192.88.99.0/24 6to4 relay anycast
    (a === 192 && b === 168) ||                 // 192.168/16
    (a === 198 && (b === 18 || b === 19)) ||    // 198.18/15 benchmarking
    (a === 198 && b === 51 && c === 100) ||     // 198.51.100.0/24 TEST-NET-2
    (a === 203 && b === 0 && c === 113) ||      // 203.0.113.0/24 TEST-NET-3
    a >= 224                                    // 224/4 multicast + 240/4 reserved + broadcast
  );
}

// Expand an IPv6 literal (any compression, optional embedded dotted IPv4,
// optional %zone) into 8 hextets. null if malformed.
function parseV6(ip: string): number[] | null {
  let s = ip.toLowerCase();
  if (s.includes("%")) return null; // zone ids only make sense for link-local → treat as malformed
  let tail: number[] = [];
  const v4 = s.match(/:(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (v4) {
    const p = parseV4(v4[1]);
    if (!p) return null;
    tail = [(p[0] << 8) | p[1], (p[2] << 8) | p[3]];
    // Drop the dotted quad, keeping "::" intact ("::1.2.3.4" → "::",
    // "::ffff:1.2.3.4" → "::ffff", "0:0:0:0:0:ffff:1.2.3.4" → "0:0:0:0:0:ffff").
    s = s.slice(0, s.length - v4[1].length);
    if (!s.endsWith("::")) s = s.slice(0, -1);
  }
  const want = 8 - tail.length;
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const toNums = (h: string) => (h === "" ? [] : h.split(":"));
  const head = toNums(halves[0]);
  const rest = halves.length === 2 ? toNums(halves[1]) : [];
  if (halves.length === 1 && head.length !== want) return null;
  if (halves.length === 2 && head.length + rest.length >= want) return null;
  const fill = halves.length === 2 ? Array(want - head.length - rest.length).fill("0") : [];
  const parts = [...head, ...fill, ...rest];
  if (parts.length !== want) return null;
  const nums: number[] = [];
  for (const h of parts) {
    if (!/^[0-9a-f]{1,4}$/.test(h)) return null;
    nums.push(parseInt(h, 16));
  }
  return [...nums, ...tail];
}

function v4From(hi: number, lo: number): string {
  return `${(hi >> 8) & 255}.${hi & 255}.${(lo >> 8) & 255}.${lo & 255}`;
}

function isPrivateV6(ip: string): boolean {
  const h = parseV6(ip);
  if (!h) return true; // malformed → block
  const zero6 = h.slice(0, 6).every((x) => x === 0);
  if (zero6) return true;                                    // ::, ::1, ::/96 IPv4-compatible (deprecated)
  if (h.slice(0, 5).every((x) => x === 0) && h[5] === 0xffff) {
    return isPrivateV4(v4From(h[6], h[7]));                  // ::ffff:0:0/96 IPv4-mapped
  }
  if (h.slice(0, 4).every((x) => x === 0) && h[4] === 0xffff && h[5] === 0) return true; // ::ffff:0:0:0/96 SIIT
  if (h[0] === 0x64 && h[1] === 0xff9b) return true;          // 64:ff9b::/96 NAT64 + 64:ff9b:1::/48 local NAT64
  if (h[0] === 0x100 && h[1] === 0 && h[2] === 0 && h[3] === 0) return true; // 100::/64 discard
  if (h[0] === 0x2001 && h[1] === 0) return true;             // 2001::/32 Teredo (embeds IPv4)
  if (h[0] === 0x2001 && h[1] === 0x0db8) return true;        // 2001:db8::/32 documentation
  if (h[0] === 0x2002) return true;                           // 2002::/16 6to4 (embeds IPv4)
  if ((h[0] & 0xfe00) === 0xfc00) return true;                // fc00::/7 ULA
  if ((h[0] & 0xffc0) === 0xfe80) return true;                // fe80::/10 link-local
  if ((h[0] & 0xffc0) === 0xfec0) return true;                // fec0::/10 site-local (deprecated)
  if ((h[0] & 0xff00) === 0xff00) return true;                // ff00::/8 multicast
  return false;
}
