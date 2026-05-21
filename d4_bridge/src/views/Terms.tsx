import { Scale, AlertCircle, CheckCircle2, FileText, ArrowLeft } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

export default function Terms() {
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
            <Scale className="text-brand-primary w-6 h-6" />
          </div>
          <h1 className="text-4xl font-bold tracking-tight text-slate-900 italic">Terms of Service</h1>
        </div>

        <div className="prose prose-slate max-w-none">
          <p className="text-lg text-slate-500 font-medium leading-relaxed mb-8">
            Access to Exos and its services is governed by these terms. By using our platform, you agree to our secure ticketing protocols.
          </p>

          <section className="mb-12">
            <h2 className="text-xl font-bold text-slate-900 mb-4 flex items-center">
              <CheckCircle2 className="w-5 h-5 mr-3 text-brand-primary" />
              1. Authorized Use
            </h2>
            <p className="text-slate-600 leading-relaxed mb-4">
              Exos is intended for authorized ticket holders and event organizers. Use of automated tools to scrape or exploit the platform is strictly prohibited.
            </p>
          </section>

          <section className="mb-12">
            <h2 className="text-xl font-bold text-slate-900 mb-4 flex items-center">
              <AlertCircle className="w-5 h-5 mr-3 text-brand-primary" />
              2. Transfer Policy
            </h2>
            <p className="text-slate-600 leading-relaxed mb-4">
              Tickets may only be transferred through the official Exos interface. Transfers made outside the platform may result in invalidation of the digital asset.
            </p>
          </section>

          <section className="mb-12">
            <h2 className="text-xl font-bold text-slate-900 mb-4 flex items-center">
              <FileText className="w-5 h-5 mr-3 text-brand-primary" />
              3. Refund & Cancellation
            </h2>
            <p className="text-slate-600 leading-relaxed mb-4">
              Refund policies are set by individual event organizers. Exos facilitates the transaction but is not responsible for event cancellations or modifications.
            </p>
          </section>
        </div>
      </div>
    </div>
  );
}
