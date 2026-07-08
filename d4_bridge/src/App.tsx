import { BrowserRouter as Router, Routes, Route, useLocation } from 'react-router-dom';
import { lazy, Suspense, ReactNode } from 'react';
import { AuthProvider } from './context/AuthContext';
import { OrganizationProvider } from './context/OrganizationContext';
import { ToastProvider } from './context/ToastContext';
import { LanguageProvider } from './context/LanguageContext';
import Navbar from './components/Navbar';
import Footer from './components/Footer';
import ErrorBoundary from './components/ErrorBoundary';
import PwaShell from './components/PwaShell';
import ConsentBanner from './components/ConsentBanner';

// Home is the landing page — keep it eagerly loaded so the first paint is
// fast. Every other route is split out so we don't ship CreateEvent / the
// QR scanner / Stripe / etc. on the initial download.
import Home from './views/Home';
const EventDetails = lazy(() => import('./views/EventDetails'));
const MyTickets = lazy(() => import('./views/MyTickets'));
const TicketDetail = lazy(() => import('./views/TicketDetail'));
const WalletPass = lazy(() => import('./views/WalletPass'));
const TransferTicket = lazy(() => import('./views/TransferTicket'));
const ClaimTicket = lazy(() => import('./views/ClaimTicket'));
const OrganizerDashboard = lazy(() => import('./views/OrganizerDashboard'));
const CreateEvent = lazy(() => import('./views/CreateEvent'));
const OrganizerCheckIn = lazy(() => import('./views/OrganizerCheckIn'));
const EditEvent = lazy(() => import('./views/EditEvent'));
const Privacy = lazy(() => import('./views/Privacy'));
const Terms = lazy(() => import('./views/Terms'));
const Status = lazy(() => import('./views/Status'));
const Profile = lazy(() => import('./views/Profile'));
const OrganizerProfile = lazy(() => import('./views/OrganizerProfile'));
const SlugRedirect = lazy(() => import('./views/SlugRedirect'));
const Orgs = lazy(() => import('./views/Orgs'));
const CreateOrg = lazy(() => import('./views/CreateOrg'));
const OrgSettings = lazy(() => import('./views/OrgSettings'));
const OrgMembers = lazy(() => import('./views/OrgMembers'));
const OrgStorefront = lazy(() => import('./views/OrgStorefront'));
const EmbedEvent = lazy(() => import('./views/EmbedEvent'));
const OrganizerOnboarding = lazy(() => import('./views/OrganizerOnboarding'));
const ClaimInvite = lazy(() => import('./views/ClaimInvite'));
const OrganizerEventReport = lazy(() => import('./views/OrganizerEventReport'));
const PromoteEvent = lazy(() => import('./views/PromoteEvent'));
const OrgPromote = lazy(() => import('./views/OrgPromote'));
const NotFound = lazy(() => import('./views/NotFound'));
const Notifications = lazy(() => import('./views/Notifications'));

/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

function RouteFallback() {
  return (
    <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
      Loading…
    </div>
  );
}

/**
 * Layout wrapper that conditionally hides the navbar/footer chrome
 * on routes that are meant to render bare (e.g. /embed/event/:id).
 * Embed routes go inside an iframe on the venue's site, so platform
 * chrome would stack with the host page's chrome and look broken.
 */
function ChromeLayout({ children }: { children: ReactNode }) {
  const location = useLocation();
  const isBare =
    location.pathname.startsWith('/embed/') ||
    location.pathname.startsWith('/wallet/pass/') ||
    // White-label org storefront (/o/:slug) supplies its own org-branded
    // nav + footer, so the platform chrome is suppressed here too.
    location.pathname.startsWith('/o/');
  if (isBare) {
    // Bare layout — no navbar, no footer, no PwaShell. The embed
    // host site provides its own chrome.
    return <>{children}</>;
  }
  return (
    <div className="flex flex-col min-h-screen">
      <Navbar />
      <main className="flex-grow">
        <ErrorBoundary>{children}</ErrorBoundary>
      </main>
      <Footer />
      <PwaShell />
      <ConsentBanner />
    </div>
  );
}

export default function App() {
  return (
    <ErrorBoundary>
      {/* basename matches vite base '/bridge/' so client routes resolve under
          the unified-shell prefix (app.py /bridge → static/bridge/). */}
      <Router basename={((import.meta as any).env?.BASE_URL ?? '/').replace(/\/$/, '')}>
        <LanguageProvider>
        <ToastProvider>
          <AuthProvider>
            <OrganizationProvider>
              <ChromeLayout>
                <Suspense fallback={<RouteFallback />}>
                  <Routes>
                    <Route path="/" element={<Home />} />
                    <Route path="/event/:id" element={<EventDetails />} />
                    <Route path="/e/:slug" element={<SlugRedirect />} />
                    <Route path="/organizer/:id" element={<OrganizerProfile />} />
                    <Route path="/profile" element={<Profile />} />
                    <Route path="/my-tickets" element={<MyTickets />} />
                    <Route path="/alerts" element={<Notifications />} />
                    <Route path="/ticket/:id" element={<TicketDetail />} />
                    <Route path="/wallet/pass/:ticketId" element={<WalletPass />} />
                    <Route path="/transfer/:id" element={<TransferTicket />} />
                    <Route path="/claim/:transferId" element={<ClaimTicket />} />
                    <Route path="/dashboard" element={<OrganizerDashboard />} />
                    <Route path="/create-event" element={<CreateEvent />} />
                    <Route path="/checkin/:eventId" element={<OrganizerCheckIn />} />
                    <Route path="/dashboard/event/:eventId" element={<OrganizerEventReport />} />
                    <Route path="/dashboard/event/:eventId/promote" element={<PromoteEvent />} />
                    <Route path="/edit-event/:eventId" element={<EditEvent />} />
                    {/* Bridge multi-tenant org views (Sprint 1). */}
                    <Route path="/orgs" element={<Orgs />} />
                    <Route path="/orgs/new" element={<CreateOrg />} />
                    <Route path="/orgs/:orgId/settings" element={<OrgSettings />} />
                    <Route path="/orgs/:orgId/members" element={<OrgMembers />} />
                    <Route path="/orgs/:orgId/promote" element={<OrgPromote />} />
                    {/* Onboarding flow for new organizers (Sprint 6). */}
                    <Route path="/onboarding" element={<OrganizerOnboarding />} />
                    <Route path="/invite/:token" element={<ClaimInvite />} />
                    {/* White-label storefront (Sprint 2). Distinct from
                        /e/:slug (event slug) — /o/:slug resolves to an
                        org's branded landing page with their event list. */}
                    <Route path="/o/:slug" element={<OrgStorefront />} />
                    {/* Embed widget (Sprint 6) — chromeless event card for
                        venues to iframe on their own site. */}
                    <Route path="/embed/event/:eventId" element={<EmbedEvent />} />
                    <Route path="/privacy" element={<Privacy />} />
                    <Route path="/terms" element={<Terms />} />
                    <Route path="/status" element={<Status />} />
                    {/* 404 catch-all — punk "off the door list" screen. */}
                    <Route path="*" element={<NotFound />} />
                  </Routes>
                </Suspense>
              </ChromeLayout>
            </OrganizationProvider>
          </AuthProvider>
        </ToastProvider>
        </LanguageProvider>
      </Router>
    </ErrorBoundary>
  );
}

