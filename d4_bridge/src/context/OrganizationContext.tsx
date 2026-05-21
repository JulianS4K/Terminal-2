// OrganizationContext — resolves the current user's orgs, picks an
// "active" org for the dashboard surface, and exposes the role the
// current user holds in that org for UI gating.
//
// Sits one level inside AuthContext (every org operation needs a uid).
// Gracefully handles three states:
//
//   * Signed-out:  active org = null, list = [].
//   * Signed-in with no orgs:  active org = null, list = []. The
//     OrganizerDashboard view treats this as "you have no org yet" and
//     shows a CTA to create one.
//   * Signed-in with N orgs:  active org defaults to the most recently
//     used (persisted in localStorage), falling back to the first by
//     name. The active org id is exposed for downstream queries.
//
// We don't subscribe to org/membership docs in real-time. Memberships
// don't change second-to-second, and a single getDocs at sign-in covers
// the whole sprint's needs. Real-time can be added later if/when we
// build a notification system around membership changes.

import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { useAuth } from './AuthContext';
import { Organization, OrgMembership, OrgRole } from '../types';
import { listOrgsForUser } from '../lib/orgs';

interface OrgEntry {
  org: Organization;
  membership: OrgMembership;
}

interface OrganizationContextType {
  // All orgs the current user belongs to via active membership.
  orgs: OrgEntry[];
  // The org currently selected for dashboard / create / edit views.
  activeOrg: Organization | null;
  // The role the current user holds in the active org. null when no
  // active org or no membership (admin-of-the-platform still gets null
  // here — admins use the existing `isAdmin` from AuthContext to bypass
  // org gating).
  activeRole: OrgRole | null;
  loading: boolean;
  // Switch to an org by id. Persists to localStorage so the choice
  // survives reloads.
  setActiveOrg: (orgId: string) => void;
  // Force a refresh — call after creating an org or accepting an invite.
  refresh: () => Promise<void>;
}

const OrganizationContext = createContext<OrganizationContextType | undefined>(undefined);

const ACTIVE_ORG_STORAGE_KEY = 'vibepass:activeOrgId';

export function OrganizationProvider({ children }: { children: React.ReactNode }) {
  const { user, loading: authLoading } = useAuth();
  const [orgs, setOrgs] = useState<OrgEntry[]>([]);
  const [activeOrgId, setActiveOrgId] = useState<string | null>(() => {
    // Lazy init from localStorage so the active-org choice survives
    // page reloads. Falls back gracefully when localStorage is
    // unavailable (Safari private mode, server-rendering, etc.).
    try {
      return localStorage.getItem(ACTIVE_ORG_STORAGE_KEY);
    } catch {
      return null;
    }
  });
  const [loading, setLoading] = useState(true);

  // loadOrgs intentionally does NOT close over activeOrgId. The
  // staleness check (validating the persisted activeOrgId against the
  // freshly loaded list) is split into a separate effect below so that
  // switching orgs doesn't recreate this callback or trigger a
  // re-fetch — the org list itself only changes when memberships
  // change, which today is on user signin / signout / explicit refresh.
  const loadOrgs = useCallback(async () => {
    if (!user) {
      setOrgs([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      const list = await listOrgsForUser(user.uid);
      setOrgs(list);
    } catch (err) {
      // Most likely a rules rejection during the brief window after sign-up
      // before the user has any memberships. Treat as empty.
      console.warn('Org list failed; treating as empty:', err);
      setOrgs([]);
    } finally {
      setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    if (authLoading) return; // Wait for auth before deciding what to load.
    loadOrgs();
  }, [authLoading, loadOrgs]);

  // Staleness check: whenever the org list updates, make sure the
  // persisted activeOrgId still matches a membership. Falls back to
  // the first org if the persisted choice is no longer valid (org was
  // deleted, membership was revoked, etc.).
  useEffect(() => {
    if (orgs.length === 0) return;
    const stillValid = activeOrgId && orgs.some((e) => e.org.id === activeOrgId);
    if (!stillValid) {
      setActiveOrgId(orgs[0].org.id);
      try {
        localStorage.setItem(ACTIVE_ORG_STORAGE_KEY, orgs[0].org.id);
      } catch {
        /* ignore */
      }
    }
  }, [orgs, activeOrgId]);

  const setActiveOrg = useCallback((orgId: string) => {
    setActiveOrgId(orgId);
    try {
      localStorage.setItem(ACTIVE_ORG_STORAGE_KEY, orgId);
    } catch {
      /* ignore */
    }
  }, []);

  const activeEntry = activeOrgId
    ? orgs.find((e) => e.org.id === activeOrgId) ?? null
    : null;

  const value: OrganizationContextType = {
    orgs,
    activeOrg: activeEntry?.org ?? null,
    activeRole: activeEntry?.membership.role ?? null,
    loading,
    setActiveOrg,
    refresh: loadOrgs,
  };

  return <OrganizationContext.Provider value={value}>{children}</OrganizationContext.Provider>;
}

export function useOrganization() {
  const ctx = useContext(OrganizationContext);
  if (ctx === undefined) {
    throw new Error('useOrganization must be used within an OrganizationProvider');
  }
  return ctx;
}
