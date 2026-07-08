// Share an event as a composed story POSTER (not just a link) to
// Instagram/Stories etc.
//
// What this does, in order of capability:
//   1. COMPOSE a 1080×1920 story poster on a canvas — punk/xerox Exos
//      language: wall-black bg with neon corner glows, grayscale-xerox event
//      art, Anton ransom title, Special Elite date/venue line, EXOS footer +
//      event URL. Falls back to a text-only poster when the art can't be
//      fetched (CORS/offline), and to the raw event image if canvas fails.
//   2. SHARE the poster via the Web Share API with files
//      (navigator.share({ files })) — on mobile, picking Instagram lands the
//      image straight in a Story draft. This is the only image hand-off a
//      web/PWA app has: the native ADD_TO_STORY intent / instagram-stories://
//      pasteboard flows in Meta's docs require a native app + FB App ID.
//   3. Otherwise DOWNLOAD the poster and open Instagram's story composer via
//      the documented universal link (https://www.instagram.com/create/story)
//      so the user can pick the freshly saved image.
//
// We also always copy the event URL to the clipboard so the user can drop it
// into a link sticker. This is the shared implementation behind the
// "Instagram / Story" buttons on both the ticket page and the public event
// page. True API-side publishing to an ORG's own Instagram (Instagram API
// with Instagram Login: POST /me/media + media_publish, insights) is a
// server-side feature that needs a Meta app + org OAuth tokens — tracked
// separately; this module is the fan-side share path.

import type { ToastFn } from './utils';

interface StoryShareInput {
  title: string;
  url: string;
  imageUrl?: string | null;
  /** Pre-formatted date line, e.g. "FRI 11 JUL · 11:00 PM". Optional. */
  dateLabel?: string;
  /** Venue / location line. Optional. */
  venue?: string;
}

const W = 1080;
const H = 1920;
const NEON = '#00FF00';
const MAGENTA = '#FF00FF';

function fileSlug(s: string): string {
  return s.replace(/[^a-z0-9]+/gi, '-').toLowerCase().replace(/^-+|-+$/g, '').slice(0, 40) || 'event';
}

/** Fetch the event art as an ImageBitmap without tainting the canvas.
 *  Returns null on any failure — the poster then renders text-only. */
async function loadArt(imageUrl: string): Promise<ImageBitmap | null> {
  try {
    const res = await fetch(imageUrl, { mode: 'cors' });
    if (!res.ok) return null;
    const blob = await res.blob();
    return await createImageBitmap(blob);
  } catch {
    return null;
  }
}

/** Wrap `text` into at most `maxLines` lines that fit `maxWidth`. */
function wrapLines(
  ctx: CanvasRenderingContext2D,
  text: string,
  maxWidth: number,
  maxLines: number,
): string[] {
  const words = text.toUpperCase().split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let line = '';
  for (const w of words) {
    const probe = line ? `${line} ${w}` : w;
    if (ctx.measureText(probe).width <= maxWidth || !line) {
      line = probe;
    } else {
      lines.push(line);
      line = w;
      if (lines.length === maxLines - 1) break;
    }
  }
  if (line && lines.length < maxLines) lines.push(line);
  // Ellipsize if we dropped words.
  const used = lines.join(' ').split(/\s+/).length;
  if (used < words.length && lines.length > 0) {
    lines[lines.length - 1] = `${lines[lines.length - 1]}…`;
  }
  return lines;
}

/**
 * Compose the 1080×1920 story poster. Returns a PNG blob, or null when the
 * canvas pipeline isn't available (caller falls back to the raw image).
 */
