// PromoteEvent — organizer-facing promotion toolkit for one event.
//
// Lives at /dashboard/event/:eventId/promote (linked from the dashboard
// event row's Megaphone action). Everything a venue/promoter needs to push
// an event out the door, in one place:
//   * the canonical public link (copy / native-share / X / Facebook)
//   * a downloadable QR for posters & flyers
//   * a paste-ready embed snippet for the venue's own site
//   * caption templates for IG / TikTok / X
//   * a jump to Marketing & socials (pixels) so ad spend is measurable
//
// All URLs are built with publicUrl() so they carry the /bridge base in the
// current deployment (and resolve at root post-beta). A bare ${origin}/event
// link 404s today — see lib/utils.ts publicUrl().

import { useEffect, useMemo, useRef, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { QRCodeCanvas } from 'qrcode.react';
import {
  ArrowLeft, Megaphone, Copy, Download, Code2, Share2, ExternalLink,
  Twitter, Facebook, QrCode, Sparkles, Settings, Tag,
} from 'lucide-react';
import { getEventForEdit } from '../lib/events';
import { Event, Organization } from '../types';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { publicUrl } from '../lib/utils';
import { formatInTz } from '../lib/datetime';
import ShareModal from '../components/ShareModal';
import SocialLinks from '../components/SocialLinks';

// Channel presets for the campaign-link builder. utm_medium follows the GA4
// convention (social / email / cpc) so the org's GA4 + ad pixels bucket them
// correctly with zero extra config.
const CHANNELS: { key: string; label: string; medium: string }[] = [
  { key: 'instagram', label: 'Instagram', medium: 'social' },
  { key: 'tiktok', label: 'TikTok', medium: 'social' },
  { key: 'facebook', label: 'Facebook', medium: 'social' },
  { key: 'x', label: 'X / Twitter', medium: 'social' },
  { key: 'email', label: 'Email', medium: 'email' },
  { key: 'meta-ads', label: 'Paid — Meta', medium: 'cpc' },
  { key: 'google-ads', label: 'Paid — Google', medium: 'cpc' },
];

const slugify = (s: string) =>
  s.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');

export default function PromoteEvent() {
  const { eventId } = useParams();
  const { user } = useAuth();
  const { orgs } = useOrganization();
  const { toast } = useToast();
  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);
  const [shareOpen, setShareOpen] = useState(false);
  const [campaignName, setCampaignName] = useState('');
  const qrWrapRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!eventId) return;
      setLoading(true);
      try {
        const ev = await getEventForEdit(eventId);
        if (!cancelled) setEvent(ev);
      } catch (err) {
        console.error('Failed to load event for promote:', err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    void load();
    return () => { cancelled = true; };
  }, [eventId]);

  // The org this event belongs to (for socials + the settings deep-link).
  const org: Organization | undefined = useMemo(
    () => orgs.find((o) => o.org.id === event?.orgId)?.org,
    [orgs, event?.orgId],
  );

  const url = eventId ? publicUrl(`event/${eventId}`) : '';
  const published = (event?.status ?? 'published') === 'published';

  // Campaign-link builder. The campaign slug is set as BOTH utm_campaign (for
  // the org's GA4/Meta/TikTok dashboards) AND promoter= (for first-party
  // attribution — the buy flow stamps it onto exos_tickets.promoter_id, which
  // the event Sales report already aggregates into a per-campaign table).
  const campaignSlug = slugify(campaignName);
  const buildCampaignUrl = (ch: { key: string; medium: string }): string => {
    if (!eventId) return '';
    const u = new URL(publicUrl(`event/${eventId}`));
    if (campaignSlug) {
      u.searchParams.set('utm_campaign', campaignSlug);
      u.searchParams.set('promoter', campaignSlug);
    }
    u.searchParams.set('utm_source', ch.key);
    u.searchParams.set('utm_medium', ch.medium);
    return u.toString();
  };

  const dateLabel = event?.date
    ? formatInTz(event.date.toDate(), event.timezone, {
        weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
      })
    : '';

  const copy = async (value: string, label = 'Copied.') => {
    try {
      await navigator.clipboard.writeText(value);
      toast({ kind: 'success', message: label });
    } catch {
      toast({ kind: 'error', message: 'Could not copy — long-press to copy manually.' });
    }
  };

  const downloadQr = () => {
    const canvas = qrWrapRef.current?.querySelector('canvas');
    if (!canvas) return;
    const a = document.createElement('a');
    a.href = canvas.toDataURL('image/png');
    a.download = `qr-${event?.slug || eventId || 'event'}.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    toast({ kind: 'success', message: 'QR downloaded — drop it on a poster or flyer.' });
  };

  const title = event?.title || 'this event';
  const captions = [
    `🎟️ ${title}${dateLabel ? ` — ${dateLabel}` : ''}. Grab tickets: ${url}`,
    `We're live! ${title} tickets are on sale now → ${url} . Tag who you're bringing 👇`,
    `Don't miss ${title}. Limited tickets, secure yours here: ${url}`,
  ];

  const embedSnippet = `<!-- Exos embed — ${title} -->
<iframe id="vibepass-embed" src="${publicUrl(`embed/event/${eventId}`)}" style="width:100%;border:0;min-height:200px" loading="lazy" title="Tickets"></iframe>
<script>
window.addEventListener('message', function(e) {
  if (e.origin !== '${typeof window !== 'undefined' ? window.location.origin : ''}') return;
  if (e.data && e.data.type === 'vibepass:resize') {
    var f = document.getElementById('vibepass-embed');
    if (f) f.style.height = e.data.height + 'px';
  }
});
</script>`;

  const twitterHref = `https://twitter.com/intent/tweet?text=${encodeURIComponent(`${title} ${url}`)}`;
  const facebookHref = `https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}`;

  if (!user) {
    return <div className="max-w-3xl mx-auto p-20 text-center text-slate-500">Sign in to promote your events.</div>;
  }
  if (loading) {
    return <div className="max-w-3xl mx-auto p-20 text-center text-slate-300 font-bold uppercase tracking-widest text-xs">Loading…</div>;
  }
  if (!event) {
    return (
      <div className="max-w-3xl mx-auto p-20 text-center">
        <p className="text-slate-400 font-bold uppercase tracking-widest text-[10px] mb-4">Event not found</p>
        <Link to="/dashboard" className="text-[#026cdf] font-bold text-sm">Back to dashboard</Link>
      </div>
    );
  }

  return (
    <div className="bg-[#f2f4f7] min-h-screen">
      <div className="max-w-3xl mx-auto px-4 py-12">
        <Link to="/dashboard" className="flex items-center text-slate-400 hover:text-slate-900 mb-8 transition-colors font-bold uppercase tracking-widest text-[10px]">
          <ArrowLeft className="w-4 h-4 mr-2" /> Back to Dashboard
        </Link>

        <div className="flex items-center gap-3 mb-2">
          <Megaphone className="w-6 h-6 text-[#026cdf]" />
          <h1 className="text-3xl font-bold tracking-tight text-slate-900">Promote</h1>
        </div>
        <p className="text-slate-500 text-sm mb-2">{event.title}{dateLabel ? ` · ${dateLabel}` : ''}</p>

        {!published && (
          <div className="mb-8 p-4 rounded-xl border border-amber-200 bg-amber-50 text-amber-800 text-xs font-bold">
            This event is a {event.status || 'draft'}. The public link below won't work until you publish it
            (only published events are visible to buyers).
          </div>
        )}

        {/* Share the link */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4 flex items-center gap-2">
            <Share2 className="w-4 h-4 text-[#026cdf]" /> Share the link
          </h2>
          <div className="flex items-center gap-2 mb-4">
            <input
              readOnly
              value={url}
              aria-label="Public event link"
              onFocus={(e) => e.currentTarget.select()}
              className="flex-1 bg-slate-50 border border-slate-200 rounded-xl px-4 py-3 text-sm font-mono text-slate-700 truncate"
            />
            <button
              onClick={() => copy(url, 'Link copied.')}
              className="px-4 py-3 bg-slate-900 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors flex items-center gap-2"
            >
              <Copy className="w-3.5 h-3.5" /> Copy
            </button>
          </div>
          <div className="flex flex-wrap gap-2">
            <button onClick={() => setShareOpen(true)} className="flex items-center gap-2 px-4 py-2.5 bg-[#026cdf] text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-[#015bbd] transition-colors">
              <Share2 className="w-3.5 h-3.5" /> Share…
            </button>
            <a href={twitterHref} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2 px-4 py-2.5 bg-white border border-slate-200 text-slate-700 rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-50 transition-colors">
              <Twitter className="w-3.5 h-3.5" /> X / Twitter
            </a>
            <a href={facebookHref} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2 px-4 py-2.5 bg-white border border-slate-200 text-slate-700 rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-50 transition-colors">
              <Facebook className="w-3.5 h-3.5" /> Facebook
            </a>
            <a href={url} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2 px-4 py-2.5 bg-white border border-slate-200 text-slate-700 rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-50 transition-colors">
              <ExternalLink className="w-3.5 h-3.5" /> Preview
            </a>
          </div>
        </section>

        {/* Campaign links — create + track */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-1 flex items-center gap-2">
            <Tag className="w-4 h-4 text-[#026cdf]" /> Campaign links
          </h2>
          <p className="text-sm text-slate-600 mb-4">
            Name a campaign and share its per-channel link. Sales attributed to it appear in this event's{' '}
            <Link to={`/dashboard/event/${eventId}`} className="text-[#026cdf] font-bold">Sales report</Link>;
            paid reach &amp; ROAS show in your Meta / GA4 / TikTok dashboards (configure pixels below).
          </p>
          <input
            value={campaignName}
            onChange={(e) => setCampaignName(e.target.value)}
            placeholder="Campaign name — e.g. spring-launch, radio-spot, influencer-jane"
            aria-label="Campaign name"
            className="w-full bg-slate-50 border border-slate-200 rounded-xl px-4 py-3 text-sm font-bold text-slate-900 placeholder:font-normal placeholder:text-slate-400 focus:outline-none focus:border-[#026cdf] mb-4"
          />
          {campaignSlug ? (
            <div className="space-y-2">
              {CHANNELS.map((ch) => {
                const link = buildCampaignUrl(ch);
                return (
                  <div key={ch.key} className="flex items-center gap-2 bg-slate-50 border border-slate-100 rounded-xl px-3 py-2">
                    <span className="text-[10px] font-black uppercase tracking-widest text-slate-500 w-28 shrink-0">{ch.label}</span>
                    <span className="flex-1 text-[11px] font-mono text-slate-600 truncate">{link}</span>
                    <button onClick={() => copy(link, `${ch.label} link copied.`)} aria-label={`Copy ${ch.label} link`} className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors shrink-0"><Copy className="w-4 h-4" /></button>
                  </div>
                );
              })}
            </div>
          ) : (
            <p className="text-[11px] text-slate-400 italic">Enter a campaign name to generate per-channel tracked links.</p>
          )}
        </section>

        {/* QR code */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4 flex items-center gap-2">
            <QrCode className="w-4 h-4 text-[#026cdf]" /> Poster QR code
          </h2>
          <div className="flex items-center gap-6 flex-wrap">
            <div ref={qrWrapRef} className="p-4 bg-white border border-slate-200 rounded-2xl">
              <QRCodeCanvas value={url} size={160} level="M" includeMargin />
            </div>
            <div className="flex-1 min-w-[200px]">
              <p className="text-sm text-slate-600 mb-4">
                Print this on flyers, posters, or the door. It points straight to the ticket page.
              </p>
              <button onClick={downloadQr} className="flex items-center gap-2 px-4 py-2.5 bg-slate-900 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors">
                <Download className="w-3.5 h-3.5" /> Download PNG
              </button>
            </div>
          </div>
        </section>

        {/* Embed */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4 flex items-center gap-2">
            <Code2 className="w-4 h-4 text-[#026cdf]" /> Embed on your site
          </h2>
          <p className="text-sm text-slate-600 mb-3">
            Paste this into your own website (WordPress, Wix, Squarespace, or hand-written HTML). It self-resizes.
          </p>
          <pre className="bg-slate-900 text-slate-100 text-[11px] rounded-xl p-4 overflow-x-auto font-mono whitespace-pre-wrap break-all">{embedSnippet}</pre>
          <button onClick={() => copy(embedSnippet, 'Embed snippet copied.')} className="mt-3 flex items-center gap-2 px-4 py-2.5 bg-slate-900 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors">
            <Copy className="w-3.5 h-3.5" /> Copy embed code
          </button>
        </section>

        {/* Caption templates */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4 flex items-center gap-2">
            <Sparkles className="w-4 h-4 text-[#026cdf]" /> Caption templates
          </h2>
          <p className="text-sm text-slate-600 mb-4">Copy-and-post for Instagram, TikTok, or X.</p>
          <div className="space-y-3">
            {captions.map((c, i) => (
              <div key={i} className="flex items-start gap-2 bg-slate-50 border border-slate-100 rounded-xl p-3">
                <p className="flex-1 text-sm text-slate-700">{c}</p>
                <button onClick={() => copy(c, 'Caption copied.')} aria-label="Copy caption" className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors shrink-0">
                  <Copy className="w-4 h-4" />
                </button>
              </div>
            ))}
          </div>
        </section>

        {/* Amplify: pixels + socials */}
        <section className="bg-gradient-to-r from-indigo-50 to-purple-50 border border-indigo-200 rounded-2xl p-6">
          <h2 className="text-[11px] font-black text-indigo-900 uppercase tracking-[0.2em] mb-2">Amplify &amp; measure</h2>
          {org?.marketing?.socials && Object.values(org.marketing.socials).some(Boolean) ? (
            <div className="mb-3">
              <p className="text-xs text-indigo-700 mb-2">Your storefront socials:</p>
              <SocialLinks socials={org.marketing.socials} className="flex items-center gap-4" />
            </div>
          ) : null}
          <p className="text-sm text-indigo-700 mb-4">
            Add your Meta / GA4 / TikTok pixel and social handles so paid promotion is tracked and your
            storefront links out to your channels.
          </p>
          {org ? (
            <Link to={`/orgs/${org.id}/settings`} className="inline-flex items-center gap-2 px-4 py-2.5 bg-indigo-600 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-indigo-700 transition-colors">
              <Settings className="w-3.5 h-3.5" /> Marketing &amp; socials
            </Link>
          ) : null}
        </section>
      </div>

      <ShareModal
        open={shareOpen}
        onClose={() => setShareOpen(false)}
        title={event.title}
        url={url}
      />
    </div>
  );
}
