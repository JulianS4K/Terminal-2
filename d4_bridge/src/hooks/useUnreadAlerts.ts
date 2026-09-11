// Unread-alert count for the navbar bell.
//
// Reuses the /alerts feed builder (lib/notifications) and the server-side
// read-state so the badge and the page always agree. Refreshes on mount, when
// the tab regains focus, and every 5 minutes — cheap enough (a handful of
// RLS-scoped selects) and no realtime subscription to babysit. Best-effort:
// a failed refresh keeps the last count rather than flashing 0.

import { useEffect, useState } from 'react';
import { listNotifications, listReadNotificationIds } from '../lib/notifications';

const REFRESH_MS = 5 * 60_000;

export function useUnreadAlerts(enabled: boolean): number {
  const [count, setCount] = useState(0);

  useEffect(() => {
    if (!enabled) {
      setCount(0);
      return undefined;
    }
    let cancelled = false;
    const refresh = async () => {
      try {
        const [feed, read] = await Promise.all([listNotifications(), listReadNotificationIds()]);
        if (cancelled) return;
        setCount(feed.items.filter((n) => n.unread && !read.has(n.id)).length);
      } catch (err) {
        console.warn('useUnreadAlerts refresh failed', err);
      }
    };
    void refresh();
    const timer = window.setInterval(refresh, REFRESH_MS);
    const onFocus = () => void refresh();
    window.addEventListener('focus', onFocus);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      window.removeEventListener('focus', onFocus);
    };
  }, [enabled]);

  return count;
}