export async function composeStoryPoster(input: StoryShareInput): Promise<Blob | null> {
  try {
    const canvas = document.createElement('canvas');
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;

    // Make sure the display faces are usable on canvas (already loaded
    // app-wide via Google Fonts; this just awaits readiness, best-effort).
    try {
      await Promise.race([
        Promise.all([
          (document as any).fonts?.load('700 120px Anton'),
          (document as any).fonts?.load('400 40px "Special Elite"'),
        ]),
        new Promise((r) => setTimeout(r, 1500)),
      ]);
    } catch {
      /* fall through — canvas falls back to sans-serif */
    }

    // ---- Wall background: near-black + neon corner glows ----
    ctx.fillStyle = '#050505';
    ctx.fillRect(0, 0, W, H);
    let g = ctx.createRadialGradient(W * 0.9, 0, 0, W * 0.9, 0, W * 0.8);
    g.addColorStop(0, 'rgba(0,255,0,0.10)');
    g.addColorStop(1, 'rgba(0,255,0,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
    g = ctx.createRadialGradient(0, H, 0, 0, H, W * 0.9);
    g.addColorStop(0, 'rgba(255,0,255,0.09)');
    g.addColorStop(1, 'rgba(255,0,255,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    // ---- Xerox event art block (center-cropped, grayscale, framed) ----
    const art = input.imageUrl ? await loadArt(input.imageUrl) : null;
    const artX = 90;
    const artY = 300;
    const artW = W - 180;
    const artH = 900;
    if (art) {
      ctx.save();
      // ctx.filter is supported in every browser that runs this app; if the
      // engine ignores it we just get the color image — acceptable.
      ctx.filter = 'grayscale(1) contrast(1.45) brightness(1.05)';
      const scale = Math.max(artW / art.width, artH / art.height);
      const dw = art.width * scale;
      const dh = art.height * scale;
      ctx.beginPath();
      ctx.rect(artX, artY, artW, artH);
      ctx.clip();
      ctx.drawImage(art, artX + (artW - dw) / 2, artY + (artH - dh) / 2, dw, dh);
      ctx.restore();
      // Fade the art into the wall at the bottom so the title sits on black.
      const fade = ctx.createLinearGradient(0, artY + artH - 320, 0, artY + artH);
      fade.addColorStop(0, 'rgba(5,5,5,0)');
      fade.addColorStop(1, 'rgba(5,5,5,1)');
      ctx.fillStyle = fade;
      ctx.fillRect(artX, artY, artW, artH);
      // Frame.
      ctx.strokeStyle = 'rgba(255,255,255,0.18)';
      ctx.lineWidth = 3;
      ctx.strokeRect(artX, artY, artW, artH);
    }

    // ---- Kicker ----
    ctx.textBaseline = 'alphabetic';
    ctx.fillStyle = NEON;
    ctx.font = '400 34px "Special Elite", monospace';
    ctx.fillText('// YOUR NEXT NIGHT', 90, 220);

    // ---- Title: Anton ransom caps, skewed, neon glow on the last line ----
    const titleTop = art ? artY + artH + 60 : 640;
    ctx.save();
    ctx.transform(1, 0, -0.07, 1, 0, 0); // skewX(-4deg)-ish
    ctx.font = '400 118px Anton, "Archivo Black", sans-serif';
    const lines = wrapLines(ctx, input.title, W - 220, 3);
    lines.forEach((line, i) => {
      const y = titleTop + i * 128;
      const last = i === lines.length - 1;
      if (last) {
        ctx.shadowColor = 'rgba(0,255,0,0.55)';
        ctx.shadowBlur = 28;
        ctx.fillStyle = NEON;
      } else {
        ctx.shadowBlur = 0;
        ctx.fillStyle = '#f5f5f5';
      }
      // Compensate x for the skew so text stays inside the frame.
      ctx.fillText(line, 100 + y * 0.07, y);
    });
    ctx.restore();

    // ---- Date / venue (typewriter) ----
    const metaY = titleTop + lines.length * 128 + 40;
    ctx.shadowBlur = 0;
    ctx.font = '400 40px "Special Elite", monospace';
    ctx.fillStyle = 'rgba(255,255,255,0.82)';
    if (input.dateLabel) ctx.fillText(input.dateLabel.toUpperCase(), 100, metaY);
    if (input.venue) {
      ctx.fillStyle = 'rgba(255,255,255,0.55)';
      ctx.fillText(input.venue.toUpperCase().slice(0, 44), 100, metaY + 58);
    }

    // ---- Marker scrawl accent ----
    ctx.save();
    ctx.translate(W - 150, 180);
    ctx.rotate(-0.09);
    ctx.font = '400 44px "Permanent Marker", cursive';
    ctx.fillStyle = MAGENTA;
    ctx.textAlign = 'right';
    ctx.fillText('real tickets only →', 0, 0);
    ctx.restore();

    // ---- Footer: EXOS mark + URL ----
    ctx.textAlign = 'left';
    ctx.fillStyle = NEON;
    ctx.font = '400 52px Anton, sans-serif';
    ctx.fillText('◤ EXOS', 100, H - 150);
    ctx.font = '400 30px "Special Elite", monospace';
    ctx.fillStyle = 'rgba(255,255,255,0.5)';
    ctx.fillText('SECURE TICKETING · LINK IN STICKER', 100, H - 96);
    ctx.fillStyle = 'rgba(255,255,255,0.75)';
    const shortUrl = input.url.replace(/^https?:\/\//, '');
    ctx.fillText(shortUrl.slice(0, 52), 100, H - 48);

    return await new Promise<Blob | null>((resolve) =>
      canvas.toBlob((b) => resolve(b), 'image/png'),
    );
  } catch (err) {
    console.warn('Poster compose failed; will fall back to raw image:', err);
    return null;
  }
}

/** Trigger a browser download of the blob. */
function downloadBlob(blob: Blob, filename: string): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 30_000);
}

export async function shareEventToStory(input: StoryShareInput, toast?: ToastFn): Promise<void> {
  const { title, url } = input;

  // Always copy the URL — that's the link-sticker hand-off regardless of path.
  try {
    await navigator.clipboard.writeText(url);
  } catch {
    /* clipboard may be blocked in some contexts; non-fatal */
  }

  // 1) Compose the poster; fall back to the raw event image bytes.
  let blob = await composeStoryPoster(input);
  let ext = 'png';
  if (!blob && input.imageUrl) {
    try {
      const res = await fetch(input.imageUrl);
      if (res.ok) {
        blob = await res.blob();
        ext = blob.type === 'image/png' ? 'png' : blob.type === 'image/webp' ? 'webp' : 'jpg';
      }
    } catch {
      /* no image at all — link-only fallback below */
    }
  }

  const nav = navigator as Navigator & {
    canShare?: (data?: unknown) => boolean;
    share?: (data?: unknown) => Promise<void>;
  };

  // 2) Web Share API with the file — mobile lands it straight in an IG Story draft.
  if (blob && typeof nav.canShare === 'function' && typeof nav.share === 'function') {
    try {
      const file = new File([blob], `${fileSlug(title)}-story.${ext}`, {
        type: blob.type || 'image/png',
      });
      const data = { files: [file], title, text: `${title} — get tickets`, url };
      if (nav.canShare(data)) {
        await nav.share(data);
        toast?.({
          kind: 'success',
          title: 'Poster ready to post',
          message:
            'In Instagram: pick the poster, add a link sticker, and paste — the URL is on your clipboard.',
          duration: 8000,
        });
        return;
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : '';
      if (/abort/i.test(msg)) return; // user dismissed the share sheet — stay quiet
      console.warn('Story poster share failed; falling back to download:', err);
    }
  }

  // 3) Desktop / no file-share: download the poster + open IG's story composer
  //    (documented universal link) so the user can pick the saved image.
  if (blob) {
    downloadBlob(blob, `${fileSlug(title)}-story.${ext}`);
    window.open('https://www.instagram.com/create/story', '_blank', 'noopener');
    toast?.({
      kind: 'success',
      title: 'Poster downloaded',
      message:
        'Instagram is opening — choose the downloaded poster, add a link sticker, and paste (URL is on your clipboard).',
      duration: 9000,
    });
    return;
  }

  // 4) No image at all: the link is already on the clipboard.
  toast?.({ kind: 'success', message: 'Event link copied — paste it into your Story.' });
}
