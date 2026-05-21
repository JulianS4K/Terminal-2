import { loadStripe, Stripe } from '@stripe/stripe-js';

// Stripe lives in its own module so that views which only need helpers like
// formatCurrency (Home, MyTickets, OrganizerDashboard) don't drag the Stripe
// SDK into the initial bundle. Only EventDetails currently calls getStripe().
let stripePromise: Promise<Stripe | null> | undefined;

export const getStripe = () => {
  if (!stripePromise) {
    const key = (import.meta as any).env?.VITE_STRIPE_PUBLISHABLE_KEY;
    if (!key) {
      console.warn('VITE_STRIPE_PUBLISHABLE_KEY not set. Checkout will fail.');
    }
    stripePromise = loadStripe(key || '');
  }
  return stripePromise;
};
