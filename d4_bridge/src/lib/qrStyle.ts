// Exos (Bridge / D4) — brand-customizable QR styling, within scanner limits.
//
// Lets an org brand the entry QR (its color + a center logo) instead of a plain
// black square — a lighter-weight alternative to PDF tickets. The hard rule
// from the scanner-limits work still governs: decoration must never cost
// contrast or intrude on the finder patterns / quiet zone, or cheap phone
// cameras stop reading it. So this module is deliberately conservative:
//
//   * Foreground color is only honored if it clears a WCAG-AA (4.5:1) contrast
//     ratio against white; otherwise it falls back to black. A pale or mid brand
//     color can't be forced onto the modules.
//   * A center logo is allowed ONLY because the pass renders at error-correction
//     level H (~30% recoverable). The logo is capped at ~16% of the QR's side
//     (~2.5% area) and excavated (modules cleared beneath it), well inside H's
//     budget, so the code still decodes with the logo present.
//   * The quiet zone (marginSize) and black-on-light contrast of the finder
//     patterns are never touched here.

export interface QrImageSettings {
  src: string;
  height: number;
  width: number;
  excavate: boolean;
}

export interface QrStyle {
  fgColor: string;
  imageSettings?: QrImageSettings;
}

interface Branding {
  primaryColor?: string;
  accentColor?: string;
  logoUrl?: string;
}

function parseHex(hex: string): [number, number, number] | null {
  const m = /^#?([0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return null;
  const n = m[1];
  return [parseInt(n.slice(0, 2), 16), parseInt(n.slice(2, 4), 16), parseInt(n.slice(4, 6), 16)];
}

/** WCAG relative luminance of an sRGB color (0 = black, 1 = white). */
export function relativeLuminance(hex: string): number | null {
  const rgb = parseHex(hex);
  if (!rgb) return null;
  const lin = rgb.map((v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

/** Contrast ratio of a color against white (QR background). */
export function contrastVsWhite(hex: string): number | null {
  const l = relativeLuminance(hex);
  if (l === null) return null;
  return (1.0 + 0.05) / (l + 0.05);
}

/**
 * A foreground color safe to print the QR in: the brand color if it clears
 * 4.5:1 against white, else black. Never returns a low-contrast color — that
 * would make the code unscannable on cheap cameras.
 */
export function safeQrForeground(hex?: string): string {
  if (!hex) return '#000000';
  const ratio = contrastVsWhite(hex);
  if (ratio !== null && ratio >= 4.5) return hex.startsWith('#') ? hex : `#${hex}`;
  return '#000000';
}

/**
 * Center-logo settings for a QR of the given pixel size, or undefined when
 * there's no logo. Capped at 16% of the side and excavated so it stays inside
 * the level-H error-correction budget.
 */
export function qrLogoSettings(logoUrl: string | undefined, size: number): QrImageSettings | undefined {
  if (!logoUrl) return undefined;
  const side = Math.round(size * 0.16);
  return { src: logoUrl, height: side, width: side, excavate: true };
}

/** Full QR style (color + optional logo) derived from an org's branding. */
export function qrStyleFromBranding(branding: Branding | undefined, size: number): QrStyle {
  return {
    fgColor: safeQrForeground(branding?.primaryColor),
    imageSettings: qrLogoSettings(branding?.logoUrl, size),
  };
}
