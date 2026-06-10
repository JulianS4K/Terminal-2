import express, { Request, Response, NextFunction } from "express";
import { createServer as createViteServer } from "vite";
import path from "path";
import Stripe from "stripe";
import { fileURLToPath } from "url";
import crypto from "crypto";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ---------------------------------------------------------------------------
// Production hardening notes (vs. the original prototype):
//   * Reads PORT from env (PaaS like Cloud Run/Render require this).
//   * Caps JSON body size — defends against trivial OOM payloads.
//   * Adds basic security headers without pulling in Helmet (kept dep-light).
//   * Adds a request id + structured access log on every request.
//   * Adds /healthz so a load balancer can probe liveness.
//   * Catches uncaught route errors centrally instead of leaking stacks.
//   * Handles SIGTERM/SIGINT cleanly so in-flight requests don't get cut off.
// Stripe payment flow is intentionally untouched — slated for the
// later phase that introduces the webhook + server-side fulfillment.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// In-memory token-bucket rate limiter.
//
// Implemented inline rather than pulling in `express-rate-limit` to keep the
// dependency surface small. Limit is per-key and per-process — fine for a
// single replica; behind a multi-replica deployment swap this for a Redis-
// backed limiter (Cloud Memorystore / Upstash) so quotas are shared.
//
// Defaults: 30 requests per minute per key on /api/*. The Stripe checkout
// endpoint specifically gets a tighter cap to deter Stripe-session spam.
// ---------------------------------------------------------------------------
interface Bucket {
  tokens: number;
  updatedAt: number;
}
const rateBuckets = new Map<string, Bucket>();

// Light-weight cleanup so the map can't grow unbounded under churn (every
// new client IP would otherwise stay in memory forever).
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of rateBuckets) {
    // 5 minutes idle and above the refill ceiling — safe to drop.
    if (now - v.updatedAt > 5 * 60_000) rateBuckets.delete(k);
  }
}, 60_000).unref();

function rateLimit(opts: { capacity: number; refillPerMinute: number; keyPrefix: string }) {
  const refillRate = opts.refillPerMinute / 60_000; // tokens per ms
  return (req: Request, res: Response, next: NextFunction) => {
    // Trust X-Forwarded-For only when express trust proxy is configured;
    // otherwise fall back to socket IP. Combining method+route into the key
    // keeps GETs and POSTs from sharing a bucket.
    const ip = (req.ip || req.socket.remoteAddress || 'unknown').toString();
    const key = `${opts.keyPrefix}:${ip}`;

    const now = Date.now();
    let bucket = rateBuckets.get(key);
    if (!bucket) {
      bucket = { tokens: opts.capacity, updatedAt: now };
      rateBuckets.set(key, bucket);
    } else {
      const elapsed = now - bucket.updatedAt;
      bucket.tokens = Math.min(opts.capacity, bucket.tokens + elapsed * refillRate);
      bucket.updatedAt = now;
    }

    if (bucket.tokens < 1) {
      const retryAfterMs = Math.ceil((1 - bucket.tokens) / refillRate);
      res.setHeader('Retry-After', Math.ceil(retryAfterMs / 1000));
      return res.status(429).json({ error: 'Too many requests' });
    }
    bucket.tokens -= 1;
    return next();
  };
}

// Parse the CORS allowlist from CORS_ORIGINS (comma-separated). Empty list
// → same-origin only (no Access-Control-Allow-Origin emitted, which makes
// browsers refuse cross-origin reads from anywhere).
function parseAllowlist(): Set<string> {
  const raw = process.env.CORS_ORIGINS || '';
  return new Set(raw.split(',').map((s) => s.trim()).filter(Boolean));
}

