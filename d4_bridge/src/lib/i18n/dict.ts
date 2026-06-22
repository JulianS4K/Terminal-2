// i18n dictionaries — English + Spanish (Hi.Events parity).
//
// Flat dot-keyed strings. Add a key to BOTH `en` and `es`. Interpolate with
// {name} placeholders; t(key, { name }) fills them. English is the fallback for
// any key missing from another locale. Buyer-facing surfaces are translated
// first; organizer/dashboard strings can be folded in incrementally by adding
// keys here and swapping literals for t('…') at the call site.

export type Lang = 'en' | 'es';

export const en = {
  'nav.myTickets': 'My Tickets',
  'nav.dashboard': 'Dashboard',
  'nav.signIn': 'Sign In',
  'nav.signOut': 'Sign Out',
  'nav.profile': 'Profile',

  'event.buy': 'Buy Tickets',
  'event.soldOut': 'Sold Out',
  'event.processing': 'Processing…',
  'event.available': 'Available',
  'event.free': 'Free',
  'event.comingSoonTitle': 'Coming soon',
  'event.comingSoon': 'Paid checkout is being wired up.',
  'event.slotsRemaining': '{n} slots remaining',

  'addon.title': 'Add-ons',

  'waitlist.join': 'Join the Waitlist',
  'waitlist.heading': 'Sold out — get notified if a spot opens',
  'waitlist.emailPlaceholder': 'you@email.com',
  'waitlist.namePlaceholder': 'Name (optional)',
  'waitlist.qty': 'Qty',
  'waitlist.notifyMe': 'Notify Me',
  'waitlist.joining': 'Joining…',
  'waitlist.onListTitle': "You're on the waitlist",
  'waitlist.position': "Position #{n} — we'll email you if a spot opens.",
  'waitlist.emailInvalid': 'Enter a valid email so we can notify you.',
  'waitlist.successTitle': "You're on the list",
  'waitlist.success': "We'll email {email} the moment a spot opens.",

  'common.cancel': 'Cancel',
} as const;

export type DictKey = keyof typeof en;

export const es: Record<DictKey, string> = {
  'nav.myTickets': 'Mis Entradas',
  'nav.dashboard': 'Panel',
  'nav.signIn': 'Iniciar Sesión',
  'nav.signOut': 'Cerrar Sesión',
  'nav.profile': 'Perfil',

  'event.buy': 'Comprar Entradas',
  'event.soldOut': 'Agotado',
  'event.processing': 'Procesando…',
  'event.available': 'Disponible',
  'event.free': 'Gratis',
  'event.comingSoonTitle': 'Próximamente',
  'event.comingSoon': 'El pago en línea se está habilitando.',
  'event.slotsRemaining': '{n} lugares disponibles',

  'addon.title': 'Complementos',

  'waitlist.join': 'Unirse a la Lista de Espera',
  'waitlist.heading': 'Agotado — recibe aviso si se libera un lugar',
  'waitlist.emailPlaceholder': 'tu@email.com',
  'waitlist.namePlaceholder': 'Nombre (opcional)',
  'waitlist.qty': 'Cant.',
  'waitlist.notifyMe': 'Avísame',
  'waitlist.joining': 'Uniéndose…',
  'waitlist.onListTitle': 'Estás en la lista de espera',
  'waitlist.position': 'Posición #{n} — te enviaremos un correo si se libera un lugar.',
  'waitlist.emailInvalid': 'Ingresa un correo válido para poder avisarte.',
  'waitlist.successTitle': 'Estás en la lista',
  'waitlist.success': 'Te enviaremos un correo a {email} en cuanto se libere un lugar.',

  'common.cancel': 'Cancelar',
};

export const DICTS: Record<Lang, Record<DictKey, string>> = { en, es };
