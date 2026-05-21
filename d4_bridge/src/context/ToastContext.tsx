import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

// Lightweight, dependency-free toast system. Replaces blocking alert() calls
// throughout the app — alert() pauses the JS thread, can't be styled, and
// can't be tested. This module exposes a single useToast() hook.

export type ToastKind = 'info' | 'success' | 'warn' | 'error';

export interface ToastOptions {
  kind?: ToastKind;
  title?: string;
  message: string;
  // ms to auto-dismiss; 0 means stay until the user closes it.
  duration?: number;
}

interface ToastRecord extends Required<Omit<ToastOptions, 'title'>> {
  id: number;
  title?: string;
}

interface ToastContextType {
  toast: (opts: ToastOptions) => void;
  dismiss: (id: number) => void;
}

const ToastContext = createContext<ToastContextType | undefined>(undefined);

const KIND_STYLES: Record<ToastKind, string> = {
  info: 'bg-slate-900 text-white',
  success: 'bg-emerald-600 text-white',
  warn: 'bg-amber-500 text-white',
  error: 'bg-red-600 text-white',
};

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<ToastRecord[]>([]);
  const idRef = useRef(0);
  // Track each toast's auto-dismiss timer so we can clear them on unmount
  // and avoid a setState-after-unmount warning during fast navigations.
  const timers = useRef<Record<number, ReturnType<typeof setTimeout>>>({});

  const dismiss = useCallback((id: number) => {
    setToasts((current) => current.filter((t) => t.id !== id));
    const handle = timers.current[id];
    if (handle) {
      clearTimeout(handle);
      delete timers.current[id];
    }
  }, []);

  const toast = useCallback(
    (opts: ToastOptions) => {
      const id = ++idRef.current;
      const record: ToastRecord = {
        id,
        kind: opts.kind ?? 'info',
        message: opts.message,
        duration: opts.duration ?? 5000,
        title: opts.title,
      };
      setToasts((current) => [...current, record]);
      if (record.duration > 0) {
        timers.current[id] = setTimeout(() => dismiss(id), record.duration);
      }
    },
    [dismiss]
  );

  // Clean up any pending timers on unmount.
  useEffect(() => {
    const map = timers.current;
    return () => {
      Object.values(map).forEach(clearTimeout);
    };
  }, []);

  const value = useMemo(() => ({ toast, dismiss }), [toast, dismiss]);

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div
        // aria-live=polite so screen readers announce non-blocking toasts.
        aria-live="polite"
        aria-atomic="true"
        className="fixed bottom-4 right-4 z-[9999] flex flex-col gap-2 max-w-sm pointer-events-none"
      >
        {toasts.map((t) => (
          <div
            key={t.id}
            role={t.kind === 'error' ? 'alert' : 'status'}
            className={`pointer-events-auto rounded-2xl shadow-2xl px-5 py-4 ${KIND_STYLES[t.kind]} animate-[fadeIn_120ms_ease-out]`}
          >
            <div className="flex items-start gap-3">
              <div className="flex-1">
                {t.title && (
                  <p className="text-[10px] font-black uppercase tracking-widest mb-1 opacity-80">
                    {t.title}
                  </p>
                )}
                <p className="text-sm font-medium leading-snug">{t.message}</p>
              </div>
              <button
                onClick={() => dismiss(t.id)}
                aria-label="Dismiss notification"
                className="text-white/70 hover:text-white text-sm leading-none ml-2"
              >
                ×
              </button>
            </div>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast() {
  const ctx = useContext(ToastContext);
  if (!ctx) {
    throw new Error('useToast must be used within a ToastProvider');
  }
  return ctx;
}
