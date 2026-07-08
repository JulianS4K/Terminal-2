// OrgSettings — owner-only view for org metadata. Sprint 1 surfaces
// just name + slug; Sprint 2 will add the white-label theme block,
// Sprint 3 the Stripe Connect onboarding link, Sprint 4 the Lysted
// distribution credentials.
//
// Slug renames go through a 3-step batch: delete old `slugs/{old}`,
// create new `slugs/{new}`, update `orgs/{id}.slug`. Skipped from this
// minimal cut — owners can rename an org's name freely; slug renaming
// is deferred until the white-label sprint.

import { ChangeEvent, useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { ArrowLeft, Upload } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { publicUrl } from '../lib/utils';
import { useToast } from '../context/ToastContext';
import { getOrganization, updateOrganization } from '../lib/orgs';
import { startStripeOnboarding } from '../lib/checkout';
import { uploadOrgLogo } from '../lib/orgLogo';
import { Organization } from '../types';
import DeveloperSettings from '../components/DeveloperSettings';

// Hex-color validator — same shape as the ThemeContext sanitizer.
// Mirrored here so we can give the user a fast field-level error
// instead of a rule-rejection at save time.
const HEX_COLOR = /^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/;

// Light "TM" form vocabulary (matches the OrgSettings mockup).
const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2';
const FLD =
  'w-full bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm text-slate-900 focus:outline-none focus:border-tm-blue transition-colors disabled:opacity-60 disabled:bg-slate-50';
const CARD = 'bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8';
const SECTION = 'text-sm font-black text-slate-900 uppercase tracking-widest';

export default function OrgSettings() {
  const { orgId } = useParams<{ orgId: string }>();
  const { user, isAdmin } = useAuth();
  const { activeRole } = useOrganization();
  const { toast } = useToast();
  const navigate = useNavigate();

  const [org, setOrg] = useState<Organization | null>(null);
  const [name, setName] = useState('');
  const [primaryColor, setPrimaryColor] = useState('');
  const [accentColor, setAccentColor] = useState('');
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const [marketing, setMarketing] = useState<NonNullable<Organization['marketing']>>({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [paymentsBusy, setPaymentsBusy] = useState(false);
  const [uploadingLogo, setUploadingLogo] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!orgId) return;
      setLoading(true);
      try {
        const o = await getOrganization(orgId);
        if (cancelled) return;
        setOrg(o);
        setName(o?.name ?? '');
        setPrimaryColor(o?.theme?.primaryColor ?? '');
        setAccentColor(o?.theme?.accentColor ?? '');
        setLogoUrl(o?.theme?.logoUrl ?? null);
        setMarketing(o?.marketing ?? {});
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [orgId]);

  if (!user) {
    return (
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-3xl mx-auto px-4 py-24 text-center text-slate-500 font-bold uppercase tracking-widest">
          Sign in required.
        </div>
      </div>
    );
  }
  if (loading) {
    return (
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-3xl mx-auto px-4 py-24 text-center text-slate-400 font-black uppercase tracking-[0.3em] animate-pulse">
          Loading…
        </div>
      </div>
    );
  }
  if (!org) {
    return (
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-3xl mx-auto px-4 py-24 text-center text-slate-500 font-bold uppercase tracking-widest">
          Org not found.
        </div>
      </div>
    );
  }

  // Gate: only the org's owner (or platform admin) can mutate. Read
  // path is permissive in the rules so the page renders for anyone
  // who can already see the org — but the form is only enabled for
  // owners.
  const canEdit = isAdmin || activeRole === 'owner';
  // Paid ticketing is gated on the Stripe publishable key — the Connect
  // onboarding backend (exos-connect-onboard) is built but dormant until set.
  const stripeEnabled = !!(import.meta as { env?: { VITE_STRIPE_PUBLISHABLE_KEY?: string } }).env?.VITE_STRIPE_PUBLISHABLE_KEY;

  const handleSetupPayments = async () => {
    if (!orgId || !canEdit) return;
    setPaymentsBusy(true);
    try {
      const url = await startStripeOnboarding({
        orgId,
        returnUrl: publicUrl(`orgs/${orgId}/settings`),
        refreshUrl: publicUrl(`orgs/${orgId}/settings`),
      });
      window.location.href = url;
    } catch (err: unknown) {
      console.error('Stripe onboarding failed:', err);
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Payments are not enabled yet.' });
    } finally {
      setPaymentsBusy(false);
    }
  };

  async function handleSave() {
    if (!org) return;
    if (!canEdit) return;
    if (name.trim().length === 0 || name.length > 100) {
      toast({ kind: 'error', message: 'Org name is required (max 100 chars).' });
      return;
    }
    // Field-level validation for theme colors. Empty is fine (clears
    // the override → ThemeContext falls back to platform default).
    if (primaryColor && !HEX_COLOR.test(primaryColor)) {
      toast({ kind: 'error', message: 'Primary color must be a hex like #ffe714.' });
      return;
    }
    if (accentColor && !HEX_COLOR.test(accentColor)) {
      toast({ kind: 'error', message: 'Accent color must be a hex like #1a1a1a.' });
      return;
    }
    setSaving(true);
    try {
      // Build the theme block conditionally — Firestore rejects undefined
      // values on update. We send the full theme object so cleared
      // fields are removed from the doc, not just left stale.
      const theme: NonNullable<Organization['theme']> = {};
      if (primaryColor) theme.primaryColor = primaryColor;
      if (accentColor) theme.accentColor = accentColor;
      if (logoUrl) theme.logoUrl = logoUrl;
      await updateOrganization(org.id, {
        name: name.trim(),
        theme,
        marketing,
      });
      toast({ kind: 'success', message: 'Saved.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Save failed';
      toast({ kind: 'error', message: msg });
    } finally {
      setSaving(false);
    }
  }

  async function handleLogoUpload(e: ChangeEvent<HTMLInputElement>) {
    if (!org) return;
    if (!canEdit) return;
    const file = e.target.files?.[0];
    if (!file) return;
    setUploadingLogo(true);
    try {
      const url = await uploadOrgLogo(org.id, file);
      setLogoUrl(url);
      // Persist immediately so the storefront updates without a separate
      // Save click. Build the theme object with only DEFINED values —
      // Firestore client-side validation rejects literal `undefined` in
      // any field. Empty-string colors mean "use the default" so we just
      // omit the key entirely, which lets the theme inherit from prior
      // saves (or fall through to platform defaults).
      const theme: NonNullable<Organization['theme']> = { logoUrl: url };
      if (primaryColor) theme.primaryColor = primaryColor;
      if (accentColor) theme.accentColor = accentColor;
      await updateOrganization(org.id, { theme });
      toast({ kind: 'success', message: 'Logo uploaded.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Upload failed';
      toast({ kind: 'error', message: msg });
    } finally {
      setUploadingLogo(false);
      // Reset the input so re-selecting the same file fires onChange.
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  }

  // Generate the embed snippet that venues paste on their own site.
  // The snippet is a tiny self-resizing iframe with a postMessage
  // listener for height updates from EmbedEvent.tsx. The host gets
  // a copy-paste-ready string they can drop into WordPress, Wix,
  // Squarespace, or a hand-written site.
  function buildEmbedSnippet(orgIdValue: string): string {
    const origin = window.location.origin;
    return `<!-- Exos embed for ${orgIdValue}. Replace EVENT_ID with your event id. -->
<iframe id="vibepass-embed" src="${publicUrl('embed/event/EVENT_ID')}" style="width:100%;border:0;min-height:200px" loading="lazy" title="Tickets"></iframe>
<script>
window.addEventListener('message', function(e) {
  if (e.origin !== '${origin}') return;
  if (e.data && e.data.type === 'vibepass:resize') {
    var f = document.getElementById('vibepass-embed');
    if (f) f.style.height = e.data.height + 'px';
  }
});
</script>`;
  }

  const previewColor = HEX_COLOR.test(primaryColor) ? primaryColor : '#00FF00';

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="min-h-screen bg-tm-gray text-slate-900"
    >
      <div className="max-w-5xl mx-auto px-4 py-10">
        <button
          onClick={() => navigate('/orgs')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors"
        >
          <ArrowLeft size={14} strokeWidth={2.5} /> All organizations
        </button>

        <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-8">
          <div>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Organization</p>
            <span className="inline-flex items-baseline gap-3 flex-wrap">
              <h1 className="text-3xl md:text-4xl font-bold tracking-tight">{org.name}</h1>
              <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">white-label ✦</span>
            </span>
            <p className="text-slate-500 text-sm mt-2">exos.live/o/{org.slug}</p>
          </div>
          {canEdit && (
            <button
              onClick={handleSave}
              disabled={saving}
              className="bg-tm-blue text-white px-6 py-3 rounded font-bold text-sm hover:bg-[#015bbd] shadow-sm transition-colors disabled:opacity-50 shrink-0"
            >
              {saving ? 'Saving…' : 'Save changes'}
            </button>
          )}
        </div>

        {/* Tabs */}
        <div className="flex gap-6 border-b border-slate-200 mb-8">
          <button className="pb-3 text-sm font-bold text-slate-900 border-b-2 border-tm-blue -mb-px">General</button>
          <button
            onClick={() => navigate(`/orgs/${org.id}/members`)}
            className="pb-3 text-sm font-bold text-slate-400 hover:text-slate-600 transition-colors"
          >
            Members
          </button>
          <span className="pb-3 text-sm font-bold text-slate-300 cursor-default">Billing</span>
        </div>

        {!canEdit && (
          <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 mb-6 text-amber-700 text-xs font-bold uppercase tracking-widest">
            You're a {activeRole ?? 'guest'} — only owners can change org settings.
          </div>
        )}

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-6">
            {/* Profile */}
            <div className={CARD}>
              <h2 className={`${SECTION} mb-6`}>Profile</h2>
              <div>
                <label htmlFor="org-name" className={LBL}>Org Name</label>
                <input
                  id="org-name"
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  disabled={!canEdit}
                  maxLength={100}
                  className={FLD}
                />
              </div>
            </div>

            {/*
              White-label theme block. Sprint 2: logo + two colors. The
              theme is applied via ThemeContext on org-scoped surfaces
              (/o/:slug, EventDetails for events whose orgId resolves to
              this org). Platform shell (Home, MyTickets, etc.) stays
              neutral so the buyer's "across all events" surfaces don't
              retint as they navigate.
            */}
            <div className={CARD}>
              <h2 className={`${SECTION} mb-2`}>White-label theme</h2>
              <p className="text-xs text-slate-400 mb-6">
                Applied to your storefront (exos.live/o/{org.slug}) and event pages hosted by this org. Platform shell stays neutral.
              </p>

              <div className="mb-6">
                <label className={LBL}>Logo</label>
                <div className="flex items-center gap-4">
                  {logoUrl ? (
                    <img
                      src={logoUrl}
                      alt="Org logo"
                      className="w-16 h-16 object-contain bg-slate-50 border border-slate-200 rounded-lg p-2"
                    />
                  ) : (
                    <div className="w-16 h-16 bg-slate-900 rounded-lg flex items-center justify-center text-white font-black italic text-xl">
                      {org.name.charAt(0).toUpperCase()}
                    </div>
                  )}
                  <div>
                    <input
                      ref={fileInputRef}
                      id="org-logo-upload"
                      type="file"
                      accept="image/png,image/jpeg,image/webp,image/svg+xml"
                      onChange={handleLogoUpload}
                      disabled={!canEdit || uploadingLogo}
                      className="hidden"
                    />
                    <label
                      htmlFor="org-logo-upload"
                      className={`inline-flex items-center gap-2 px-4 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest transition-colors ${
                        canEdit && !uploadingLogo
                          ? 'text-tm-blue hover:border-tm-blue cursor-pointer'
                          : 'text-slate-300 opacity-60 cursor-not-allowed'
                      }`}
                    >
                      <Upload size={12} />
                      {uploadingLogo ? 'Uploading…' : logoUrl ? 'Replace' : 'Upload'}
                    </label>
                    <p className="text-slate-400 text-xs mt-2">PNG, JPG, WebP, or SVG. Max 2 MB.</p>
                  </div>
                </div>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-6">
                <div>
                  <label htmlFor="org-primary" className={LBL}>Primary color</label>
                  <div className="flex items-center gap-2">
                    <input
                      id="org-primary"
                      type="text"
                      value={primaryColor}
                      onChange={(e) => setPrimaryColor(e.target.value)}
                      disabled={!canEdit}
                      placeholder="#FFE714"
                      maxLength={7}
                      className={`${FLD} flex-1 font-mono`}
                    />
                    <div
                      aria-hidden
                      className="w-11 h-11 rounded-lg border border-slate-200 shrink-0"
                      style={{ background: HEX_COLOR.test(primaryColor) ? primaryColor : '#f1f5f9' }}
                    />
                  </div>
                </div>
                <div>
                  <label htmlFor="org-accent" className={LBL}>Accent color</label>
                  <div className="flex items-center gap-2">
                    <input
                      id="org-accent"
                      type="text"
                      value={accentColor}
                      onChange={(e) => setAccentColor(e.target.value)}
                      disabled={!canEdit}
                      placeholder="#1A1A1A"
                      maxLength={7}
                      className={`${FLD} flex-1 font-mono`}
                    />
                    <div
                      aria-hidden
                      className="w-11 h-11 rounded-lg border border-slate-200 shrink-0"
                      style={{ background: HEX_COLOR.test(accentColor) ? accentColor : '#f1f5f9' }}
                    />
                  </div>
                </div>
              </div>

              {/* Live storefront preview — bound to the real theme fields. */}
              <div className="mt-6">
                <p className={LBL}>Storefront preview</p>
                <div className="rounded-xl overflow-hidden border border-slate-200">
                  <div className="bg-black px-5 py-4 flex items-center justify-between">
                    <span className="text-white font-black italic text-lg truncate">
                      {org.name.charAt(0).toUpperCase()} · {org.name.toUpperCase()}
                    </span>
                    <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: previewColor }}>Events</span>
                  </div>
                  <div className="bg-[#0a0a0a] p-5 grid grid-cols-3 gap-3">
                    <div className="aspect-[3/4] bg-[#1a1a1a] relative">
                      <span className="absolute bottom-1 left-1 text-white text-[9px] font-black">EVENT</span>
                      <span className="absolute top-1 right-1 text-[9px] font-black" style={{ color: previewColor }}>$30</span>
                    </div>
                    <div className="aspect-[3/4] bg-[#1a1a1a]" />
                    <div className="aspect-[3/4] bg-[#1a1a1a]" />
                  </div>
                </div>
              </div>
            </div>

            {/* Marketing & socials */}
            <div className={CARD}>
              <h2 className={`${SECTION} mb-2`}>Marketing &amp; socials</h2>
              <p className="text-xs text-slate-400 mb-5">
                Social handles + tracking pixel IDs (public IDs only — no secrets).
                Handles show on your storefront; pixels load on your public pages
                after a visitor accepts cookies.
              </p>
              <div className="grid grid-cols-2 gap-3 mb-4">
                {(([['Instagram','instagram'],['Facebook','facebook'],['TikTok','tiktok'],['X','x'],['Website','website']]) as readonly (readonly ['Instagram'|'Facebook'|'TikTok'|'X'|'Website', 'instagram'|'facebook'|'tiktok'|'x'|'website'])[]).map(([label, key]) => (
                  <label key={key} className="block">
                    <span className="text-[10px] text-slate-400 uppercase tracking-widest">{label}</span>
                    <input
                      type="text"
                      className={`${FLD} mt-1`}
                      value={marketing.socials?.[key] ?? ''}
                      onChange={(e) => setMarketing((m) => ({ ...m, socials: { ...m.socials, [key]: e.target.value } }))}
                      disabled={!canEdit}
                      placeholder={label}
                    />
                  </label>
                ))}
              </div>
              <div className="grid grid-cols-3 gap-3">
                {(([['Meta Pixel','meta','000000000000000'],['GA4','ga4','G-XXXXXXXXXX'],['TikTok Pixel','tiktok','CXXXXXXXXXXXXXXXXXXX']]) as readonly (readonly [string, 'meta'|'ga4'|'tiktok', string])[]).map(([label, key, hint]) => (
                  <label key={key} className="block">
                    <span className="text-[10px] text-slate-400 uppercase tracking-widest">{label}</span>
                    <input
                      type="text"
                      className={`${FLD} mt-1`}
                      value={marketing.pixels?.[key] ?? ''}
                      onChange={(e) => setMarketing((m) => ({ ...m, pixels: { ...m.pixels, [key]: e.target.value } }))}
                      disabled={!canEdit}
                      placeholder={hint}
                    />
                  </label>
                ))}
              </div>
            </div>

            {/*
              Embed snippet — venues paste this on their own website to
              render an event-card iframe. The snippet has a EVENT_ID
              placeholder; the host swaps in the real event id after
              they create the event. Paired with EmbedEvent.tsx and the
              /embed/event/:eventId route.
            */}
            <div className={CARD}>
              <h2 className={`${SECTION} mb-2`}>Embed on your website</h2>
              <p className="text-xs text-slate-400 mb-4">
                Paste this snippet on your venue's site (WordPress, Wix, Squarespace,
                or any HTML page). Replace <code className="text-tm-blue font-mono">EVENT_ID</code>{' '}
                with your event's id from the dashboard. The iframe self-resizes.
              </p>
              <textarea
                readOnly
                value={buildEmbedSnippet(org.id)}
                onClick={(e) => (e.target as HTMLTextAreaElement).select()}
                rows={9}
                className="w-full bg-slate-900 border border-slate-800 rounded-lg px-3 py-2 text-[11px] text-slate-100 font-mono whitespace-pre-wrap break-all focus:outline-none focus:border-tm-blue"
              />
              <button
                type="button"
                onClick={() => {
                  navigator.clipboard
                    .writeText(buildEmbedSnippet(org.id))
                    .then(() => toast({ kind: 'success', message: 'Snippet copied.' }))
                    .catch(() => toast({ kind: 'error', message: 'Copy failed — select and copy manually.' }));
                }}
                className="mt-3 px-4 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:border-tm-blue hover:text-tm-blue transition-colors"
              >
                Copy snippet
              </button>
            </div>

            {/* Developer — API keys + outbound webhooks (self-contained CRUD). */}
            <DeveloperSettings orgId={org.id} canEdit={canEdit} />
          </div>

          {/* Sidebar */}
          <div className="space-y-6">
            {/* Payments */}
            <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6">
              <h2 className={`${SECTION} mb-3`}>Payments</h2>
              <p className="text-xs text-slate-400 mb-4">
                Connect Stripe to sell paid tickets — payouts go to your account and the
                platform takes a fee. Free events need nothing here.
              </p>
              {stripeEnabled ? (
                <button
                  type="button"
                  onClick={handleSetupPayments}
                  disabled={!canEdit || paymentsBusy}
                  className="w-full border border-slate-200 rounded py-2.5 text-slate-700 text-[10px] font-black uppercase tracking-widest hover:border-tm-blue hover:text-tm-blue transition-colors disabled:opacity-50"
                >
                  {paymentsBusy ? 'Opening Stripe…' : 'Set up payments'}
                </button>
              ) : (
                <p className="text-[10px] text-slate-400 uppercase tracking-widest">
                  Paid ticketing isn't enabled yet — coming soon.
                </p>
              )}
            </div>

            {/* Meta info */}
            <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 text-xs text-slate-500 space-y-2">
              <div>
                <span className="font-black uppercase tracking-widest text-slate-400">Slug:</span>{' '}
                {org.slug} (rename in a future sprint)
              </div>
              <div>
                <span className="font-black uppercase tracking-widest text-slate-400">Owner:</span>{' '}
                <span className="font-mono break-all">{org.ownerUid}</span>
              </div>
              <div>
                <span className="font-black uppercase tracking-widest text-slate-400">Stripe Connect:</span>{' '}
                {org.payments?.connectedAccountId ? 'Connected' : 'Not connected (Sprint 3)'}
              </div>
              <div>
                <span className="font-black uppercase tracking-widest text-slate-400">Distribution:</span>{' '}
                {org.distribution?.enabled ? 'Lysted enabled' : 'Lysted not enabled (Sprint 4)'}
              </div>
            </div>
          </div>
        </div>
      </div>
    </motion.div>
  );
}
