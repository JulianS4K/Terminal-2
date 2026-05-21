// CreateOrg — single-form view that mints a new Organization for the
// current user. The first writeBatch creates the org doc, the slug
// reservation, and the bootstrap owner membership atomically.
//
// On success: refreshes OrganizationContext, sets the new org active,
// and routes to /dashboard so the user can immediately create an event.

import { FormEvent, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion } from 'motion/react';
import { ArrowLeft } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { createOrganization, isValidOrgSlug, slugify } from '../lib/orgs';

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
      <div className="max-w-3xl mx-auto p-12 text-center">
        <h2 className="text-3xl font-black uppercase italic tracking-tighter text-white mb-4">
          Sign in to create an org
        </h2>
        <button
          onClick={openAuthModal}
          className="px-8 py-3 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all"
        >
          Sign In
        </button>
      </div>
    );
  }

  const slugError = slug.length > 0 && !isValidOrgSlug(slug)
    ? 'Slug must be lowercase letters, numbers, and dashes (max 80 chars).'
    : null;

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
        Create an Org
      </h1>
      <p className="text-white/50 text-sm mb-10 max-w-prose">
        An org owns events and inventory. Multiple staff can share access via
        roles (owner, manager, finance, scanner, content). You'll start as the
        owner; you can invite others after.
      </p>

      <form onSubmit={handleSubmit} className="space-y-6">
        <div>
          <label htmlFor="org-name" className="block text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">
            Org Name *
          </label>
          <input
            id="org-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={100}
            required
            placeholder="Brooklyn Steel"
            className="w-full bg-white/5 border border-white/10 px-4 py-3 text-white font-bold focus:border-brand-primary focus:outline-none transition-all"
          />
        </div>

        <div>
          <label htmlFor="org-slug" className="block text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">
            URL Slug *
          </label>
          <div className="flex">
            <span className="bg-white/5 border border-white/10 border-r-0 px-3 py-3 text-white/40 font-bold text-sm">
              /o/
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
              className="flex-1 bg-white/5 border border-white/10 px-4 py-3 text-white font-bold focus:border-brand-primary focus:outline-none transition-all"
            />
          </div>
          {slugError && <p className="text-red-400 text-xs mt-2 font-bold uppercase tracking-widest">{slugError}</p>}
          <p className="text-white/30 text-xs mt-2">
            Lowercase letters, numbers, and dashes. Will become your storefront URL when white-label ships.
          </p>
        </div>

        <button
          type="submit"
          disabled={submitting || !name.trim() || !isValidOrgSlug(slug)}
          className="w-full px-8 py-4 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {submitting ? 'Creating…' : 'Create Org'}
        </button>
      </form>
    </motion.div>
  );
}
