import { Scale, AlertCircle, CheckCircle2, FileText, ArrowLeft } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

export default function Terms() {
  const navigate = useNavigate();

  return (
    <div className="max-w-3xl mx-auto px-4 py-14 md:py-20">
      <button
        onClick={() => navigate(-1)}
        className="type inline-flex items-center text-white/40 hover:text-brand-primary mb-10 transition-colors uppercase tracking-[0.3em] text-[11px]"
      >
        <ArrowLeft className="w-4 h-4 mr-2" />
        Back
      </button>

      <p className="type text-brand-primary text-xs tracking-[0.3em] uppercase mb-4">// legal</p>
      <div className="flex items-center gap-4 mb-3">
        <div className="w-12 h-12 bg-brand-primary/10 border border-brand-primary/30 flex items-center justify-center shrink-0">
          <Scale className="text-brand-primary w-6 h-6" />
        </div>
        <h1 className="disp text-5xl md:text-7xl leading-[0.9]" style={{ transform: 'skewX(-4deg)' }}>
          TERMS OF<br />
          <span className="text-brand-primary">SERVICE</span>
        </h1>
      </div>

      <div className="mt-8">
        <p className="type text-white/60 leading-relaxed mb-8 text-[15px]">
          Access to Exos and its services is governed by these terms. By using our platform, you agree to our secure ticketing protocols.
        </p>

        <section className="mb-12">
          <h2 className="disp text-2xl md:text-3xl mt-12 mb-3 text-white flex items-center" style={{ transform: 'skewX(-4deg)' }}>
            <CheckCircle2 className="w-6 h-6 mr-3 text-brand-primary shrink-0" />
            1. Authorized Use
          </h2>
          <p className="type text-white/60 leading-relaxed mb-3 text-[15px]">
            Exos is intended for authorized ticket holders and event organizers. Use of automated tools to scrape or exploit the platform is strictly prohibited.
          </p>
        </section>

        <section className="mb-12">
          <h2 className="disp text-2xl md:text-3xl mt-12 mb-3 text-white flex items-center" style={{ transform: 'skewX(-4deg)' }}>
            <AlertCircle className="w-6 h-6 mr-3 text-brand-primary shrink-0" />
            2. Transfer Policy
          </h2>
          <p className="type text-white/60 leading-relaxed mb-3 text-[15px]">
            Tickets may only be transferred through the official Exos interface. Transfers made outside the platform may result in invalidation of the digital asset.
          </p>
        </section>

        <section className="mb-12">
          <h2 className="disp text-2xl md:text-3xl mt-12 mb-3 text-white flex items-center" style={{ transform: 'skewX(-4deg)' }}>
            <FileText className="w-6 h-6 mr-3 text-brand-primary shrink-0" />
            3. Refund &amp; Cancellation
          </h2>
          <p className="type text-white/60 leading-relaxed mb-3 text-[15px]">
            Refund policies are set by individual event organizers. Exos facilitates the transaction but is not responsible for event cancellations or modifications.
          </p>
        </section>
      </div>
    </div>
  );
}
