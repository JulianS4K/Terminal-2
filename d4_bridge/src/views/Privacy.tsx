import { Shield, Lock, Eye, FileText, ArrowLeft } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

export default function Privacy() {
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
          <Shield className="text-brand-primary w-6 h-6" />
        </div>
        <h1 className="disp text-5xl md:text-7xl leading-[0.9]" style={{ transform: 'skewX(-4deg)' }}>
          PRIVACY<br />
          <span className="text-brand-primary">POLICY</span>
        </h1>
      </div>

      <div className="mt-8">
        <p className="type text-white/60 leading-relaxed mb-8 text-[15px]">
          At Exos, we take your security and privacy seriously. This policy outlines how we handle your digital assets and personal identification.
        </p>

        <section className="mb-12">
          <h2 className="disp text-2xl md:text-3xl mt-12 mb-3 text-white flex items-center" style={{ transform: 'skewX(-4deg)' }}>
            <Eye className="w-6 h-6 mr-3 text-brand-primary shrink-0" />
            1. Data Collection
          </h2>
          <p className="type text-white/60 leading-relaxed mb-3 text-[15px]">
            We collect minimal information necessary to secure your tickets and verify your identity at events. This includes your name, email, and transaction history.
          </p>
        </section>

        <section className="mb-12">
          <h2 className="disp text-2xl md:text-3xl mt-12 mb-3 text-white flex items-center" style={{ transform: 'skewX(-4deg)' }}>
            <Lock className="w-6 h-6 mr-3 text-brand-primary shrink-0" />
            2. Security Protocols
          </h2>
          <p className="type text-white/60 leading-relaxed mb-3 text-[15px]">
            All barcodes are generated using rotating cryptographic keys. We do not store your raw private keys; only the necessary hashes to verify entry.
          </p>
        </section>

        <section className="mb-12">
          <h2 className="disp text-2xl md:text-3xl mt-12 mb-3 text-white flex items-center" style={{ transform: 'skewX(-4deg)' }}>
            <FileText className="w-6 h-6 mr-3 text-brand-primary shrink-0" />
            3. Data Retention
          </h2>
          <p className="type text-white/60 leading-relaxed mb-3 text-[15px]">
            Transaction records are kept for audit purposes and to facilitate transfers. You can request account deletion at any time through our help center.
          </p>
        </section>
      </div>
    </div>
  );
}
