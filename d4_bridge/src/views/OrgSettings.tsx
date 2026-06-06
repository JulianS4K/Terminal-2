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

// Hex-color validator — same shape as the ThemeContext sanitizer.
// Mirrored here so we can give the user a fast field-level error
// instead of a rule-rejection at save time.
const HEX_COLOR = /^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/;

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
      <div className="max-w-3xl mx-auto p-12 text-center text-white/60 font-bold uppercase tracking-widest">
        Sign in required.
      </div>
    );
  }
  if (loading) {
    return (
      <div className="max-w-3xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }
  if (!org) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center text-white/60 font-bold uppercase tracking-widest">
        Org not found.
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

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-2xl mx-auto p-6 md:p-12"
    >
      <button
        onClick={() => navigate('/orgs')}
        className="flex items-center gap-2 text-white/40 hover:text-white text-[10px] font-black uppercase tracking-widest mb-6 transition-all"
      >
        <ArrowLeft size={14} /> Back to orgs
      </button>

      <h1 className="text-4xl md:text-5xl font-black uppercase italic tracking-tighter text-white mb-2">
        {org.name}
      </h1>
      <p className="text-white/50 text-sm mb-10">
        Settings · /o/{org.slug}
      </p>

      {!canEdit && (
        <div className="bg-yellow-500/10 border border-yellow-500/30 p-4 mb-6 text-yellow-400 text-xs font-bold uppercase tracking-widest">
          You're a {activeRole ?? 'guest'} — only owners can change org settings.
        </div>
      )}

      <div className="space-y-6">
        <div>
          <label htmlFor="org-name" className="block text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">
            Org Name
          </label>
          <input
            id="org-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            disabled={!canEdit}
            maxLength={100}
            className="w-full bg-white/5 border border-white/10 px-4 py-3 text-white font-bold focus:border-brand-primary focus:outline-none disabled:opacity-50 transition-all"
          />
        </div>

        {/*
          White-label theme block. Sprint 2: logo + two colors. The
          theme is applied via ThemeContext on org-scoped surfaces
          (/o/:slug, EventDetails for events whose orgId resolves to
          this org). Platform shell (Home, MyTickets, etc.) stays
          neutral so the buyer's "across all events" surfaces don't
          retint as they navigate.
        */}
        <fieldset className="border border-white/10 p-5 space-y-5">
          <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">
            Storefront Theme
          </legend>

          <div>
            <label className="block text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">
              Logo
            </label>
            <div className="flex items-center gap-4">
              {logoUrl ? (
                <img
                  src={logoUrl}
                  alt="Org logo"
                  className="w-20 h-20 object-contain bg-white/5 border border-white/10 p-2"
                />
              ) : (
                <div className="w-20 h-20 bg-white/5 border border-white/10 flex items-center justify-center text-white/30 text-[9px] font-black uppercase tracking-widest">
                  no logo
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
                  className={`inline-flex items-center gap-2 px-4 py-2 border border-white/10 text-[10px] font-black uppercase tracking-widest transition-all ${
                    canEdit && !uploadingLogo
                      ? 'bg-white/5 hover:bg-white/10 cursor-pointer'
                      : 'bg-white/5 opacity-50 cursor-not-allowed'
                  }`}
                >
                  <Upload size={12} />
                  {uploadingLogo ? 'Uploading…' : logoUrl ? 'Replace' : 'Upload'}
                </label>
                <p className="text-white/30 text-xs mt-2">PNG, JPG, WebP, or SVG. Max 2 MB.</p>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label htmlFor="org-primary" className="block text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">
                Primary color
              </label>
              <div className="flex items-center gap-2">
                <input
                  id="org-primary"
                  type="text"
                  value={primaryColor}
                  onChange={(e) => setPrimaryColor(e.target.value)}
                  disabled={!canEdit}
                  placeholder="#FFE714"
                  maxLength={7}
                  className="flex-1 bg-white/5 border border-white/10 px-3 py-2 text-sm text-white font-bold focus:border-brand-primary focus:outline-none disabled:opacity-50 transition-all"
                />
                <div
                  aria-hidden
                  className="w-10 h-10 border border-white/10"
                  style={{ background: HEX_COLOR.test(primaryColor) ? primaryColor : 'transparent' }}
                />
              </div>
            </div>
            <div>
              <label htmlFor="org-accent" className="block text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">
                Accent color
              </label>
              <div className="flex items-center gap-2">
                <input
                  id="org-accent"
                  type="text"
                  value={accentColor}
                  onChange={(e) => setAccentColor(e.target.value)}
                  disabled={!canEdit}
                  placeholder="#1A1A1A"
                  maxLength={7}
                  className="flex-1 bg-white/5 border border-white/10 px-3 py-2 text-sm text-white font-bold focus:border-brand-primary focus:outline-none disabled:opacity-50 transition-all"
                />
                <div
                  aria-hidden
                  className="w-10 h-10 border border-white/10"
                  style={{ background: HEX_COLOR.test(accentColor) ? accentColor : 'transparent' }}
                />
              </div>
            </div>
          </div>

          <p className="text-white/40 text-xs">
            Theme applies on storefront pages (/o/{org.slug}) and event pages
            for events under this org. Platform shell stays neutral.
          </p>
        </fieldset>

        <fieldset className="border border-white/10 p-5 space-y-3">
          <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">
            Marketing &amp; socials
          </legend>
          <p className="text-white/50 text-xs">
            Social handles + tracking pixel IDs (public IDs only — no secrets).
            Handles show on your storefront; pixels load on your public pages
            after a visitor accepts cookies.
          </p>
          <div className="grid grid-cols-2 gap-3">
            {(([['Instagram','instagram'],['Facebook','facebook'],['TikTok','tiktok'],['X','x'],['Website','website']]) as readonly (readonly ['Instagram'|'Facebook'|'TikTok'|'X'|'Website', 'instagram'|'facebook'|'tiktok'|'x'|'website'])[]).map(([label, key]) => (
              <label key={key} className="block">
                <span className="text-[10px] text-white/40 uppercase tracking-widest">{label}</span>
                <input
                  type="text"
                  className="w-full bg-white/5 border border-white/10 rounded px-3 py-2 text-white text-sm"
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
                <span className="text-[10px] text-white/40 uppercase tracking-widest">{label}</span>
                <input
                  type="text"
                  className="w-full bg-white/5 border border-white/10 rounded px-3 py-2 text-white text-sm"
                  value={marketing.pixels?.[key] ?? ''}
                  onChange={(e) => setMarketing((m) => ({ ...m, pixels: { ...m.pixels, [key]: e.target.value } }))}
                  disabled={!canEdit}
                  placeholder={hint}
                />
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className="border border-white/10 p-5 space-y-3">
          <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">
            Payments
          </legend>
          <p className="text-white/50 text-xs">
            Connect Stripe to sell paid tickets — payouts go to your account and the
            platform takes a fee. Free events need nothing here.
          </p>
          {stripeEnabled ? (
            <button
              type="button"
              onClick={handleSetupPayments}
              disabled={!canEdit || paymentsBusy}
              className="px-4 py-2 bg-white/5 hover:bg-white/10 border border-white/10 text-white text-[10px] font-black uppercase tracking-widest transition-all disabled:opacity-50"
            >
              {paymentsBusy ? 'Opening Stripe…' : 'Set up payments'}
            </button>
          ) : (
            <p className="text-[10px] text-white/30 uppercase tracking-widest">
              Paid ticketing isn't enabled yet — coming soon.
            </p>
          )}
        </fieldset>

        {/*
          Embed snippet — venues paste this on their own website to
          render an event-card iframe. The snippet has a EVENT_ID
          placeholder; the host swaps in the real event id after
          they create the event. Paired with EmbedEvent.tsx and the
          /embed/event/:eventId route.
        */}
        <fieldset className="border border-white/10 p-5 space-y-3">
          <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">
            Embed on your website
          </legend>
          <p className="text-white/50 text-xs">
            Paste this snippet on your venue's site (WordPress, Wix, Squarespace,
            or any HTML page). Replace <code className="text-brand-primary">EVENT_ID</code>{' '}
            with your event's id from the dashboard. The iframe self-resizes.
          </p>
          <textarea
            readOnly
            value={buildEmbedSnippet(org.id)}
            onClick={(e) => (e.target as HTMLTextAreaElement).select()}
            rows={9}
            className="w-full bg-black border border-white/10 px-3 py-2 text-[11px] text-white/80 font-mono whitespace-pre-wrap break-all focus:outline-none focus:border-brand-primary"
          />
          <button
            type="button"
            onClick={() => {
              navigator.clipboard
                .writeText(buildEmbedSnippet(org.id))
                .then(() => toast({ kind: 'success', message: 'Snippet copied.' }))
                .catch(() => toast({ kind: 'error', message: 'Copy failed — select and copy manually.' }));
            }}
            className="px-4 py-2 bg-white/5 hover:bg-white/10 text-[10px] font-black uppercase tracking-widest text-white/80 transition-all"
          >
            Copy snippet
          </button>
        </fieldset>

        <div className="bg-white/5 border border-white/10 p-4 text-xs text-white/50 space-y-1">
          <div>
            <span className="font-black uppercase tracking-widest text-white/30">Slug:</span>{' '}
            {org.slug} (rename in a future sprint)
          </div>
          <div>
            <span className="font-black uppercase tracking-widest text-white/30">Owner:</span>{' '}
            {org.ownerUid}
          </div>
          <div>
            <span className="font-black uppercase tracking-widest text-white/30">Stripe Connect:</span>{' '}
            {org.payments?.connectedAccountId ? 'Connected' : 'Not connected (Sprint 3)'}
          </div>
          <div>
            <span className="font-black uppercase tracking-widest text-white/30">Distribution:</span>{' '}
            {org.distribution?.enabled ? 'Lysted enabled' : 'Lysted not enabled (Sprint 4)'}
          </div>
        </div>

        {canEdit && (
          <button
            onClick={handleSave}
            disabled={saving}
            className="w-full px-8 py-4 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all disabled:opacity-50"
          >
            {saving ? 'Saving…' : 'Save'}
          </button>
        )}
      </div>
    </motion.div>
  );
}
