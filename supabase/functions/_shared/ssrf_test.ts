// deno test supabase/functions/_shared/ssrf_test.ts
import { isPrivateIp, urlIsBlocked } from "./ssrf.ts";

function check(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

const BLOCKED = [
  // IPv4
  "0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.254", "127.0.0.1",
  "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.0.2.1",
  "192.88.99.1", "192.168.1.1", "198.18.0.1", "198.19.255.255", "198.51.100.7",
  "203.0.113.9", "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
  "1.2.3", "256.1.1.1", "01.2.3.4.5",
  // IPv6
  "::", "::1", "[::1]", "::127.0.0.1", "::ffff:127.0.0.1", "::ffff:7f00:1",
  "::ffff:a9fe:a9fe", "0:0:0:0:0:ffff:10.0.0.1", "::ffff:0:10.0.0.1",
  "64:ff9b::8.8.8.8", "64:ff9b::a9fe:a9fe", "64:ff9b:1::1", "2002:c0a8:0101::1",
  "2002:0808:0808::1", "2001:0:4136:e378::1", "2001:db8::1", "100::1",
  "fc00::1", "fd12:3456::1", "fe80::1", "febf::1", "fec0::1", "ff02::1",
  "fe80::1%eth0", "1:2:3:4:5:6:7:8:9", "1::2::3", "gggg::1",
];
const ALLOWED = [
  "8.8.8.8", "1.1.1.1", "100.63.255.255", "100.128.0.0", "172.15.0.1", "172.32.0.1",
  "192.0.1.1", "198.17.0.1", "198.20.0.1", "223.255.255.255", "93.184.216.34",
  "2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8", "::ffff:808:808",
  "2a00:1450:4001:80b::200e",
];

Deno.test("isPrivateIp blocks non-public addresses", () => {
  for (const ip of BLOCKED) check(isPrivateIp(ip), `expected blocked: ${ip}`);
});

Deno.test("isPrivateIp allows public unicast", () => {
  for (const ip of ALLOWED) check(!isPrivateIp(ip), `expected allowed: ${ip}`);
});

Deno.test("urlIsBlocked: scheme, hosts, literals, DNS", async () => {
  const dns = (map: Record<string, string[]>) => (h: string) => Promise.resolve(map[h] ?? []);
  const pub = dns({ "hooks.example.com": ["93.184.216.34", "2606:2800:220:1::1"] });
  check(await urlIsBlocked("https://hooks.example.com/x", pub) === null, "public host allowed");
  check(await urlIsBlocked("http://hooks.example.com/x", pub) === "non-https", "http refused");
  check(await urlIsBlocked("not a url", pub) === "invalid url", "garbage refused");
  check(await urlIsBlocked("https://user:pw@hooks.example.com/", pub) !== null, "userinfo refused");
  for (const u of [
    "https://localhost/", "https://localhost./", "https://a.localhost/", "https://x.local/",
    "https://metadata.google.internal/", "https://[::1]/", "https://[::ffff:127.0.0.1]/",
    "https://[64:ff9b::a9fe:a9fe]/", "https://[2002:a9fe:a9fe::1]/", "https://127.1/",
    "https://0x7f000001/", "https://2130706433/", "https://198.18.0.1/", "https://224.0.0.1/",
  ]) check(await urlIsBlocked(u, pub) !== null, `expected blocked: ${u}`);
  // A public A record must not launder a private AAAA (and vice versa).
  const mixed = dns({ "evil.example.com": ["93.184.216.34", "fd00::1"] });
  check(await urlIsBlocked("https://evil.example.com/", mixed) !== null, "mixed A/AAAA blocked");
  check(await urlIsBlocked("https://nxdomain.example.com/", dns({})) === "dns resolution failed", "nxdomain");
});
