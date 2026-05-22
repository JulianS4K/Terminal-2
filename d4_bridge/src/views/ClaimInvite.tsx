// ClaimInvite — recipient lands here after clicking the invite link
// in their email. Validates the invite, requires email-verified
// sign-in, and on accept atomically creates the membership doc +
// marks the invite completed.
//
// Validation surface, in order:
//   1. Token exists in org_invites/{token}.
//   2. Status == 'pending'.
//   3. expiresAt is in the future.
//   4. User is signed in with email_verified == true.
//   5. The signed-in user's email (lowercased) matches the invite email.
//
// We surface specific failure messaging at each step so the recipient
// understands why an invite isn't accepting (vs. a generic "couldn't
// claim" toast).

import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { Check, X } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { claimOrgInvite, getOrgInvite, getOrganization } from '../lib/orgs';
import { Organization, OrgRole } from '../types';
import { Timestamp } from '../lib/timestamp';

interface InviteDoc {
  token: string;
  orgId: string;
  email: string;
  role: OrgRole;
  status: 'pending' | 'completed' | 'cancelled' | 'expired';
  expiresAt?: Timestamp;
}

export default function ClaimInvite() {
  const { token } = useParams<{ token: string }>();
  const { user, openAuthModal } = useAuth();
  const { refresh, setActiveOrg } = useOrganization();
  const { toast } = useToast();
  const navigate = useNavigate();

  const [state, setState] = useState<
    | { kind: 'loading' }
    | { kind: 'invalid'; reason: string }
    | { kind: 'ready'; invite: InviteDoc; org: Organization | null }
    | { kind: 'claiming' }
    | { kind: 'done'; orgName: string }
  >({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!token) {
        setState({ kind: 'invalid', reason: 'Invite link is missing the token.' });
        return;
      }
      try {
        const inv = await getOrgInvite(token);
        if (cancelled) return;
        if (!inv) {
          setState({ kind: 'invalid', reason: 'This invite no longer exists.' });
          return;
        }
        if (inv.status !== 'pending') {
          setState({
            kind: 'invalid',
            reason:
              inv.status === 'completed'
                ? 'This invite has already been used.'
                : `This invite was ${inv.status}.`,
          });
          return;
        }
        const expiresAt = inv.expiresAt?.toDate?.();
        if (expiresAt && expiresAt.getTime() < Date.now()) {
          setState({
            kind: 'invalid',
            reason: 'This invite has expired. Ask the org owner to send a new one.',
          });
          return;
        }
        const org = await getOrganization(inv.orgId).catch(() => null);
        setState({ kind: 'ready', invite: inv as InviteDoc, org });
      } catch (err) {
        // Most likely cause: rule rejection because the signed-in
        // user's email doesn't match the invite. Surface helpfully.
        const msg = err instanceof Error ? err.message : '';
        setState({
          kind: 'invalid',
          reason:
            /permission|denied/i.test(msg)
              ? 'You must sign in with the email this invite was sent to.'
              : 'Could not load this invite. Try again later.',
        });
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [token, user]);

  async function handleAccept() {
    if (state.kind !== 'ready') return;
    if (!user) {
      openAuthModal();
      return;
    }
    if (!user.emailVerified) {
      toast({
        kind: 'error',
        message: 'Verify your email before accepting (check your inbox for a verification link).',
      });
      return;
    }
    const inviteEmail = state.invite.email.toLowerCase();
    const callerEmail = (user.email || '').toLowerCase();
    if (inviteEmail !== callerEmail) {
      toast({
        kind: 'error',
        message: `This invite is for ${state.invite.email}. Sign out and sign in with that email.`,
      });
      return;
    }
    setState({ kind: 'claiming' });
    try {
      // Supabase Auth keeps the session JWT fresh on its own; the old Firebase
      // getIdToken(true) force-refresh is gone. The claim RPC derives
      // auth.uid()/email + the email_confirmed gate from the current session.
      await claimOrgInvite({
        token: state.invite.token,
        orgId: state.invite.orgId,
        role: state.invite.role,
        uid: user.uid,
      });
      await refresh();
      setActiveOrg(state.invite.orgId);
      const orgName = (state.kind as any) === 'ready' ? state.org?.name ?? 'the org' : 'the org';
      setState({ kind: 'done', orgName });
      toast({ kind: 'success', message: `Joined ${orgName} as ${state.invite.role}.` });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Claim failed';
      toast({ kind: 'error', message: msg });
      // Re-fetch the invite to surface the latest state (it may have
      // been cancelled or claimed in the interim).
      setState({ kind: 'loading' });
    }
  }

  // ---- Render ---------------------------------------------------------

  if (state.kind === 'loading' || state.kind === 'claiming') {
    return (
      <div className="max-w-xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        {state.kind === 'claiming' ? 'Accepting…' : 'Loading invite…'}
      </div>
    );
  }

  if (state.kind === 'invalid') {
    return (
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="max-w-xl mx-auto p-12 text-center"
      >
        <div className="w-12 h-12 mx-auto mb-4 bg-red-500/20 text-red-400 flex items-center justify-center">
          <X size={20} />
        </div>
        <h2 className="text-2xl font-black uppercase italic tracking-tighter text-white mb-3">
          Invite Unavailable
        </h2>
        <p className="text-white/60 mb-8">{state.reason}</p>
        <button
          onClick={() => navigate('/')}
          className="px-6 py-3 bg-white/5 hover:bg-white/10 text-white/60 font-black uppercase tracking-tighter italic transition-all"
        >
          Go home
        </button>
      </motion.div>
    );
  }

  if (state.kind === 'done') {
    return (
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="max-w-xl mx-auto p-12 text-center"
      >
        <div className="w-12 h-12 mx-auto mb-4 bg-emerald-500/20 text-emerald-400 flex items-center justify-center">
          <Check size={20} />
        </div>
        <h2 className="text-2xl font-black uppercase italic tracking-tighter text-white mb-3">
          You're In
        </h2>
        <p className="text-white/60 mb-8">You've joined {state.orgName}.</p>
        <button
          onClick={() => navigate('/dashboard')}
          className="px-6 py-3 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all"
        >
          Go to Dashboard
        </button>
      </motion.div>
    );
  }

  // 'ready' — show accept screen.
  const { invite, org } = state;
  const signedInWithRightEmail =
    user && (user.email || '').toLowerCase() === invite.email.toLowerCase();

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-xl mx-auto p-6 md:p-12"
    >
      <p className="text-[10px] text-brand-primary font-black uppercase tracking-widest mb-3">
        Invitation
      </p>
      <h1 className="text-3xl md:text-4xl font-black uppercase italic tracking-tighter text-white mb-3">
        Join {org?.name ?? 'an organization'}
      </h1>
      <p className="text-white/60 mb-6">
        You've been invited as <strong>{invite.role}</strong>. This invite is for{' '}
        <strong className="text-white">{invite.email}</strong>.
      </p>

      {!user ? (
        <div className="bg-yellow-500/10 border border-yellow-500/30 p-4 text-xs text-yellow-400 font-bold uppercase tracking-widest mb-6">
          Sign in with {invite.email} to accept.
        </div>
      ) : !signedInWithRightEmail ? (
        <div className="bg-red-500/10 border border-red-500/30 p-4 text-xs text-red-400 font-bold uppercase tracking-widest mb-6">
          You're signed in as {user.email}. Sign out and sign in with {invite.email} to accept.
        </div>
      ) : !user.emailVerified ? (
        <div className="bg-yellow-500/10 border border-yellow-500/30 p-4 text-xs text-yellow-400 font-bold uppercase tracking-widest mb-6">
          Verify your email first — check your inbox for a verification link.
        </div>
      ) : null}

      <button
        onClick={handleAccept}
        disabled={!user || !signedInWithRightEmail || !user.emailVerified}
        className="w-full px-6 py-4 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all disabled:opacity-50"
      >
        Accept Invitation
      </button>

      <p className="text-[10px] text-white/30 uppercase tracking-widest mt-4 text-center">
        By accepting you'll be added to the org with the {invite.role} role.
      </p>
    </motion.div>
  );
}
