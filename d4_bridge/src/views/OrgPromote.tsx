// OrgPromote — venue-wide promotion hub for one organization.
//
// Lives at /orgs/:orgId/promote (linked from the dashboard + the Orgs list).
// Where the per-event Promote page pushes a single event, this promotes the
// VENUE: its public storefront (all events), a poster QR for it, share tools,
// the socials/pixels setup, and a jump into each event's own promote page.

import { useEffect, useMemo, useRef, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { QRCodeCanvas } from 'qrcode.react';
import {
  ArrowLeft, Megaphone, Copy, Download, Share2, ExternalLink, Settings,
  Sparkles, Calendar,
} from 'lucide-react';
import { getOrganization } from '../lib/orgs';
import { listOrgEvents } from '../lib/events';
import { Event, Organization } from '../types';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { publicUrl } from '../lib/utils';
import { formatInTz } from '../lib/datetime';
import ShareModal from '../components/ShareModal';
import SocialLinks from '../components/SocialLinks';

export default function OrgPromote() {
  const { orgId } = useParams();
  const { user } = useAuth();
  const { toast } = useToast();
  const [org, setOrg] = useState<Organization | null>(null);
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [shareOpen, setShareOpen] = useState(false);
  const qrWrapRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!orgId) { setLoading(false); return; }
      setLoading(true);
      try {
        const [o, evs] = await Promise.all([
          getOrganization(orgId),
          listOrgEvents(orgId).catch(() => [] as Event[]),
        ]);
        if (cancelled) return;
        setOrg(o);
        setEvents(evs);
      } catch (err) {
        console.error('Failed to load org promote hub:', err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    void load();
    return () => { cancelled = true; };
  }, [orgId]);

  const storefrontUrl = org?.slug ? publicUrl(`o/${org.slug}`) : '';
  const publishedCount = useMemo(
    () => events.filter((e) => (e.status ?? 'published') === 'published').length,
    [events],
  );

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
    a.download = `qr-${org?.slug || 'venue'}.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    toast({ kind: 'success', message: 'QR downloaded.' });
  };

  if (!user) {
    return <div className="max-w-3xl mx-auto p-20 text-center text-slate-500">Sign in to promote your venue.</div>;
  }
  if (loading) {
    return <div className="max-w-3xl mx-auto p-20 text-center text-slate-300 font-bold uppercase tracking-widest text-xs">Loading…</div>;
  }
  if (!org) {
    return (
      <div className="max-w-3xl mx-auto p-20 text-center">
        <p className="text-slate-400 font-bold uppercase tracking-widest text-[10px] mb-4">Venue not found</p>
        <Link to="/orgs" className="text-[#026cdf] font-bold text-sm">Back to organizations</Link>
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
          <h1 className="text-3xl font-bold tracking-tight text-slate-900">Promote {org.name}</h1>
        </div>
        <p className="text-slate-500 text-sm mb-8">
          Your venue storefront lists every published event in one branded page.
        </p>

        {/* Storefront link */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4 flex items-center gap-2">
            <Share2 className="w-4 h-4 text-[#026cdf]" /> Your storefront
          </h2>
          <div className="flex items-center gap-2 mb-4">
            <input
              readOnly
              value={storefrontUrl}
              aria-label="Storefront link"
              onFocus={(e) => e.currentTarget.select()}
              className="flex-1 bg-slate-50 border border-slate-200 rounded-xl px-4 py-3 text-sm font-mono text-slate-700 truncate"
            />
            <button onClick={() => copy(storefrontUrl, 'Storefront link copied.')} className="px-4 py-3 bg-slate-900 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors flex items-center gap-2">
              <Copy className="w-3.5 h-3.5" /> Copy
            </button>
          </div>
          <div className="flex flex-wrap gap-2">
            <button onClick={() => setShareOpen(true)} className="flex items-center gap-2 px-4 py-2.5 bg-[#026cdf] text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-[#015bbd] transition-colors">
              <Share2 className="w-3.5 h-3.5" /> Share…
            </button>
            <a href={storefrontUrl} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2 px-4 py-2.5 bg-white border border-slate-200 text-slate-700 rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-50 transition-colors">
              <ExternalLink className="w-3.5 h-3.5" /> Preview
            </a>
          </div>
        </section>

        {/* QR */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm mb-6">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4">Storefront QR</h2>
          <div className="flex items-center gap-6 flex-wrap">
            <div ref={qrWrapRef} className="p-4 bg-white border border-slate-200 rounded-2xl">
              <QRCodeCanvas value={storefrontUrl || org.slug} size={160} level="M" includeMargin />
            </div>
            <div className="flex-1 min-w-[200px]">
              <p className="text-sm text-slate-600 mb-4">Put it on posters at the door or around town — it opens your full event list.</p>
              <button onClick={downloadQr} className="flex items-center gap-2 px-4 py-2.5 bg-slate-900 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors">
                <Download className="w-3.5 h-3.5" /> Download PNG
              </button>
            </div>
          </div>
        </section>

        {/* Socials + pixels */}
        <section className="bg-gradient-to-r from-indigo-50 to-purple-50 border border-indigo-200 rounded-2xl p-6 mb-6">
          <h2 className="text-[11px] font-black text-indigo-900 uppercase tracking-[0.2em] mb-2 flex items-center gap-2">
            <Sparkles className="w-4 h-4" /> Socials &amp; pixels
          </h2>
          {org.marketing?.socials && Object.values(org.marketing.socials).some(Boolean) ? (
            <div className="mb-3">
              <p className="text-xs text-indigo-700 mb-2">Showing on your storefront:</p>
              <SocialLinks socials={org.marketing.socials} className="flex items-center gap-4" />
            </div>
          ) : (
            <p className="text-sm text-indigo-700 mb-4">Add your social handles and ad pixels so your storefront links out and paid promotion is measurable.</p>
          )}
          <Link to={`/orgs/${org.id}/settings`} className="inline-flex items-center gap-2 px-4 py-2.5 bg-indigo-600 text-white rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-indigo-700 transition-colors">
            <Settings className="w-3.5 h-3.5" /> Marketing &amp; socials
          </Link>
        </section>

        {/* Per-event promote */}
        <section className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm">
          <h2 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em] mb-4 flex items-center gap-2">
            <Calendar className="w-4 h-4 text-[#026cdf]" /> Promote a specific event
          </h2>
          {events.length === 0 ? (
            <p className="text-sm text-slate-500">No events yet. <Link to="/create-event" className="text-[#026cdf] font-bold">Create one</Link> to start promoting.</p>
          ) : (
            <>
              <p className="text-sm text-slate-600 mb-4">{publishedCount} published · {events.length} total. Open an event's promote kit for campaign links, QR, embed, and captions.</p>
              <div className="space-y-2">
                {events.map((ev) => (
                  <Link
                    key={ev.id}
                    to={`/dashboard/event/${ev.id}/promote`}
                    className="flex items-center justify-between bg-slate-50 border border-slate-100 rounded-xl px-4 py-3 hover:border-[#026cdf] transition-colors group"
                  >
                    <div className="min-w-0">
                      <p className="font-bold text-slate-900 text-sm truncate">{ev.title}</p>
                      <p className="text-[10px] text-slate-400 uppercase tracking-widest">
                        {ev.date ? formatInTz(ev.date.toDate(), ev.timezone, { month: 'short', day: 'numeric', year: 'numeric' }) : '—'}
                      </p>
                    </div>
                    <span className="flex items-center gap-1 text-[10px] font-black uppercase tracking-widest text-slate-400 group-hover:text-[#026cdf] shrink-0">
                      <Megaphone className="w-3.5 h-3.5" /> Promote
                    </span>
                  </Link>
                ))}
              </div>
            </>
          )}
        </section>
      </div>

      <ShareModal
        open={shareOpen}
        onClose={() => setShareOpen(false)}
        title={org.name}
        url={storefrontUrl}
        text={`Check out events from ${org.name}`}
      />
    </div>
  );
}
