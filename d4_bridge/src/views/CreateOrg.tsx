// CreateOrg — single-form view that mints a new Organization for the
// current user. The first writeBatch creates the org doc, the slug
// reservation, and the bootstrap owner membership atomically.
//
// On success: refreshes OrganizationContext, sets the new org active,
// and routes to /dashboard so the user can immediately create an event.

import { FormEvent, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion } from 'motion/react';
import { ArrowLeft, Check } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { createOrganization, isValidOrgSlug, slugify } from '../lib/orgs';

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1.5';
const INP =
  'w-full bg-slate-50 border border-slate-200 rounded-lg px-3.5 py-2.5 text-sm text-slate-900 placeholder:text-slate-300 focus:outline-none focus:border-tm-blue focus:ring-2 focus:ring-tm-blue/15 transition-colors';

export default function CreateOrg() {
  const { user, openAuthModal } = useAuth();
  const { refresh, setActiveOrg } = useOrganization();
  const { toast } = useToast();
  const navigate = useNavigate();

  const [name, setName] = useState('');
  const [slug, setSlug] = useState('');
  const [slugManuallyEdited, setSlugManuallyEdited] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  // Auto-derive slug from name unless the user has typed something
  // custom in the slug field.
  useEffect(() => {
    if (!slugManuallyEdited) {
      setSlug(slugify(name));
    }
  }, [name, slugManuallyEdited]);

  if (!user) {
    return (
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-3xl mx-auto px-4 py-24 text-center">
          <span className="marker text-brand-secondary text-lg inline-block rotate-[-3deg] mb-3">hold up ✦</span>
          <h2 className="text-3xl font-bold tracking-tight mb-6">Sign in to create an org</h2>
          <button
            onClick={openAuthModal}
            className="bg-tm-blue text-white px-7 py-3 rounded font-bold text-sm hover:bg-[#015bbd] shadow-sm transition-colors"
          >
            Sign In
          </button>
        </div>
      </div>
    );
  }

  const slugError = slug.length > 0 && !isValidOrgSlug(slug)
    ? 'Slug must be lowercase letters, numbers, and dashes (max 80 chars).'
    : null;
  const slugAvailable = slug.length > 0 && isValidOrgSlug(slug);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!user) return;
    if (name.trim().length === 0 || name.length > 100) {
      toast({ kind: 'error', message: 'Org name is required (max 100 chars).' });
      return;
    }
    if (!isValidOrgSlug(slug)) {
      toast({ kind: 'error', message: slugError || 'Invalid slug.' });
      return;
    }
    setSubmitting(true);
    try {
      const { orgId } = await createOrganization({
        name: name.trim(),
        slug,
        ownerUid: user.uid,
      });
      await refresh();
      setActiveOrg(orgId);
      toast({ kind: 'success', message: `Created ${name}.` });
      navigate('/dashboard');
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to create org';
      // Slug collision is the most common failure here — the
      // slugs/{slug} doc rule is `allow update: if false`, so a second
      // creator gets a permission-denied which Firebase surfaces as a
      // generic write error. Detect on message shape.
      if (/permission|denied|already/i.test(msg)) {
        toast({
          kind: 'error',
          message: `Slug "${slug}" is taken. Try a different one.`,
        });
      } else {
        toast({ kind: 'error', message: msg });
      }
    } finally {
      setSubmitting(false);
    }
  }

  const avatarLetter = (name.trim()[0] || '?').toUpperCase();

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="min-h-screen bg-tm-gray text-slate-900"
    >
      <div className="max-w-2xl mx-auto px-4 py-12">
        <button
          onClick={() => navigate('/orgs')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors"
        >
          <ArrowLeft size={14} strokeWidth={2.5} /> Orgs
        </button>

        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Team · Setup</p>
        <span className="inline-flex items-baseline gap-3 flex-wrap mb-1">
          <h1 className="text-3xl md:text-4xl font-bold tracking-tight">New organization</h1>
          <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">new crew ✦</span>
        </span>
        <p className="text-slate-500 text-sm mb-8 max-w-prose">
          An org owns events and inventory. Multiple staff can share access via
          roles (owner, manager, finance, scanner, content). You'll start as the
          owner; you can invite others after.
        </p>

        <form onSubmit={handleSubmit}>
          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-6">
            <div className="flex items-center gap-4">
              <div
                className="w-16 h-16 flex items-center justify-center font-black text-black text-2xl shrink-0"
                style={{ background: '#00FF00' }}
                aria-hidden
              >
                {avatarLetter}
              </div>
              <div className="flex-1">
                <label htmlFor="org-name" className={LBL}>
                  Organization name *
                </label>
                <input
                  id="org-name"
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  maxLength={100}
                  required
                  placeholder="Brooklyn Steel"
                  className={INP}
                />
              </div>
            </div>

            <div>
              <label htmlFor="org-slug" className={LBL}>
                Public handle *
              </label>
              <div className="flex items-center gap-0">
                <span className="text-sm text-slate-400 bg-slate-100 border border-r-0 border-slate-200 rounded-l-lg px-3 py-2.5 font-mono whitespace-nowrap">
                  exos.live/o/
                </span>
                <input
                  id="org-slug"
                  type="text"
                  value={slug}
                  onChange={(e) => {
                    setSlug(e.target.value);
                    setSlugManuallyEdited(true);
                  }}
                  maxLength={80}
                  required
                  placeholder="brooklyn-steel"
                  className={`${INP} rounded-l-none`}
                  style={{ borderRadius: '0 .5rem .5rem 0' }}
                />
              </div>
              {slugError ? (
                <p className="text-[11px] text-rose-500 mt-1.5 font-semibold">{slugError}</p>
              ) : slugAvailable ? (
                <p className="text-[11px] text-emerald-600 mt-1.5 font-semibold flex items-center gap-1">
                  <Check size={13} strokeWidth={3} /> Available
                </p>
              ) : (
                <p className="text-[11px] text-slate-400 mt-1.5">
                  Lowercase letters, numbers, and dashes. Becomes your storefront URL when white-label ships.
                </p>
              )}
            </div>
          </div>

          <div className="flex items-center gap-3 mt-6">
            <button
              type="submit"
              disabled={submitting || !name.trim() || !isValidOrgSlug(slug)}
              className="bg-tm-blue text-white px-7 py-3 rounded font-bold text-sm hover:bg-[#015bbd] shadow-sm transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {submitting ? 'Creating…' : 'Create organization'}
            </button>
            <button
              type="button"
              onClick={() => navigate('/orgs')}
              className="px-5 py-3 rounded font-bold text-sm text-slate-500 hover:text-slate-900 transition-colors"
            >
              Cancel
            </button>
            <span className="ml-auto text-[11px] text-slate-400 hidden sm:inline">you can change all of this later</span>
          </div>
        </form>
      </div>
    </motion.div>
  );
}
