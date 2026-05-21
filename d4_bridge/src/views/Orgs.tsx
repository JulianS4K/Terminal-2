// Orgs index — lists every org the current user belongs to and
// surfaces the active-org switcher. Single CTA to create a new org.
//
// Why this view exists separately from OrganizerDashboard: the
// dashboard renders ONE org's events; this view renders the *list* of
// orgs and is the entry point for switching between them. Operators
// running multiple venues / promoter brands need this distinction.

import { useNavigate } from 'react-router-dom';
import { motion } from 'motion/react';
import { Plus, Settings, Users, Check } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';

export default function Orgs() {
  const { user, openAuthModal } = useAuth();
  const { orgs, activeOrg, setActiveOrg, loading } = useOrganization();
  const navigate = useNavigate();

  if (!user) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center">
        <h2 className="text-3xl font-black uppercase italic tracking-tighter text-white mb-4">
          Sign in to manage your orgs
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

  if (loading) {
    return (
      <div className="max-w-3xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-4xl mx-auto p-6 md:p-12"
    >
      <div className="flex items-center justify-between mb-8">
        <h1 className="text-4xl md:text-5xl font-black uppercase italic tracking-tighter text-white">
          Your Organizations
        </h1>
        <button
          onClick={() => navigate('/orgs/new')}
          className="px-6 py-3 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all flex items-center gap-2"
        >
          <Plus size={18} />
          New Org
        </button>
      </div>

      {orgs.length === 0 ? (
        <div className="bg-white/5 border border-white/10 p-12 text-center">
          <p className="text-white/60 font-bold uppercase tracking-widest mb-6">
            You don't belong to any organizations yet.
          </p>
          <p className="text-white/40 text-sm mb-8">
            Create one to start listing events. Each event you create lives
            under an org so multiple staff can share access.
          </p>
          <button
            onClick={() => navigate('/orgs/new')}
            className="px-8 py-3 bg-brand-primary text-black font-black uppercase tracking-tighter italic hover:bg-white transition-all"
          >
            Create your first org
          </button>
        </div>
      ) : (
        <div className="space-y-3">
          {orgs.map(({ org, membership }) => {
            const isActive = activeOrg?.id === org.id;
            return (
              <div
                key={org.id}
                className={`bg-white/5 border ${isActive ? 'border-brand-primary' : 'border-white/10'} p-6 flex items-center justify-between gap-4 group hover:border-brand-primary transition-all`}
              >
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-3 mb-1">
                    <h3 className="text-xl font-black uppercase italic tracking-tighter text-white truncate">
                      {org.name}
                    </h3>
                    {isActive && (
                      <span className="text-[10px] text-brand-primary font-black uppercase tracking-widest flex items-center gap-1">
                        <Check size={12} /> Active
                      </span>
                    )}
                  </div>
                  <p className="text-[10px] text-white/40 font-bold uppercase tracking-widest">
                    /{org.slug} · {membership.role}
                  </p>
                </div>
                <div className="flex items-center gap-2 flex-shrink-0">
                  {!isActive && (
                    <button
                      onClick={() => setActiveOrg(org.id)}
                      className="px-4 py-2 bg-white/5 hover:bg-brand-primary hover:text-black text-[10px] font-black uppercase tracking-tighter italic transition-all"
                    >
                      Switch
                    </button>
                  )}
                  {membership.role === 'owner' && (
                    <>
                      <button
                        onClick={() => navigate(`/orgs/${org.id}/settings`)}
                        className="p-2 bg-white/5 hover:bg-white/10 transition-all"
                        title="Settings"
                      >
                        <Settings size={16} />
                      </button>
                      <button
                        onClick={() => navigate(`/orgs/${org.id}/members`)}
                        className="p-2 bg-white/5 hover:bg-white/10 transition-all"
                        title="Members"
                      >
                        <Users size={16} />
                      </button>
                    </>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </motion.div>
  );
}
