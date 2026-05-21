// ThemeContext — surfaces the active org's white-label theme as CSS
// variables on the document root. Sits inside OrganizationContext.
//
// The variables we expose:
//   --bridge-primary    — primary accent (replaces the global brand-primary
//                         where buyer-facing pages opt in via tailwind config).
//   --bridge-accent     — secondary accent.
//   --bridge-logo-url   — the org's logo. Components can read it via
//                         `var(--bridge-logo-url)` for background-image.
//
// This sprint applies theme to org-scoped surfaces only; the public
// home page stays neutral. When a buyer lands on /o/:slug or /event/:id
// for an event whose orgId resolves to a themed org, the theme kicks
// in. When viewing the platform shell (Home, MyTickets, etc.) the
// platform default holds.
//
// Implementation note: we set variables on a wrapper div rather than
// document.documentElement so the platform shell doesn't get retinted
// when an org viewer navigates back to /. The wrapper goes around the
// branded route region in App.tsx.

import { CSSProperties, createContext, useContext, useMemo, ReactNode } from 'react';
import { Organization } from '../types';

export interface ResolvedTheme {
  primary: string;
  accent: string;
  logoUrl: string | null;
}

const PLATFORM_DEFAULT_THEME: ResolvedTheme = {
  // These match the existing tailwind brand-primary/brand-accent so
  // platform-default surfaces don't shift when ThemeProvider is mounted.
  primary: '#FFE714',
  accent: '#1A1A1A',
  logoUrl: null,
};

interface ThemeContextType {
  theme: ResolvedTheme;
  // CSS-variable map suitable for spreading onto a div's `style` prop.
  cssVars: CSSProperties;
}

const ThemeContext = createContext<ThemeContextType | undefined>(undefined);

export function resolveTheme(org: Organization | null | undefined): ResolvedTheme {
  if (!org?.theme) return PLATFORM_DEFAULT_THEME;
  return {
    primary: sanitizeColor(org.theme.primaryColor) ?? PLATFORM_DEFAULT_THEME.primary,
    accent: sanitizeColor(org.theme.accentColor) ?? PLATFORM_DEFAULT_THEME.accent,
    logoUrl: sanitizeLogoUrl(org.theme.logoUrl),
  };
}

/**
 * Reject anything that isn't an HTTPS URL pointing at a same-class
 * host. Defense in depth — Firebase Storage download URLs are
 * already origin-locked, but in case Storage rules ever loosen or a
 * compromised admin writes an arbitrary value, this prevents
 * `javascript:`, `data:`, or any non-HTTPS URL from ending up in
 * a CSS `url(...)` or an `<img src>`. Also returns null for empty
 * strings and non-string values so the caller can fall through to
 * "no logo" rendering.
 */
function sanitizeLogoUrl(value: string | undefined | null): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  try {
    const url = new URL(trimmed);
    if (url.protocol !== 'https:') return null;
    return trimmed;
  } catch {
    return null;
  }
}

/**
 * Reject anything that isn't a hex color (#rgb / #rrggbb) — keeps
 * malicious org docs from injecting arbitrary CSS via the variable.
 */
function sanitizeColor(value: string | undefined | null): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (/^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$/.test(trimmed)) return trimmed;
  return null;
}

interface ThemeProviderProps {
  org: Organization | null | undefined;
  children: ReactNode;
}

/**
 * Wrap a route region with this to apply the org's theme. Pass the
 * resolved Organization (or null for platform default).
 */
export function ThemeProvider({ org, children }: ThemeProviderProps) {
  const theme = useMemo(() => resolveTheme(org), [org]);

  const cssVars = useMemo<CSSProperties>(
    () => ({
      // The CSS-variable cast is needed because React's style typing
      // doesn't know about custom properties.
      ['--bridge-primary' as any]: theme.primary,
      ['--bridge-accent' as any]: theme.accent,
      ...(theme.logoUrl ? { ['--bridge-logo-url' as any]: `url(${theme.logoUrl})` } : {}),
    }),
    [theme],
  );

  return (
    <ThemeContext.Provider value={{ theme, cssVars }}>
      <div style={cssVars} className="contents">
        {children}
      </div>
    </ThemeContext.Provider>
  );
}

export function useTheme() {
  const ctx = useContext(ThemeContext);
  // Falling back to defaults rather than throwing — many surfaces
  // render outside ThemeProvider (Home, MyTickets, the auth modal),
  // and they should keep working.
  if (!ctx) return { theme: PLATFORM_DEFAULT_THEME, cssVars: {} as CSSProperties };
  return ctx;
}
