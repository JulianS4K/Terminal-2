import { describe, it, expect } from 'vitest';
import {
  safeQrForeground,
  contrastVsWhite,
  qrLogoSettings,
  qrStyleFromBranding,
} from './qrStyle';

describe('safeQrForeground', () => {
  it('keeps a dark, high-contrast brand color', () => {
    expect(safeQrForeground('#0B1F3A')).toBe('#0B1F3A'); // navy
    expect(safeQrForeground('#111111')).toBe('#111111');
  });

  it('falls back to black for low-contrast (pale/bright) colors', () => {
    expect(safeQrForeground('#FFD400')).toBe('#000000'); // bright yellow
    expect(safeQrForeground('#EEEEEE')).toBe('#000000'); // near-white
  });

  it('normalizes a missing # and rejects garbage', () => {
    expect(safeQrForeground('0B1F3A')).toBe('#0B1F3A');
    expect(safeQrForeground('not-a-color')).toBe('#000000');
    expect(safeQrForeground(undefined)).toBe('#000000');
  });

  it('black and white are handled sanely', () => {
    expect(safeQrForeground('#000000')).toBe('#000000');
    expect(safeQrForeground('#FFFFFF')).toBe('#000000'); // white on white → black
  });
});

describe('contrastVsWhite', () => {
  it('black has the max ratio, white the min', () => {
    expect(contrastVsWhite('#000000')).toBeCloseTo(21, 0);
    expect(contrastVsWhite('#FFFFFF')).toBeCloseTo(1, 1);
  });
});

describe('qrLogoSettings', () => {
  it('caps the logo at 16% of the QR side and excavates', () => {
    const s = qrLogoSettings('https://cdn/logo.png', 260);
    expect(s).toBeDefined();
    expect(s!.width).toBe(Math.round(260 * 0.16));
    expect(s!.height).toBe(s!.width);
    expect(s!.excavate).toBe(true);
    expect(s!.src).toContain('logo.png');
  });

  it('is undefined without a logo', () => {
    expect(qrLogoSettings(undefined, 260)).toBeUndefined();
  });
});

describe('qrStyleFromBranding', () => {
  it('combines a safe color with a logo', () => {
    const style = qrStyleFromBranding({ primaryColor: '#0B1F3A', logoUrl: 'https://cdn/l.png' }, 220);
    expect(style.fgColor).toBe('#0B1F3A');
    expect(style.imageSettings?.width).toBe(Math.round(220 * 0.16));
  });

  it('defaults to black with no logo when branding is absent', () => {
    const style = qrStyleFromBranding(undefined, 220);
    expect(style.fgColor).toBe('#000000');
    expect(style.imageSettings).toBeUndefined();
  });
});
