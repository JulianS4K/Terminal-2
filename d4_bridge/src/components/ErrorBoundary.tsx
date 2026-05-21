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

    return (
      <div
        role="alert"
        className="min-h-screen bg-[#000] text-white flex items-center justify-center px-6"
      >
        <div className="max-w-md text-center">
          <p className="text-brand-primary text-xs font-black uppercase tracking-widest italic mb-4">
            Something went wrong
          </p>
          <h1 className="text-3xl font-black uppercase italic tracking-tighter leading-none mb-6">
            We couldn&apos;t load this view.
          </h1>
          <p className="text-white/60 text-sm font-medium mb-10 leading-relaxed">
            The error has been logged. Reloading the page usually clears
            transient issues — if not, please come back in a moment.
          </p>
          <button
            onClick={this.handleReload}
            className="bg-brand-primary text-black px-8 py-4 font-black uppercase tracking-widest text-xs hover:bg-white transition-all"
          >
            Reload
          </button>
        </div>
      </div>
    );
  }
}