async function startServer() {
  const app = express();
  const PORT = Number(process.env.PORT) || 3000;
  const HOST = process.env.HOST || "0.0.0.0";
  const isProd = process.env.NODE_ENV === "production";
  const corsAllowlist = parseAllowlist();

  // If the SPA and API are on the same origin (default for `npm start`),
  // CORS is not needed and the allowlist stays empty. Set CORS_ORIGINS to a
  // comma-separated list when deploying the API on a different hostname.
  app.use((req, res, next) => {
    const origin = req.header('Origin');
    if (origin && corsAllowlist.has(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
      res.setHeader('Access-Control-Max-Age', '600');
    }
    if (req.method === 'OPTIONS') {
      // Short-circuit preflight only when origin is allowed; otherwise the
      // missing CORS headers will cause the browser to block — which is the
      // correct behaviour.
      return res.status(origin && corsAllowlist.has(origin) ? 204 : 403).end();
    }
    return next();
  });

  // Lazy Stripe client: only instantiated on the first request that needs it,
  // and only if the secret is configured. Lets the app boot without it.
  let stripe: Stripe | null = null;
  const getStripe = () => {
    if (!stripe) {
      const key = process.env.STRIPE_SECRET_KEY;
      if (!key) {
        console.warn("STRIPE_SECRET_KEY not set. Payments will fail.");
        return null;
      }
      stripe = new Stripe(key);
    }
    return stripe;
  };

  // -- Security headers ----------------------------------------------------
  // Minimal set of headers that any web app should send. We don't ship a
  // strict CSP yet because the SPA pulls Stripe.js + Firebase from CDNs and
  // a misconfigured CSP would silently break checkout. Add one once the
  // origin allowlist is known.
  app.use((_req, res, next) => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    res.setHeader(
      "Permissions-Policy",
      "camera=(self), geolocation=(), microphone=()"
    );
    if (isProd) {
      res.setHeader(
        "Strict-Transport-Security",
        "max-age=31536000; includeSubDomains"
      );
    }
    next();
  });

  // -- Request id + access log --------------------------------------------
  app.use((req, res, next) => {
    const requestId =
      (req.header("x-request-id") as string | undefined) ||
      crypto.randomUUID();
    res.setHeader("X-Request-Id", requestId);
    (req as Request & { id: string }).id = requestId;

    const start = Date.now();
    res.on("finish", () => {
      const ms = Date.now() - start;
      // One-line structured log; easy to parse from any log aggregator.
      console.log(
        JSON.stringify({
          t: new Date().toISOString(),
          lvl: "info",
          reqId: requestId,
          method: req.method,
          path: req.originalUrl,
          status: res.statusCode,
          ms,
        })
      );
    });
    next();
  });

  // -- Body parsing with a sane cap ---------------------------------------
  // 100kb is plenty for the API's JSON payloads. If something legitimately
  // larger comes along (e.g. ticket batch ops) raise it on a per-route basis.
  app.use(express.json({ limit: "100kb" }));

  // -- Health check (used by load balancers, uptime monitors) -------------
  app.get("/healthz", (_req, res) => {
    res.status(200).json({ status: "ok", uptime: process.uptime() });
  });

  // Canonical public base URL for crawler-facing absolute links. Pinned to
  // VITE_APP_URL (same env Stripe redirect URLs use) so a forged Host /
  // X-Forwarded-Proto header can't poison robots.txt or the cached sitemap.
  // Request-header fallback is dev-only convenience when the env is unset.
  const publicBase = (req: express.Request): string => {
    const configured = (process.env.VITE_APP_URL || '').replace(/\/$/, '');
    if (configured) return configured;
    const host = req.get('host') || 'localhost';
    const proto = (req.get('x-forwarded-proto') || req.protocol || 'https') as string;
    return `${proto}://${host}`;
  };

  // -- robots.txt -----------------------------------------------------------
  // Allow indexing of public surfaces, deny embed routes (those are
  // for iframe consumption, not for crawler ingestion). Points at the
  // sitemap so Googlebot finds the full event list.
  app.get('/robots.txt', (req, res) => {
    res.type('text/plain').send(
      [
        'User-agent: *',
        'Allow: /',
        'Disallow: /embed/',
        'Disallow: /api/',
        'Disallow: /dashboard',
        'Disallow: /create-event',
        'Disallow: /edit-event/',
        'Disallow: /checkin/',
        'Disallow: /onboarding',
        '',
        `Sitemap: ${publicBase(req)}/sitemap.xml`,
        '',
      ].join('\n'),
    );
  });

  // -- sitemap.xml ----------------------------------------------------------
  // Generates a sitemap pointing at every published event + every org
  // storefront. Queries the public Supabase projections (exos_public_events /
  // exos_public_orgs) with the anon key — both are anon-readable views.
  // Cached in-memory for 10 minutes so a hammering crawler doesn't
  // burn reads on every hit.
  let sitemapCache: { generatedAt: number; xml: string } | null = null;
  const SITEMAP_TTL_MS = 10 * 60 * 1000;
  app.get('/sitemap.xml', async (req, res, next) => {
    try {
      if (
        sitemapCache &&
        Date.now() - sitemapCache.generatedAt < SITEMAP_TTL_MS
      ) {
        res.type('application/xml').send(sitemapCache.xml);
        return;
      }
      // Read published events + org storefronts from the public Supabase
      // projections. exos_public_events is already status=published (the view's
      // WHERE clause) and exos_public_orgs/events are anon-readable, so the
      // anon key suffices. Lazy-import keeps dev-mode boot snappy. Absent env →
      // throws, caught below → graceful empty-sitemap stub.
      const { createClient } = await import('@supabase/supabase-js');
      const sbUrl = process.env.VITE_SUPABASE_URL;
      const sbKey = process.env.VITE_SUPABASE_ANON_KEY;
      if (!sbUrl || !sbKey) throw new Error('Supabase env (VITE_SUPABASE_URL / _ANON_KEY) missing');
      const sb = createClient(sbUrl, sbKey);
      const [{ data: events }, { data: orgs }] = await Promise.all([
        sb.from('exos_public_events').select('id, starts_at').limit(1000),
        sb.from('exos_public_orgs').select('slug').limit(500),
      ]);

      const base = publicBase(req);
      const urls: string[] = [
        `<url><loc>${base}/</loc><changefreq>daily</changefreq><priority>1.0</priority></url>`,
      ];
      for (const e of events ?? []) {
        const row = e as { id: string; starts_at?: string | null };
        const lastmod = row.starts_at ? new Date(row.starts_at).toISOString() : null;
        urls.push(
          `<url><loc>${base}/event/${row.id}</loc>${
            lastmod ? `<lastmod>${lastmod}</lastmod>` : ''
          }<changefreq>daily</changefreq><priority>0.8</priority></url>`,
        );
      }
      for (const o of orgs ?? []) {
        const slug = (o as { slug?: string }).slug;
        if (!slug) continue;
        urls.push(
          `<url><loc>${base}/o/${slug}</loc><changefreq>weekly</changefreq><priority>0.6</priority></url>`,
        );
      }
      const xml =
        '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
        urls.join('\n') +
        '\n</urlset>\n';
      sitemapCache = { generatedAt: Date.now(), xml };
      res.type('application/xml').send(xml);
    } catch (err) {
      // Sitemap failure shouldn't 500 the whole server; serve a stub.
      res.type('application/xml').send(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>\n',
      );
      next?.(); // eslint-disable-line @typescript-eslint/no-unused-expressions
    }
  });

  // -- Rate limiting --------------------------------------------------------
  // Apply a generous per-IP cap to all /api/* endpoints, plus a tighter cap
  // on the Stripe checkout creation endpoint (which has real cost on Stripe's
  // side and shouldn't be spammable).
  const apiLimiter = rateLimit({
    capacity: 60,
    refillPerMinute: 60,
    keyPrefix: 'api',
  });
  const checkoutLimiter = rateLimit({
    capacity: 10,
    refillPerMinute: 10,
    keyPrefix: 'checkout',
  });
  app.use('/api', apiLimiter);
  app.use('/api/create-checkout-session', checkoutLimiter);

  // -- API: Create Stripe Checkout Session --------------------------------
  // NOTE: This still trusts the client-supplied price. Validating against
  // the event/tier doc on the server is part of the deferred Stripe phase.
  app.post("/api/create-checkout-session", async (req, res, next) => {
    try {
      const { price, eventName, eventId, tierId, userId, quantity, promoCode, currency, promoterId } = req.body;
      const stripeClient = getStripe();
      if (!stripeClient) {
        return res.status(503).json({ error: "Stripe not configured" });
      }

      const session = await stripeClient.checkout.sessions.create({
        payment_method_types: ["card"],
        line_items: [
          {
            price_data: {
              // Currency comes from the event doc, threaded through by
              // EventDetails. Stripe accepts ISO 4217 lowercase. We
              // default to USD when the request omits it (legacy events
              // pre-currency-field). The phase-2 Stripe rebuild should
              // validate this against an allowlist of currencies the
              // platform is enabled for.
              currency: typeof currency === 'string' && /^[A-Za-z]{3}$/.test(currency)
                ? currency.toLowerCase()
                : 'usd',
              product_data: {
                name: `${eventName} - Ticket`,
                metadata: { eventId, tierId, userId },
              },
              unit_amount: Math.round(price * 100),
            },
            quantity: quantity || 1,
          },
        ],
        mode: "payment",
        success_url: `${process.env.VITE_APP_URL || "http://localhost:3000"}/my-tickets?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${process.env.VITE_APP_URL || "http://localhost:3000"}/event/${eventId}`,
        metadata: {
          eventId,
          tierId,
          userId,
          quantity: (quantity || 1).toString(),
          // Promo code passes through metadata so MyTickets fulfillment
          // can increment events/{id}/promoUses/{code} once the buyer
          // actually pays. Stripe rejects null metadata values, so we
          // collapse missing codes to an empty string.
          promoCode: typeof promoCode === 'string' ? promoCode : '',
          // Promoter / affiliate attribution. Empty string when no
          // promoter was supplied. We additionally restrict the
          // character set with a regex to refuse anything that could
          // surface in dashboards / CSV exports as raw HTML or
          // JSON-breaking glyphs. Stripe metadata accepts ~500 chars
          // per value; we go stricter.
          promoterId:
            typeof promoterId === 'string' &&
            /^[A-Za-z0-9_-]{1,64}$/.test(promoterId)
              ? promoterId
              : '',
        },
      });

      return res.json({ id: session.id });
    } catch (err) {
      return next(err);
    }
  });

  app.get("/api/verify-session", async (req, res, next) => {
    try {
      const { session_id } = req.query;
      const stripeClient = getStripe();
      if (!stripeClient || !session_id) {
        return res.status(400).json({ error: "Invalid request" });
      }

      const session = await stripeClient.checkout.sessions.retrieve(
        session_id as string
      );
      if (session.payment_status === "paid") {
        return res.json({ status: "paid", metadata: session.metadata });
      } else {
        return res.json({ status: session.payment_status });
      }
    } catch (err) {
      return next(err);
    }
  });

  // -- Vite middleware for dev / static assets in prod --------------------
  if (!isProd) {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "spa",
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), "dist");
    app.use(
      express.static(distPath, {
        // Hashed assets are immutable — let CDNs cache them aggressively.
        // index.html is served below with no-cache so the user always gets
        // a fresh entrypoint.
        setHeaders: (res, filePath) => {
          if (/\.[a-f0-9]{8,}\./.test(filePath)) {
            res.setHeader(
              "Cache-Control",
              "public, max-age=31536000, immutable"
            );
          }
        },
      })
    );

    app.get("*", (_req, res) => {
      res.setHeader("Cache-Control", "no-cache");
      res.sendFile(path.join(distPath, "index.html"));
    });
  }

  // -- Central error handler ---------------------------------------------
  // Express has to recognise the four-arg signature for this to fire.
  app.use((err: any, req: Request, res: Response, _next: NextFunction) => {
    const reqId = (req as Request & { id?: string }).id;
    console.error(
      JSON.stringify({
        t: new Date().toISOString(),
        lvl: "error",
        reqId,
        path: req.originalUrl,
        message: err?.message,
        stack: err?.stack,
      })
    );
    if (res.headersSent) return;
    // Don't leak internal error messages to clients in production.
    res
      .status(500)
      .json({ error: isProd ? "Internal Server Error" : err?.message });
  });

  const server = app.listen(PORT, HOST, () => {
    console.log(`Server running on http://${HOST}:${PORT}`);
  });

  // -- Graceful shutdown --------------------------------------------------
  // PaaS sends SIGTERM on deploy/scale-down; finishing in-flight requests
  // before exiting prevents 502s during rollouts.
  const shutdown = (signal: NodeJS.Signals) => {
    console.log(`Received ${signal}, shutting down gracefully...`);
    server.close((err) => {
      if (err) {
        console.error("Error during shutdown", err);
        process.exit(1);
      }
      process.exit(0);
    });
    // Hard-kill backstop in case something hangs forever.
    setTimeout(() => {
      console.error("Forcing exit after 10s shutdown timeout");
      process.exit(1);
    }, 10_000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

startServer().catch((err) => {
  console.error("Failed to start server", err);
  process.exit(1);
});
