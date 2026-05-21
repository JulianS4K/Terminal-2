import { Shield, Lock, Eye, FileText, ArrowLeft } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

export default function Privacy() {
  const navigate = useNavigate();
  
  return (
    <div className="max-w-4xl mx-auto px-4 py-20">
      <button onClick={() => navigate(-1)} className="flex items-center text-slate-400 hover:text-slate-900 mb-12 transition-colors font-bold uppercase tracking-widest text-[10px]">
        <ArrowLeft className="w-4 h-4 mr-2" />
        Back
      </button>

      <div className="bg-white p-12 md:p-20 rounded-[3rem] border border-slate-100 shadow-xl">
        <div className="flex items-center space-x-4 mb-10">
          <div className="w-12 h-12 bg-indigo-50 rounded-2xl flex items-center justify-center">
            <Shield className="text-brand-primary w-6 h-6" />
          </div>
          <h1 className="text-4xl font-bold tracking-tight text-slate-900 italic">Privacy Policy</h1>
        </div>

        <div className="prose prose-slate max-w-none">
          <p className="text-lg text-slate-500 font-medium leading-relaxed mb-8">
            At Exos, we take your security and privacy seriously. This policy outlines how we handle your digital assets and personal identification.
          </p>

          <section className="mb-12">
            <h2 className="text-xl font-bold text-slate-900 mb-4 flex items-center">
              <Eye className="w-5 h-5 mr-3 text-brand-primary" />
              1. Data Collection
            </h2>
            <p className="text-slate-600 leading-relaxed mb-4">
              We collect minimal information necessary to secure your tickets and verify your identity at events. This includes your name, email, and transaction history.
            </p>
          </section>

          <section className="mb-12">
            <h2 className="text-xl font-bold text-slate-900 mb-4 flex items-center">
              <Lock className="w-5 h-5 mr-3 text-brand-primary" />
              2. Security Protocols
            </h2>
            <p className="text-slate-600 leading-relaxed mb-4">
              All barcodes are generated using rotating cryptographic keys. We do not store your raw private keys; only the necessary hashes to verify entry.
            </p>
          </section>

          <section className="mb-12">
            <h2 className="text-xl font-bold text-slate-900 mb-4 flex items-center">
              <FileText className="w-5 h-5 mr-3 text-brand-primary" />
              3. Data Retention
            </h2>
            <p className="text-slate-600 leading-relaxed mb-4">
              Transaction records are kept for audit purposes and to facilitate transfers. You can request account deletion at any time through our help center.
            </p>
          </section>
        </div>
      </div>
    </div>
  );
}
