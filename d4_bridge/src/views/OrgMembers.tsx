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
import { ArrowLeft, Mail, UserX, UserCheck, X, Check, Minus } from 'lucide-react';
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

// Light "TM" role chips, keyed by the lowercase OrgRole values.
const ROLE_CHIP: Record<string, string> = {
  owner: 'bg-slate-900 text-white',
  manager: 'bg-blue-50 text-tm-blue border border-blue-100',
  finance: 'bg-emerald-50 text-emerald-700 border border-emerald-100',
  scanner: 'bg-amber-50 text-amber-700 border border-amber-100',
  content: 'bg-violet-50 text-violet-700 border border-violet-100',
};
const roleChip = (r: string) => ROLE_CHIP[r] ?? 'bg-slate-100 text-slate-600 border border-slate-200';

// Static roles/permissions reference — mirrors the descriptive copy the
// view has always shown, presented as the RolePermissions matrix. Purely
// informational (no persistence layer exists for per-role toggles).
const ROLE_REF: Array<{ name: string; chip: string; desc: string }> = [
  { name: 'Owner', chip: ROLE_CHIP.owner, desc: 'Full control. Billing, members, delete.' },
  { name: 'Manager', chip: ROLE_CHIP.manager, desc: 'Run events end-to-end. No billing.' },
  { name: 'Finance', chip: ROLE_CHIP.finance, desc: 'Money: reports, refunds, payouts.' },
  { name: 'Scanner', chip: ROLE_CHIP.scanner, desc: 'Door only. Scan + admit.' },
  { name: 'Content', chip: ROLE_CHIP.content, desc: 'Edit listings, storefront, promo.' },
];
// [owner, manager, finance, scanner, content]
const PERM_MATRIX: Array<[string, number[]]> = [
  ['Create & edit events', [1, 1, 0, 0, 1]],
  ['Publish / cancel events', [1, 1, 0, 0, 0]],
  ['View sales & financials', [1, 1, 1, 0, 0]],
  ['Refund / void tickets', [1, 1, 1, 0, 0]],
  ['Scan at the door', [1, 1, 0, 1, 0]],
  ['Send announcements', [1, 1, 0, 0, 1]],
  ['Promo codes & promote', [1, 1, 0, 0, 1]],
  ['Edit storefront & branding', [1, 1, 0, 0, 1]],
  ['Manage members', [1, 0, 0, 0, 0]],
  ['Billing & payouts', [1, 0, 1, 0, 0]],
];

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
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-3xl mx-auto px-4 py-24 text-center text-slate-500 font-bold uppercase tracking-widest">
          Sign in required.
        </div>
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
      className="min-h-screen bg-tm-gray text-slate-900"
    >
      <div className="max-w-5xl mx-auto px-4 py-10">
        <button
          onClick={() => navigate('/orgs')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors"
        >
          <ArrowLeft size={14} strokeWidth={2.5} /> All organizations
        </button>

        <div className="mb-8">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Team</p>
          <span className="inline-flex items-baseline gap-3 flex-wrap">
            <h1 className="text-3xl md:text-4xl font-bold tracking-tight">Members</h1>
            <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">the team ✦</span>
          </span>
        </div>

        {/* Tabs */}
        <div className="flex gap-6 border-b border-slate-200 mb-8">
          <button
            onClick={() => orgId && navigate(`/orgs/${orgId}/settings`)}
            className="pb-3 text-sm font-bold text-slate-400 hover:text-slate-600 transition-colors"
          >
            General
          </button>
          <button className="pb-3 text-sm font-bold text-slate-900 border-b-2 border-tm-blue -mb-px">Members</button>
          <span className="pb-3 text-sm font-bold text-slate-300 cursor-default">Billing</span>
        </div>

        {!canManage && (
          <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 mb-6 text-amber-700 text-xs font-bold uppercase tracking-widest">
            Read-only — only org owners can change membership.
          </div>
        )}

        {canManage && (
          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 mb-6">
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3 flex items-center gap-2">
              <Mail size={14} /> Invite a teammate
            </p>
            <div className="flex flex-col sm:flex-row gap-3">
              <input
                type="email"
                value={inviteEmail}
                onChange={(e) => setInviteEmail(e.target.value)}
                placeholder="email@venue.com"
                className="flex-1 bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm text-slate-900 focus:outline-none focus:border-tm-blue transition-colors"
              />
              <select
                value={inviteRole}
                onChange={(e) => setInviteRole(e.target.value as OrgRole)}
                className="bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm font-bold text-slate-900 focus:outline-none focus:border-tm-blue transition-colors capitalize"
              >
                {ROLE_OPTIONS.map((r) => (
                  <option key={r} value={r}>{r}</option>
                ))}
              </select>
              <button
                onClick={handleInvite}
                disabled={inviting}
                className="bg-tm-blue text-white px-6 py-3 rounded font-bold text-sm hover:bg-[#015bbd] shadow-sm transition-colors disabled:opacity-50"
              >
                {inviting ? 'Sending…' : 'Send invite'}
              </button>
            </div>
            <p className="text-[10px] text-slate-400 mt-3 uppercase tracking-widest">
              Recipient signs in with this email; invite expires in 14 days. Ownership transfer requires admin tooling.
            </p>
          </div>
        )}

        {/* Roster */}
        <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-x-auto mb-10">
          <table className="w-full text-left min-w-[640px]">
            <thead>
              <tr className="bg-slate-50 border-b border-slate-100">
                <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Member</th>
                <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Role</th>
                <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Status</th>
                <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {loading ? (
                <tr>
                  <td colSpan={4} className="px-6 py-12 text-center text-slate-400 font-black uppercase tracking-[0.3em] animate-pulse">
                    Loading…
                  </td>
                </tr>
              ) : (
                <>
                  {/* Pending invites first */}
                  {pendingInvites.map((inv) => (
                    <tr key={inv.token} className="hover:bg-slate-50/50">
                      <td className="px-6 py-4">
                        <div className="flex items-center gap-3">
                          <div className="w-9 h-9 rounded-full bg-slate-100 flex items-center justify-center font-black text-slate-400">?</div>
                          <div className="min-w-0">
                            <p className="font-bold text-sm text-slate-900 truncate">{inv.email}</p>
                            <p className="text-[11px] text-slate-400">Invite pending</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-4">
                        <span className={`px-2.5 py-1 rounded-full text-[10px] font-bold uppercase tracking-widest ${roleChip(inv.role)}`}>
                          {inv.role}
                        </span>
                      </td>
                      <td className="px-6 py-4">
                        <span className="text-[10px] font-bold text-amber-500 uppercase tracking-widest">◔ Invite sent</span>
                      </td>
                      <td className="px-6 py-4 text-right">
                        {canManage ? (
                          <button
                            onClick={() => handleCancelInvite(inv.token)}
                            title="Cancel invite"
                            className="inline-flex items-center gap-1 text-slate-400 hover:text-rose-500 text-[10px] font-black uppercase tracking-widest transition-colors"
                          >
                            <X size={13} strokeWidth={2.5} /> Cancel
                          </button>
                        ) : (
                          <span className="text-[10px] text-slate-300 font-bold uppercase tracking-widest">—</span>
                        )}
                      </td>
                    </tr>
                  ))}

                  {/* Members */}
                  {members.length === 0 && pendingInvites.length === 0 ? (
                    <tr>
                      <td colSpan={4} className="px-6 py-12 text-center text-slate-400 text-sm">
                        No members yet — that shouldn't happen if you're seeing this page,
                        since you are one. Try refreshing.
                      </td>
                    </tr>
                  ) : (
                    members.map((m) => {
                      const isYou = m.uid === user.uid;
                      const isOwner = m.role === 'owner';
                      return (
                        <tr key={m.id} className={`hover:bg-slate-50/50 ${m.disabled ? 'opacity-60' : ''}`}>
                          <td className="px-6 py-4">
                            <div className="flex items-center gap-3">
                              <div className="w-9 h-9 rounded-full bg-slate-100 flex items-center justify-center font-black text-slate-500 uppercase">
                                {m.uid.charAt(0)}
                              </div>
                              <div className="min-w-0">
                                <p className="font-bold text-sm text-slate-900 font-mono truncate">
                                  {m.uid}
                                  {isYou && <span className="ml-2 text-[10px] text-tm-blue font-black uppercase tracking-widest">(you)</span>}
                                </p>
                                <p className="text-[11px] text-slate-400 capitalize">{m.role}</p>
                              </div>
                            </div>
                          </td>
                          <td className="px-6 py-4">
                            <span className={`px-2.5 py-1 rounded-full text-[10px] font-bold uppercase tracking-widest ${roleChip(m.role)}`}>
                              {m.role}
                            </span>
                          </td>
                          <td className="px-6 py-4">
                            {m.disabled ? (
                              <span className="text-[10px] font-bold text-rose-500 uppercase tracking-widest">● Disabled</span>
                            ) : (
                              <span className="text-[10px] font-bold text-green-600 uppercase tracking-widest">● Active</span>
                            )}
                          </td>
                          <td className="px-6 py-4">
                            {canManage && !isOwner ? (
                              <div className="flex items-center justify-end gap-2">
                                <select
                                  value={m.role}
                                  onChange={(e) => handleRoleChange(m.uid, e.target.value as OrgRole)}
                                  className="bg-white border border-slate-200 rounded px-2 py-1 text-xs font-bold text-slate-700 focus:outline-none focus:border-tm-blue transition-colors capitalize"
                                >
                                  {ROLE_OPTIONS.map((r) => (
                                    <option key={r} value={r}>{r}</option>
                                  ))}
                                </select>
                                <button
                                  onClick={() => handleDisable(m.uid, m.disabled === true)}
                                  title={m.disabled ? 'Re-enable' : 'Disable'}
                                  className="p-2 rounded border border-slate-200 text-slate-400 hover:border-rose-300 hover:text-rose-500 transition-colors"
                                >
                                  {m.disabled ? <UserCheck size={14} /> : <UserX size={14} />}
                                </button>
                              </div>
                            ) : (
                              <div className="text-right">
                                <span className="text-[10px] text-slate-300 font-bold uppercase tracking-widest">—</span>
                              </div>
                            )}
                          </td>
                        </tr>
                      );
                    })
                  )}
                </>
              )}
            </tbody>
          </table>
        </div>

        {/* Roles & permissions reference (read-only) */}
        <div className="mb-6">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Team access</p>
          <span className="inline-flex items-baseline gap-3 flex-wrap">
            <h2 className="text-2xl md:text-3xl font-bold tracking-tight">Roles &amp; permissions</h2>
            <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">who does what ✦</span>
          </span>
          <p className="text-slate-500 text-sm mt-2">
            What each role can do. Enforced server-side by <span className="font-mono text-xs text-slate-600">exos_has_org_role()</span>.
          </p>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6">
          {ROLE_REF.map((r) => (
            <div key={r.name} className="bg-white rounded-2xl border border-slate-200 shadow-sm p-4">
              <span className={`inline-block px-2.5 py-1 rounded-full text-[10px] font-bold uppercase tracking-widest mb-3 ${r.chip}`}>{r.name}</span>
              <p className="text-[11px] text-slate-500 leading-snug">{r.desc}</p>
            </div>
          ))}
        </div>

        <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-x-auto">
          <table className="w-full text-left min-w-[720px]">
            <thead>
              <tr className="bg-slate-50 border-b border-slate-100">
                <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Permission</th>
                <th className="px-4 py-4 text-[10px] font-black text-slate-900 uppercase tracking-widest text-center">Owner</th>
                <th className="px-4 py-4 text-[10px] font-black text-tm-blue uppercase tracking-widest text-center">Manager</th>
                <th className="px-4 py-4 text-[10px] font-black text-emerald-600 uppercase tracking-widest text-center">Finance</th>
                <th className="px-4 py-4 text-[10px] font-black text-amber-600 uppercase tracking-widest text-center">Scanner</th>
                <th className="px-4 py-4 text-[10px] font-black text-violet-600 uppercase tracking-widest text-center">Content</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {PERM_MATRIX.map(([label, arr]) => (
                <tr key={label} className="hover:bg-slate-50/50">
                  <td className="px-6 py-3.5 text-sm font-bold text-slate-700">{label}</td>
                  {arr.map((v, idx) => (
                    <td key={idx} className="px-4 py-3.5 text-center">
                      {v ? (
                        <span className="inline-flex w-6 h-6 rounded-full bg-green-50 text-green-600 items-center justify-center mx-auto">
                          <Check size={14} strokeWidth={3} />
                        </span>
                      ) : (
                        <span className="inline-flex w-6 h-6 items-center justify-center mx-auto text-slate-200">
                          <Minus size={14} strokeWidth={3} />
                        </span>
                      )}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </motion.div>
  );
}
