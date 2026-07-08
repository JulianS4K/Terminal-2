// Orgs index — lists every org the current user belongs to and
// surfaces the active-org switcher. Single CTA to create a new org.
//
// Why this view exists separately from OrganizerDashboard: the
// dashboard renders ONE org's events; this view renders the *list* of
// orgs and is the entry point for switching between them. Operators
// running multiple venues / promoter brands need this distinction.

import { useNavigate } from 'react-router-dom';
import { motion } from 'motion/react';
import { Plus, Settings, Users, Check, Megaphone, ChevronRight } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';

const CARD = 'bg-white rounded-2xl border border-slate-200 shadow-sm';

// Light "TM" role chips, keyed by the lowercase OrgRole values.
const ROLE_CHIP: Record<string, string> = {
  owner: 'bg-slate-900 text-white',
  manager: 'bg-blue-50 text-tm-blue border border-blue-100',
  finance: 'bg-emerald-50 text-emerald-700 border border-emerald-100',
  scanner: 'bg-amber-50 text-amber-700 border border-amber-100',
  content: 'bg-violet-50 text-violet-700 border border-violet-100',
};
const roleChip = (r: string) => ROLE_CHIP[r] ?? 'bg-slate-100 text-slate-600 border border-slate-200';

// Fallback avatar palette (mockup demo colors) when an org has no theme color.
const AVATAR_PALETTE = ['#00FF00', '#FF00FF', '#FFE714', '#026cdf', '#FF3B3B', '#8B5CF6'];

export default function Orgs() {
  const { user, openAuthModal } = useAuth();
  const { orgs, activeOrg, setActiveOrg, loading } = useOrganization();
  const navigate = useNavigate();

  if (!user) {
    return (
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-3xl mx-auto px-4 py-24 text-center">
          <span className="marker text-brand-secondary text-lg inline-block rotate-[-3deg] mb-3">hold up ✦</span>
          <h2 className="text-3xl font-bold tracking-tight text-slate-900 mb-6">
            Sign in to manage your orgs
          </h2>
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

  if (loading) {
    return (
      <div className="min-h-screen bg-tm-gray text-slate-900">
        <div className="max-w-4xl mx-auto px-4 py-24 text-center text-slate-400 font-black uppercase tracking-[0.3em] animate-pulse">
          Loading…
        </div>
      </div>
    );
  }

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="min-h-screen bg-tm-gray text-slate-900"
    >
      <div className="max-w-4xl mx-auto px-4 py-12">
        <div className="flex items-center justify-between mb-8 gap-4">
          <div>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Team</p>
            <span className="inline-flex items-baseline gap-3 flex-wrap">
              <h1 className="text-3xl md:text-4xl font-bold tracking-tight">Organizations</h1>
              <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">your crews ✦</span>
            </span>
          </div>
          <button
            onClick={() => navigate('/orgs/new')}
            className="bg-tm-blue text-white px-6 py-3 rounded font-bold text-sm hover:bg-[#015bbd] shadow-sm flex items-center gap-2 shrink-0 transition-colors"
          >
            <Plus size={16} strokeWidth={2.5} />
            New org
          </button>
        </div>

        {orgs.length === 0 ? (
          <div className={`${CARD} p-12 text-center`}>
            <p className="text-slate-600 font-bold mb-3">
              You don't belong to any organizations yet.
            </p>
            <p className="text-slate-400 text-sm mb-8 max-w-md mx-auto">
              Create one to start listing events. Each event you create lives
              under an org so multiple staff can share access.
            </p>
            <button
              onClick={() => navigate('/orgs/new')}
              className="bg-tm-blue text-white px-7 py-3 rounded font-bold text-sm hover:bg-[#015bbd] shadow-sm transition-colors"
            >
              Create your first org
            </button>
          </div>
        ) : (
          <div className="space-y-3">
            {orgs.map(({ org, membership }, i) => {
              const isActive = activeOrg?.id === org.id;
              const avatarColor = org.theme?.primaryColor || AVATAR_PALETTE[i % AVATAR_PALETTE.length];
              return (
                <div
                  key={org.id}
                  className={`${CARD} p-5 flex items-center gap-4 transition-colors hover:border-tm-blue ${isActive ? 'border-tm-blue ring-1 ring-tm-blue/20' : ''}`}
                >
                  <div
                    className="w-12 h-12 flex items-center justify-center font-black text-black text-xl shrink-0"
                    style={{ background: avatarColor }}
                  >
                    {org.name.charAt(0).toUpperCase()}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2">
                      <p className="font-bold text-slate-900 truncate">{org.name}</p>
                      {isActive && (
                        <span className="text-[10px] text-tm-blue font-black uppercase tracking-widest flex items-center gap-1 shrink-0">
                          <Check size={12} strokeWidth={3} /> Active
                        </span>
                      )}
                    </div>
                    <p className="text-[11px] text-slate-400 truncate">exos.live/o/{org.slug}</p>
                  </div>

                  <span className={`px-2.5 py-1 rounded-full text-[10px] font-bold uppercase tracking-widest shrink-0 ${roleChip(membership.role)}`}>
                    {membership.role}
                  </span>

                  <div className="flex items-center gap-2 shrink-0">
                    {!isActive && (
                      <button
                        onClick={() => setActiveOrg(org.id)}
                        className="px-3 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-500 hover:border-tm-blue hover:text-tm-blue transition-colors"
                      >
                        Switch
                      </button>
                    )}
                    <button
                      onClick={() => navigate(`/orgs/${org.id}/promote`)}
                      className="p-2 rounded border border-slate-200 text-slate-500 hover:border-tm-blue hover:text-tm-blue transition-colors"
                      title="Promote"
                    >
                      <Megaphone size={16} />
                    </button>
                    {membership.role === 'owner' && (
                      <>
                        <button
                          onClick={() => navigate(`/orgs/${org.id}/settings`)}
                          className="p-2 rounded border border-slate-200 text-slate-500 hover:border-tm-blue hover:text-tm-blue transition-colors"
                          title="Settings"
                        >
                          <Settings size={16} />
                        </button>
                        <button
                          onClick={() => navigate(`/orgs/${org.id}/members`)}
                          className="p-2 rounded border border-slate-200 text-slate-500 hover:border-tm-blue hover:text-tm-blue transition-colors"
                          title="Members"
                        >
                          <Users size={16} />
                        </button>
                      </>
                    )}
                    <ChevronRight size={16} className="text-slate-300 hidden sm:block" strokeWidth={2.5} />
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </motion.div>
  );
}
