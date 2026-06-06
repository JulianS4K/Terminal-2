// Share an event as a poster IMAGE (not just a link) to Instagram/Stories etc.
//
// Mobile share sheets accept image files via the Web Share API
// (navigator.share({ files })) — picking Instagram lands the image straight in
// a Story draft. We also copy the event URL to the clipboard so the user can
// drop it into a link sticker. Desktop / no-file-share / no-image / fetch
// errors fall back to a copied link.
//
// This is the shared implementation behind the "Instagram / Story" buttons on
// both the ticket page and the public event page.

import type { ToastFn } from './utils';

interface StoryShareInput {
  title: string;
  url: string;
  imageUrl?: string | null;
}

function fileSlug(s: string): string {
  return s.replace(/[^a-z0-9]+/gi, '-').toLowerCase().replace(/^-+|-+$/g, '').slice(0, 40) || 'event';
}

export async function shareEventToStory(input: StoryShareInput, toast?: ToastFn): Promise<void> {
  const { title, url, imageUrl } = input;

  // Always copy the URL — that's the link-sticker hand-off regardless of path.
  try {
    await navigator.clipboard.writeText(url);
  } catch {
    /* clipboard may be blocked in some contexts; non-fatal */
  }

  const nav = navigator as Navigator & {
    canShare?: (data?: unknown) => boolean;
    share?: (data?: unknown) => Promise<void>;
  };

  if (imageUrl && typeof nav.canShare === 'function' && typeof nav.share === 'function') {
    try {
      const res = await fetch(imageUrl);
      if (!res.ok) throw new Error(`image fetch failed: ${res.status}`);
      const blob = await res.blob();
      const ext =
        blob.type === 'image/png' ? 'png' :
        blob.type === 'image/webp' ? 'webp' : 'jpg';
      const file = new File([blob], `${fileSlug(title)}.${ext}`, { type: blob.type || 'image/jpeg' });
      const data = { files: [file], title, text: `${title} — get tickets`, url };
      if (nav.canShare(data)) {
        await nav.share(data);
        toast?.({
          kind: 'success',
          title: 'Image ready to post',
          message: 'In Instagram: pick this image, add a link sticker, and paste — the URL is on your clipboard.',
          duration: 8000,
        });
        return;
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : '';
      if (/abort/i.test(msg)) return; // user dismissed the share sheet — stay quiet
      console.warn('Story image share failed; falling back to link copy:', err);
    }
  }

  // Fallback: the link is already on the clipboard.
  toast?.({ kind: 'success', message: 'Event link copied — paste it into your Story.' });
}
