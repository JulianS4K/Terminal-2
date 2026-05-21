import React, { createContext, useContext, useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { AppUser, toAppUser, isAdminUser, setCurrentAppUser } from '../lib/auth';
import AuthModal from '../components/AuthModal';

interface AuthContextType {
  user: AppUser | null;
  loading: boolean;
  // True iff the Supabase JWT carries `app_metadata.admin === true`. Set
  // server-side (service role) — unforgeable from the client, the analogue of
  // the old Firebase `admin` custom claim. Defaults to false.
  isAdmin: boolean;
  signIn: () => void; // Keeps the same method name but just opens the modal
  logout: () => Promise<void>;
  // Force a session refresh so a freshly-granted app_metadata claim is picked
  // up without a sign-out/sign-in cycle.
  refreshClaims: () => Promise<void>;
  isAuthModalOpen: boolean;
  openAuthModal: () => void;
  closeAuthModal: () => void;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<AppUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [isAuthModalOpen, setIsAuthModalOpen] = useState(false);

  useEffect(() => {
    let active = true;

    // Best-effort upsert of the user's PUBLIC profile (display-only). Email is
    // intentionally NOT mirrored — it stays on the JWT where RLS reads it, so
    // it isn't leaked to every signed-in user that reads a profile for a name.
    const syncProfile = async (u: AppUser) => {
      try {
        await supabase
          .from('exos_profiles')
          .upsert({ id: u.uid, display_name: u.displayName, photo_url: u.photoURL }, { onConflict: 'id' });
      } catch (err) {
        console.warn('Profile sync failed:', err);
      }
    };

    const apply = (session: Session | null, sync: boolean) => {
      if (!active) return;
      const su = session?.user ?? null;
      const appUser = toAppUser(su);
      setUser(appUser);
      setCurrentAppUser(appUser);
      setIsAdmin(isAdminUser(su));
      if (appUser) {
        setIsAuthModalOpen(false); // close the modal on successful login
        if (sync) void syncProfile(appUser);
      }
    };

    supabase.auth.getSession().then(({ data }) => {
      apply(data.session, true);
      if (active) setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      apply(session, event === 'SIGNED_IN');
    });

    return () => {
      active = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const refreshClaims = async () => {
    try {
      const { data } = await supabase.auth.refreshSession();
      setIsAdmin(isAdminUser(data.session?.user ?? null));
    } catch (err) {
      console.warn('Claim refresh failed:', err);
    }
  };

  const openAuthModal = () => setIsAuthModalOpen(true);
  const closeAuthModal = () => setIsAuthModalOpen(false);
  const signIn = () => setIsAuthModalOpen(true); // maintain compatibility

  const logout = async () => {
    await supabase.auth.signOut();
  };

  return (
    <AuthContext.Provider value={{ user, loading, isAdmin, signIn, logout, refreshClaims, isAuthModalOpen, openAuthModal, closeAuthModal }}>
      {children}
      <AuthModal isOpen={isAuthModalOpen} onClose={closeAuthModal} />
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
