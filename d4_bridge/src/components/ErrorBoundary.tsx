import { Component, ErrorInfo, ReactNode } from 'react';

interface Props {
  children: ReactNode;
  // Optional override fallback. Defaults to the friendly screen below.
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error?: Error;
}

/**
 * Top-level error boundary.
 *
 * Catches:
 *   - Render errors from any descendant component.
 *   - Lazy-chunk load failures (route-level React.lazy() throws on failed
 *     dynamic import — without this boundary the user sees a blank page).
 *
 * Does NOT catch:
 *   - Async errors thrown outside the render tree (those need a try/catch in
 *     the caller — that's the contract for handleFirestoreError + toasts).
 *   - Event-handler errors.
 */
// NOTE: this project doesn't install @types/react, so `Component<Props, State>`
// resolves to `any` and TS doesn't synthesize `this.props`/`this.state` for us.
// We declare them manually below — `declare` keeps them type-only and emits
// no JS, while satisfying the type checker.
export default class ErrorBoundary extends Component<Props, State> {
  declare props: Props;
  declare state: State;

  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Replace this with a structured log forwarder (Sentry, Datadog, etc.)
    // when one is wired in.
    console.error('Uncaught render error:', error, info.componentStack);
  }

  private handleReload = () => {
    // A full reload is the right escape hatch for a chunk-load failure or
    // a corrupted SPA state — preserves the URL, drops in-memory garbage.
    window.location.reload();
  };

  render() {
    if (!this.state.hasError) return this.props.children;
    if (this.props.fallback) return this.props.fallback;

    // Punk "500 / something broke" treatment from the Exos design set —
    // glitch numerals, marker scrawl, neon headline.
    return (
      <div
        role="alert"
        className="wall min-h-screen text-white flex flex-col items-center justify-center px-6 text-center"
      >
        <p
          className="disp glitch text-[24vw] md:text-[180px] leading-[0.8] tracking-tight"
          style={{ transform: 'skewX(-4deg)' }}
        >
          500
        </p>
        <span
          className="marker text-brand-secondary text-2xl md:text-3xl -mt-2 mb-6"
          style={{ transform: 'rotate(5deg)' }}
        >
          the sound guy blew a fuse
        </span>
        <h1 className="disp text-3xl md:text-5xl tracking-tight mb-4" style={{ transform: 'skewX(-4deg)' }}>
          SOMETHING <span className="neon">BROKE</span>
        </h1>
        <p className="type text-white/55 text-base max-w-md mb-9 leading-relaxed">
          That&apos;s on us, not you. The error has been logged and our crew&apos;s already on it —
          give it a second and try again.
        </p>
        <button
          onClick={this.handleReload}
          className="disp bg-brand-primary text-black px-7 py-3 text-lg tracking-wide hover:scale-[1.02] transition-transform"
        >
          RELOAD
        </button>
      </div>
    );
  }
}
