import React, { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Mail, Phone, X, ShieldCheck, Ticket, ArrowLeft, Loader2 } from 'lucide-react';
import { supabase } from '../lib/supabase';

export default function AuthModal({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) {
  const [method, setMethod] = useState<'options' | 'email-login' | 'email-signup' | 'phone'>('options');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (isOpen) {
      setMethod('options');
      setEmail('');
      setPassword('');
      setName('');
      setError('');
      setInfo('');
    }
  }, [isOpen]);

  const handleProviderSignIn = async (providerName: 'google' | 'apple' | 'microsoft') => {
    setLoading(true);
    setError('');
    // Supabase names the Microsoft provider 'azure'.
    const provider = providerName === 'microsoft' ? 'azure' : providerName;

    try {
      const { error } = await supabase.auth.signInWithOAuth({
        provider,
        options: { redirectTo: window.location.origin },
      });
      if (error) throw error;
      // OAuth is a redirect flow — the browser navigates to the provider and
      // AuthContext picks up the session on return.
    } catch (err: any) {
      console.error(err);
      setError(err.message || 'Authentication failed');
      setLoading(false);
    }
  };

  const handleEmailAuth = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');
    setInfo('');
    try {
      if (method === 'email-signup') {
        const { error } = await supabase.auth.signUp({
          email,
          password,
          options: { data: { display_name: name }, emailRedirectTo: window.location.origin },
        });
        if (error) throw error;
        // Supabase sends a confirmation email; the session isn't active until
        // the user confirms (unless the project disables confirmations).
        setInfo('Account created — check your email to confirm, then sign in.');
        setLoading(false);
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        // AuthContext closes the modal on the SIGNED_IN auth state change.
      }
    } catch (err: any) {
      console.error(err);
      setError(err.message || 'Authentication failed');
      setLoading(false);
    }
  };

  if (!isOpen) return null;

  return (
    <AnimatePresence>
      <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          className="absolute inset-0 bg-black/90 backdrop-blur-sm"
          onClick={onClose}
        />

        <motion.div
          initial={{ scale: 0.95, opacity: 0, y: 20 }}
          animate={{ scale: 1, opacity: 1, y: 0 }}
          exit={{ scale: 0.95, opacity: 0, y: 20 }}
          className="relative bg-[#0e0e0e] border border-white/12 w-full max-w-md shadow-2xl overflow-hidden"
        >
          <div className="p-6 border-b border-white/10 flex justify-between items-center bg-black">
             <div className="flex items-center gap-3">
                {method !== 'options' && (
                  <button onClick={() => setMethod('options')} className="mr-1 text-white/50 hover:text-brand-primary transition-colors">
                    <ArrowLeft className="w-4 h-4" />
                  </button>
                )}
                <div className="w-9 h-9 bg-brand-primary flex items-center justify-center shrink-0">
                  <Ticket className="w-5 h-5 text-black" />
                </div>
                <h2 className="disp text-2xl uppercase tracking-tight leading-none pt-1" style={{ transform: 'skewX(-4deg)' }}>
                  {method === 'options' ? 'Get On The List' : method === 'email-login' ? 'Sign In' : method === 'email-signup' ? 'Create Account' : method}
                </h2>
             </div>
             <button onClick={onClose} className="type text-white/40 hover:text-white text-[11px] uppercase tracking-widest transition-colors">close [x]</button>
          </div>

          <div className="p-8">
            {error && (
              <div className="mb-6 p-4 bg-brand-accent/10 border-l-4 border-brand-accent border-y border-r border-white/10 text-brand-accent type text-[11px] uppercase tracking-widest text-center">
                {error}
              </div>
            )}
            {info && (
              <div className="mb-6 p-4 bg-brand-primary/10 border-l-4 border-brand-primary border-y border-r border-white/10 text-brand-primary type text-[11px] uppercase tracking-widest text-center">
                {info}
              </div>
            )}

            {method === 'options' && (
              <div className="space-y-4">
                <button
                  onClick={() => handleProviderSignIn('google')}
                  disabled={loading}
                  className="w-full flex items-center justify-center gap-3 p-4 bg-white text-black disp text-lg uppercase tracking-wide hover:bg-brand-primary transition-colors"
                >
                  <svg className="w-4 h-4" viewBox="0 0 24 24">
                    <path fill="currentColor" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
                    <path fill="currentColor" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
                    <path fill="currentColor" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" />
                    <path fill="currentColor" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" />
                  </svg>
                  <span>Continue with Google</span>
                </button>

                <button
                  onClick={() => handleProviderSignIn('apple')}
                  disabled={loading}
                  className="w-full flex items-center justify-center gap-3 p-4 bg-black border border-white/20 text-white disp text-lg uppercase tracking-wide hover:border-brand-primary hover:text-brand-primary transition-colors"
                >
                  <svg className="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.56-1.701z" />
                  </svg>
                  <span>Continue with Apple</span>
                </button>

                <button
                  onClick={() => handleProviderSignIn('microsoft')}
                  disabled={loading}
                  className="w-full flex items-center justify-center gap-3 p-4 bg-black border border-white/20 text-white disp text-lg uppercase tracking-wide hover:border-brand-primary hover:text-brand-primary transition-colors"
                >
                  <svg className="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M11.4 24H0V12.6h11.4V24zM24 24H12.6V12.6H24V24zM11.4 11.4H0V0h11.4v11.4zm12.6 0H12.6V0H24v11.4z" />
                  </svg>
                  <span>Continue with Microsoft</span>
                </button>

                <div className="relative py-4">
                  <div className="absolute inset-0 flex items-center">
                    <div className="w-full border-t border-white/10"></div>
                  </div>
                  <div className="relative flex justify-center">
                    <span className="bg-[#0e0e0e] px-4 type text-[10px] text-white/50 uppercase tracking-widest">or</span>
                  </div>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <button
                    onClick={() => setMethod('email-login')}
                    disabled={loading}
                    className="flex flex-col items-center justify-center p-4 border border-white/10 hover:border-brand-primary text-white hover:text-brand-primary transition-colors group"
                  >
                     <Mail className="w-6 h-6 mb-2 text-white/50 group-hover:text-brand-primary transition-colors" />
                     <span className="type text-[10px] uppercase tracking-widest">Email Login</span>
                  </button>
                  <button
                    onClick={() => setMethod('email-signup')}
                    disabled={loading}
                    className="flex flex-col items-center justify-center p-4 border border-white/10 hover:border-brand-primary text-white hover:text-brand-primary transition-colors group"
                  >
                     <ShieldCheck className="w-6 h-6 mb-2 text-white/50 group-hover:text-brand-primary transition-colors" />
                     <span className="type text-[10px] uppercase tracking-widest">Sign Up</span>
                  </button>
                </div>

              </div>
            )}

            {(method === 'email-login' || method === 'email-signup') && (
              <form onSubmit={handleEmailAuth} className="space-y-4">
                {method === 'email-signup' && (
                   <div>
                    <label className="block type text-[10px] uppercase tracking-widest text-white/50 mb-2">Display Name</label>
                    <input
                      type="text"
                      className="w-full type bg-black border border-white/20 p-4 text-white placeholder-white/35 focus:border-brand-primary focus:outline-none transition-colors"
                      placeholder="e.g. Satoshi Nakamoto"
                      value={name}
                      onChange={(e) => setName(e.target.value)}
                      required
                    />
                  </div>
                )}
                <div>
                  <label className="block type text-[10px] uppercase tracking-widest text-white/50 mb-2">Email Address</label>
                  <input
                    type="email"
                    className="w-full type bg-black border border-white/20 p-4 text-white placeholder-white/35 focus:border-brand-primary focus:outline-none transition-colors"
                    placeholder="you@domain.com"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    required
                  />
                </div>
                <div>
                  <label className="block type text-[10px] uppercase tracking-widest text-white/50 mb-2">Password</label>
                  <input
                    type="password"
                    className="w-full type bg-black border border-white/20 p-4 text-white placeholder-white/35 focus:border-brand-primary focus:outline-none transition-colors"
                    placeholder="••••••••"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    required
                  />
                </div>
                <button
                  type="submit"
                  disabled={loading}
                  className="w-full flex items-center justify-center bg-brand-primary text-black p-4 disp text-xl uppercase tracking-wide hover:bg-white transition-colors mt-6"
                >
                  {loading ? <Loader2 className="w-5 h-5 animate-spin" /> : (method === 'email-login' ? 'Sign In' : 'Create Account')}
                </button>
              </form>
            )}
          </div>
          <div className="px-8 py-4 border-t border-white/10 bg-black text-center">
            <p className="type text-[10px] text-white/30 uppercase tracking-widest leading-relaxed">
              By continuing, you agree to our Terms of Service and Privacy Policy.
            </p>
          </div>
        </motion.div>
      </div>
    </AnimatePresence>
  );
}
