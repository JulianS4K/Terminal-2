// Runtime SEO meta-tag helper.
//
// Modern crawlers (Googlebot, Bingbot, social previewers) execute
// JavaScript before reading meta tags, so SPA-side runtime updates
// to title/description/OG/Schema.org actually do reach indexers.
// The two requirements that are non-negotiable for this to work:
//   1. The relevant meta tag must EXIST in the initial HTML — we
//      can update it but we can't add it from JS in time. That's
//      handled by the placeholder tags in index.html.
//   2. We must update document.title (sets the page tab + the
//      crawler-visible title) AND the corresponding <meta property>.
//
// What this module does NOT do:
//   * Server-side rendering. We rely on the crawler executing JS.
//     For social previewers that don't (some link unfurlers), the
//     index.html defaults are what they see.
//   * Sitemap generation. That's in server.ts.

export interface MetaInput {
  title: string;
  description?: string;
  // Absolute URL of an image (>= 1200x630 ideal for social cards).
  imageUrl?: string;
  // Canonical URL — set this on every page to suppress duplicate-
  // content penalties from utm-tagged variants.
  canonicalUrl?: string;
  // Schema.org Event JSON-LD. Pass null to skip (default).
  event?: SchemaEvent;
}

export interface SchemaEvent {
  name: string;
  startDate: string; // ISO 8601
  endDate?: string;
  location: {
    name: string;
    streetAddress?: string;
    city?: string;
    region?: string;
    country?: string;
    postal?: string;
  };
  organizer?: {
    name: string;
    url?: string;
  };
  offers?: {
    price?: number;
    currency?: string;
    availability?: 'InStock' | 'SoldOut' | 'PreOrder';
    url?: string;
  };
  image?: string;
  description?: string;
}

export function applyMeta(input: MetaInput): void {
  if (typeof document === 'undefined') return;

  // Title.
  document.title = `${input.title} | Exos`;

  // <meta name="description">
  setOrCreateMeta('name', 'description', input.description ?? '');

  // Open Graph.
  setOrCreateMeta('property', 'og:title', input.title);
  setOrCreateMeta('property', 'og:type', input.event ? 'event' : 'website');
  if (input.description) setOrCreateMeta('property', 'og:description', input.description);
  if (input.imageUrl) setOrCreateMeta('property', 'og:image', input.imageUrl);
  if (input.canonicalUrl) setOrCreateMeta('property', 'og:url', input.canonicalUrl);

  // Twitter Card.
  setOrCreateMeta('name', 'twitter:card', input.imageUrl ? 'summary_large_image' : 'summary');
  setOrCreateMeta('name', 'twitter:title', input.title);
  if (input.description) setOrCreateMeta('name', 'twitter:description', input.description);
  if (input.imageUrl) setOrCreateMeta('name', 'twitter:image', input.imageUrl);

  // Canonical link.
  if (input.canonicalUrl) {
    let canonical = document.querySelector('link[rel="canonical"]') as HTMLLinkElement | null;
    if (!canonical) {
      canonical = document.createElement('link');
      canonical.rel = 'canonical';
      document.head.appendChild(canonical);
    }
    canonical.href = input.canonicalUrl;
  }

  // Schema.org Event JSON-LD.
  // Single <script type="application/ld+json" id="vibepass-jsonld">.
  if (input.event) {
    const ld = buildEventJsonLd(input.event);
    let script = document.getElementById('vibepass-jsonld') as HTMLScriptElement | null;
    if (!script) {
      script = document.createElement('script');
      script.type = 'application/ld+json';
      script.id = 'vibepass-jsonld';
      document.head.appendChild(script);
    }
    script.textContent = JSON.stringify(ld);
  } else {
    // Clear any prior JSON-LD when navigating to a non-event page.
    const script = document.getElementById('vibepass-jsonld');
    script?.parentNode?.removeChild(script);
  }
}

function setOrCreateMeta(attr: 'name' | 'property', value: string, content: string) {
  let el = document.querySelector(`meta[${attr}="${value}"]`) as HTMLMetaElement | null;
  if (!el) {
    el = document.createElement('meta');
    el.setAttribute(attr, value);
    document.head.appendChild(el);
  }
  el.setAttribute('content', content);
}

function buildEventJsonLd(ev: SchemaEvent) {
  const out: Record<string, unknown> = {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: ev.name,
    startDate: ev.startDate,
    location: {
      '@type': 'Place',
      name: ev.location.name,
      address: {
        '@type': 'PostalAddress',
        streetAddress: ev.location.streetAddress,
        addressLocality: ev.location.city,
        addressRegion: ev.location.region,
        postalCode: ev.location.postal,
        addressCountry: ev.location.country,
      },
    },
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
    eventStatus: 'https://schema.org/EventScheduled',
  };
  if (ev.endDate) out.endDate = ev.endDate;
  if (ev.image) out.image = ev.image;
  if (ev.description) out.description = ev.description;
  if (ev.organizer) {
    out.organizer = {
      '@type': 'Organization',
      name: ev.organizer.name,
      ...(ev.organizer.url ? { url: ev.organizer.url } : {}),
    };
  }
  if (ev.offers) {
    out.offers = {
      '@type': 'Offer',
      ...(ev.offers.price !== undefined ? { price: ev.offers.price.toFixed(2) } : {}),
      ...(ev.offers.currency ? { priceCurrency: ev.offers.currency } : {}),
      ...(ev.offers.availability
        ? { availability: `https://schema.org/${ev.offers.availability}` }
        : {}),
      ...(ev.offers.url ? { url: ev.offers.url } : {}),
    };
  }
  return out;
}
