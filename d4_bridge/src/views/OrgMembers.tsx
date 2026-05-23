// OrgMembers — owner-only member roster + role/disable management.
//
// Sprint 1 cut: list members (uid + role + disabled flag), let the
// owner change a member's role and soft-disable them, plus a stub
// "invite" flow that requires the invitee's uid (the email-based
// invite needs Cloud Functions to look up uids by email — deferred to
// when the mail queue is rate-limited).

import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { ArrowLeft, Mail, UserX, UserCheck, X } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import {
  cancelOrgInvite,
  createOrgInvite,
  disableOrgMember,
  enableOrgMember,
  listOrgInvites,
  listOrgMembers,
  updateOrgMemberRole,
} from '../lib/orgs';
import { queueEmail } from '../lib/mail';
import { OrgMembership, OrgRole } from '../types';

const ROLE_OPTIONS: OrgRole[] = ['manager', 'finance', 'content', 'scanner'];

export default function OrgMembers() {
  const { orgId } = useParams<{ orgId: string }>();
  const { user, isAdmin } = useAuth();
  const { activeRole } = useOrganization();
  const { toast } = useToast();
  const navigate = useNavigate();

  const [members, setMembers] = useState<OrgMembership[]>([]);
  const [pendingInvites, setPendingInvites] = useState<
    Array<{ token: string; email: string; role: OrgRole; status: string }>
  >([]);
  const [loading, setLoading] = useState(true);
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteRole, setInviteRole] = useState<OrgRole>('manager');
  const [inviting, setInviting] = useState(false);

  const canManage = isAdmin || activeRole === 'owner';

  async function refresh() {
    if (!orgId) return;
    setLoading(true);
    try {
      const [m, i] = await Promise.all([
        listOrgMembers(orgId),
        listOrgInvites(orgId).catch(() => []),
      ]);
      setMembers(m);
      // Only surface pending invites in the UI; completed/cancelled
      // are kept in Firestore for audit but not shown here.
      setPendingInvites(
        i
          .filter((inv) => inv.status === 'pending')
          .map((inv) => ({ token: inv.token, email: inv.email, role: inv.role, status: inv.status })),
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Load failed';
      toast({ kind: 'error', message: msg });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId]);

  if (!user) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center text-white/60 font-bold uppercase tracking-widest">
        Sign in required.
      </div>
    );
  }

  async function handleInvite() {
    if (!orgId || !user) return;
    if (!canManage) return;
    const email = inviteEmail.trim().toLowerCase();
    if (email.length === 0 || !email.includes('@')) {
      toast({ kind: 'error', message: 'Enter a valid email.' });
      return;
    }
    setInviting(true);
    try {
      const { token: inviteToken, inviteUrl } = await createOrgInvite({
        orgId,
        email,
        role: inviteRole,
        createdBy: user.uid,
      });
      // Best-effort enqueue of the invite email. Recipient + body are
      // server-derived by the exos_queue_mail RPC (mig 20260520160000).
      // exos_org_invites PK is `token`; pass it as refId so the RPC can
      // look up the invite row. If the migration isn't applied yet the
      // call fails silently — the owner can copy inviteUrl manually.
      await queueEmail({ template: 'org-invite', refId: inviteToken });
      toast({ kind: 'success', message: `Invite sent to ${email}.` });
      setInviteEmail('');
      await refresh();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Invite failed';
      toast({ kind: 'error', message: msg });
    } finally {
      setInviting(false);
    }
  }

  async function handleCancelInvite(token: string) {
    if (!orgId || !canManage) return;
    try {
      await cancelOrgInvite(token);
      toast({ kind: 'success', message: 'Invite cancelled.' });
      await refresh();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Cancel failed';
      toast({ kind: 'error', message: msg });
    }
  }

  async function handleRoleChange(uid: string, role: OrgRole) {
    if (!orgId || !canManage) return;
    try {
      await updateOrgMemberRole(orgId, uid, role);
      toast({ kind: 'success', message: 'Role updated.' });
      await refresh();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Update failed';
      toast({ kind: 'error', message: msg });
    }
  }

  async function handleDisable(uid: string, currentlyDisabled: boolean) {
    if (!orgId || !canManage) return;
    try {
      if (currentlyDisabled) {
        await enableOrgMember(orgId, uid);
        toast({ kind: 'success', message: 'Member re-enabled.' });
      } else {
        await disableOrgMember(orgId, uid);
        toast({ kind: 'success', message: 'Member disabled.' });
      }
      await refresh();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Update failed';
      toast({ kind: 'error', message: msg });
    }
  }

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-3xl mx-auto p-6 md:p-12"
    >
      <button
        onClick={() => navigate('/orgs')}
        className="flex items-center gap-2 text-white/40 hover:text-white text-[10px] font-black uppercase tracking-widest mb-6 transition-all"
      >
        <ArrowLeft size={14} /> Back to orgs
      </button>

      <h1 className="text-4xl md:text-5xl font-black uppercase italic tracking-tighter text-white mb-2">
        Members
      </h1>
      <p className="text-white/50 text-sm mb-10">
        Roles: owner (full control), manager (events + check-in), finance
        (read-only + refunds), content (event content only), scanner (door staff).
      </p>

      {!canManage && (
        <div className="bg-yellow-500/10 border border-yellow-500/30 p-4 mb-6 text-yellow-400 text-xs font-bold uppercase tracking-widest">
          Read-only — only org owners can change membership.
        </div>
      )}

      {canManage && (
        <div className="bg-white/5 border border-white/10 p-4 mb-6">
          <h2 className="text-[10px] text-white/60 font-black uppercase tracking-widest mb-3 flex items-center gap-2">
            <Mail size={14} /> Invite by email
          </h2>
          <div className="flex flex-col md:flex-row gap-2">
            <input
              type="email"
              value={inviteEmail}
              onChange={(e) => setInviteEmail(e.target.value)}
              placeholder="member@venue.com"
              className="flex-1 bg-white/5 border border-white/10 px-3 py-2 text-sm text-white font-bold focus:border-brand-primary focus:outline-none transition-all"
            />
            <select
              value={inviteRole}
              onChange={(e) => setInviteRole(e.target.value as OrgRole)}
              className="bg-white/5 border border-white/10 px-3 py-2 text-sm text-white font-bold focus:border-brand-primary focus:outline-none transition-all"
            >
              {ROLE_OPTIONS.map((r) => (
                <option key={r} value={r}>{r}</option>
              ))}
            </select>
            <button
              onClick={handleInvite}
              disabled={inviting}
              className="px-4 py-2 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all disabled:opacity-50 text-sm"
            >
              {inviting ? 'Sending…' : 'Send Invite'}
            </button>
          </div>
          <p className="text-[10px] text-white/30 mt-2 uppercase tracking-widest">
            Recipient signs in with this email; invite expires in 14 days. Ownership transfer requires admin tooling.
          </p>
        </div>
      )}

      {pendingInvites.length > 0 && (
        <div className="mb-8">
          <h3 className="text-[10px] text-white/60 font-black uppercase tracking-widest mb-2">Pending invites</h3>
          <div className="space-y-2">
            {pendingInvites.map((inv) => (
              <div
                key={inv.token}
                className="bg-white/5 border border-yellow-500/30 p-3 flex items-center justify-between gap-3"
              >
                <div className="flex-1 min-w-0">
                  <div className="text-white font-bold text-sm truncate">{inv.email}</div>
                  <div className="text-[10px] text-yellow-400 font-bold uppercase tracking-widest">
                    pending · {inv.role}
                  </div>
                </div>
                {canManage && (
                  <button
                    onClick={() => handleCancelInvite(inv.token)}
                    title="Cancel invite"
                    className="p-2 bg-white/5 hover:bg-red-500/20 transition-all"
                  >
                    <X size={14} />
                  </button>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {loading ? (
        <div className="text-center text-white/50 py-12 font-bold uppercase tracking-[0.3em] animate-pulse">
          Loading…
        </div>
      ) : members.length === 0 ? (
        <div className="bg-white/5 border border-white/10 p-12 text-center text-white/50 text-sm">
          No members yet — that shouldn't happen if you're seeing this page,
          since you are one. Try refreshing.
        </div>
      ) : (
        <div className="space-y-2">
          {members.map((m) => {
            const isYou = m.uid === user.uid;
            const isOwner = m.role === 'owner';
            return (
              <div
                key={m.id}
                className={`bg-white/5 border ${m.disabled ? 'border-red-500/30 opacity-60' : 'border-white/10'} p-4 flex items-center justify-between gap-4`}
              >
                <div className="flex-1 min-w-0">
                  <div className="text-white font-bold text-sm truncate">
                    {m.uid}
                    {isYou && <span className="ml-2 text-[10px] text-brand-primary uppercase tracking-widest">(you)</span>}
                  </div>
                  <div className="text-[10px] text-white/40 font-bold uppercase tracking-widest">
                    {m.role}
                    {m.disabled && <span className="ml-2 text-red-400">disabled</span>}
                  </div>
                </div>
                {canManage && !isOwner && (
                  <div className="flex items-center gap-2">
                    <select
                      value={m.role}
                      onChange={(e) => handleRoleChange(m.uid, e.target.value as OrgRole)}
                      className="bg-white/5 border border-white/10 px-2 py-1 text-xs text-white font-bold focus:border-brand-primary focus:outline-none transition-all"
                    >
                      {ROLE_OPTIONS.map((r) => (
                        <option key={r} value={r}>{r}</option>
                      ))}
                    </select>
                    <button
                      onClick={() => handleDisable(m.uid, m.disabled === true)}
                      title={m.disabled ? 'Re-enable' : 'Disable'}
                      className="p-2 bg-white/5 hover:bg-red-500/20 transition-all"
                    >
                      {m.disabled ? <UserCheck size={14} /> : <UserX size={14} />}
                    </button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </motion.div>
  );
}
