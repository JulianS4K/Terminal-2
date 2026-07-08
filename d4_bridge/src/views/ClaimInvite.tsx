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
      <div className="wall min-h-screen flex items-center justify-center">
        <p className="disp text-3xl tracking-tight text-white/20 animate-pulse" style={{ transform: 'skewX(-4deg)' }}>
          {state.kind === 'claiming' ? 'ACCEPTING…' : 'LOADING INVITE…'}
        </p>
      </div>
    );
  }

  if (state.kind === 'invalid') {
    return (
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="wall min-h-screen"
      >
        <div className="max-w-xl mx-auto p-12 text-center">
          <div className="w-12 h-12 mx-auto mb-4 bg-brand-accent/20 text-brand-accent flex items-center justify-center">
            <X size={20} />
          </div>
          <h2 className="disp text-4xl tracking-tight leading-none text-white mb-3" style={{ transform: 'skewX(-4deg)' }}>
            INVITE UNAVAILABLE
          </h2>
          <p className="type text-white/60 text-sm mb-8">{state.reason}</p>
          <button
            onClick={() => navigate('/')}
            className="disp px-6 py-3 bg-white/5 hover:bg-white/10 text-white/60 text-lg tracking-wide transition-all"
          >
            GO HOME
          </button>
        </div>
      </motion.div>
    );
  }

  if (state.kind === 'done') {
    return (
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="wall min-h-screen"
      >
        <div className="max-w-xl mx-auto p-12 text-center">
          <div className="w-12 h-12 mx-auto mb-4 bg-brand-primary/20 text-brand-primary flex items-center justify-center">
            <Check size={20} />
          </div>
          <h2 className="disp text-4xl tracking-tight leading-none text-white mb-3" style={{ transform: 'skewX(-4deg)' }}>
            YOU'RE IN
          </h2>
          <p className="type text-white/60 text-sm mb-8">You've joined {state.orgName}.</p>
          <button
            onClick={() => navigate('/dashboard')}
            className="disp px-6 py-3 bg-brand-primary text-black text-lg tracking-wide hover:bg-white transition-all"
          >
            GO TO DASHBOARD
          </button>
        </div>
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
      className="wall min-h-screen"
    >
      <div className="max-w-lg mx-auto px-4 py-16 md:py-24">
        <div className="border border-white/10 bg-[#0c0c0c]">
          <div className="p-8 md:p-10 text-center border-b border-white/10">
            <p className="type text-brand-primary text-xs tracking-[0.3em] uppercase mb-6">// you're invited</p>
            <div className="w-20 h-20 mx-auto flex items-center justify-center disp text-black text-3xl mb-6 bg-brand-primary">
              {(org?.name ?? 'O').charAt(0).toUpperCase()}
            </div>
            <h1 className="disp text-4xl md:text-5xl leading-none mb-3" style={{ transform: 'skewX(-4deg)' }}>
              JOIN <span className="text-brand-primary">{org?.name ?? 'AN ORGANIZATION'}</span>
            </h1>
            <p className="type text-white/60 text-sm">You've been invited to help run events on Exos.</p>
          </div>

          <div className="p-8 md:p-10">
            <div className="flex items-center justify-between py-3 border-b border-white/5">
              <span className="type text-xs uppercase tracking-widest text-white/40">Invited as</span>
              <span className="px-2.5 py-1 text-[10px] font-black uppercase tracking-widest bg-white/10 border border-white/15">{invite.role}</span>
            </div>
            <div className="flex items-center justify-between py-3 gap-4">
              <span className="type text-xs uppercase tracking-widest text-white/40 shrink-0">Your email</span>
              <span className="text-sm font-semibold break-all text-right">{invite.email}</span>
            </div>

            {!user ? (
              <div className="mt-6 bg-yellow-500/10 border border-yellow-500/30 p-4 text-xs text-yellow-400 font-bold uppercase tracking-widest">
                Sign in with {invite.email} to accept.
              </div>
            ) : !signedInWithRightEmail ? (
              <div className="mt-6 bg-red-500/10 border border-red-500/30 p-4 text-xs text-red-400 font-bold uppercase tracking-widest">
                You're signed in as {user.email}. Sign out and sign in with {invite.email} to accept.
              </div>
            ) : !user.emailVerified ? (
              <div className="mt-6 bg-yellow-500/10 border border-yellow-500/30 p-4 text-xs text-yellow-400 font-bold uppercase tracking-widest">
                Verify your email first — check your inbox for a verification link.
              </div>
            ) : null}

            <button
              onClick={handleAccept}
              disabled={!user || !signedInWithRightEmail || !user.emailVerified}
              className="mt-8 block w-full text-center bg-brand-primary text-black disp uppercase tracking-wide text-xl py-4 hover:scale-[1.01] active:scale-[0.99] transition-transform disabled:opacity-50"
            >
              Accept Invitation
            </button>

            <p className="type text-[11px] text-white/30 text-center mt-4">
              By accepting you'll be added to the org with the {invite.role} role.
            </p>
          </div>
        </div>
      </div>
    </motion.div>
  );
}
