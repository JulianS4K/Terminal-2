// Org developer settings — API keys + outbound webhooks (Hi.Events parity).
//
// Self-contained CRUD embedded in OrgSettings (dark theme). API keys: create
// shows the plaintext ONCE (irrecoverable), list shows prefix only, revoke.
// Webhooks: register an HTTPS endpoint + subscribe to event types; the signing
// secret is shown so the receiver can verify the X-Exos-Signature header.

import { useEffect, useState } from 'react';
import { Key, Webhook as WebhookIcon, Trash2, Plus, Copy, EyeOff } from 'lucide-react';
import {
  createApiKey, revokeApiKey, listApiKeys, type ApiKey,
  listWebhooks, createWebhook, setWebhookEnabled, deleteWebhook,
  WEBHOOK_EVENT_TYPES, type Webhook,
} from '../lib/orgApi';
import { useToast } from '../context/ToastContext';

export default function DeveloperSettings({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [hooks, setHooks] = useState<Webhook[]>([]);
  const [newKeyName, setNewKeyName] = useState('');
  const [freshKey, setFreshKey] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [hookUrl, setHookUrl] = useState('');
  const [hookTypes, setHookTypes] = useState<string[]>([...WEBHOOK_EVENT_TYPES]);

  const reload = async () => {
    try {
      const [k, w] = await Promise.all([listApiKeys(orgId), listWebhooks(orgId)]);
      setKeys(k);
      setHooks(w);
    } catch (e) {
      console.error('developer settings load failed:', e);
    }
  };
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [orgId]);

  const genKey = async () => {
    setBusy(true);
    try {
      const key = await createApiKey(orgId, newKeyName.trim() || undefined);
      setFreshKey(key);
      setNewKeyName('');
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not create key.' });
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (id: string) => {
    try { await revokeApiKey(id); await reload(); }
    catch (e: any) { toast({ kind: 'error', message: e?.message || 'Could not revoke.' }); }
  };

  const addHook = async () => {
    if (!/^https:\/\//.test(hookUrl.trim())) {
      toast({ kind: 'error', message: 'Webhook URL must start with https://' });
      return;
    }
    setBusy(true);
    try {
      await createWebhook(orgId, hookUrl.trim(), hookTypes);
      setHookUrl('');
      setHookTypes([...WEBHOOK_EVENT_TYPES]);
      await reload();
      toast({ kind: 'success', message: 'Webhook added.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not add webhook.' });
    } finally {
      setBusy(false);
    }
  };

  const copy = (text: string) => {
    navigator.clipboard.writeText(text)
      .then(() => toast({ kind: 'success', message: 'Copied.' }))
      .catch(() => toast({ kind: 'error', message: 'Copy failed.' }));
  };

  const toggleType = (t: string) =>
    setHookTypes((cur) => (cur.includes(t) ? cur.filter((x) => x !== t) : [...cur, t]));

  return (
    <fieldset className="border border-white/10 p-5 space-y-6">
      <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">
        Developer — API &amp; webhooks
      </legend>

      {/* API keys */}
      <div className="space-y-3">
        <div className="flex items-center gap-2 text-white/70">
          <Key className="w-4 h-4 text-brand-primary" />
          <span className="text-[11px] font-black uppercase tracking-widest">API keys</span>
        </div>
        <p className="text-white/40 text-xs">
          Authenticate the read-only REST API with <code className="text-brand-primary">Authorization: Bearer &lt;key&gt;</code>.
          Shown once at creation — store it safely.
        </p>

        {freshKey && (
          <div className="bg-brand-primary/10 border border-brand-primary/40 p-3 space-y-2">
            <p className="text-[10px] text-brand-primary font-black uppercase tracking-widest">
              Copy now — you won't see this again
            </p>
            <div className="flex items-center gap-2">
              <code className="flex-1 text-xs text-white font-mono break-all">{freshKey}</code>
              <button type="button" onClick={() => copy(freshKey)} className="text-white/60 hover:text-white" aria-label="Copy key">
                <Copy className="w-4 h-4" />
              </button>
              <button type="button" onClick={() => setFreshKey(null)} className="text-white/60 hover:text-white" aria-label="Dismiss">
                <EyeOff className="w-4 h-4" />
              </button>
            </div>
          </div>
        )}

        {keys.map((k) => (
          <div key={k.id} className="flex items-center justify-between bg-white/5 border border-white/10 px-3 py-2">
            <div className="min-w-0 pr-3">
              <p className="text-sm text-white font-bold truncate">
                {k.name || 'Untitled key'} {k.revokedAt && <span className="text-red-400 text-xs">(revoked)</span>}
              </p>
              <p className="text-white/40 text-xs font-mono">
                {k.keyPrefix}…{k.lastUsedAt ? ` · used ${new Date(k.lastUsedAt).toLocaleDateString()}` : ' · never used'}
              </p>
            </div>
            {canEdit && !k.revokedAt && (
              <button type="button" onClick={() => revoke(k.id)} className="text-white/40 hover:text-red-400 shrink-0 text-[10px] font-black uppercase tracking-widest">
                Revoke
              </button>
            )}
          </div>
        ))}

        {canEdit && (
          <div className="flex items-center gap-2">
            <input
              value={newKeyName}
              onChange={(e) => setNewKeyName(e.target.value)}
              placeholder="Key name (e.g. Zapier)"
              className="flex-1 bg-white/5 border border-white/10 px-3 py-2 text-sm text-white focus:border-brand-primary focus:outline-none"
            />
            <button type="button" disabled={busy} onClick={genKey} className="flex items-center gap-1 px-3 py-2 bg-white/10 hover:bg-white/20 text-[10px] font-black uppercase tracking-widest text-white disabled:opacity-50">
              <Plus className="w-3 h-3" /> New key
            </button>
          </div>
        )}
      </div>

      {/* Webhooks */}
      <div className="space-y-3 pt-2 border-t border-white/10">
        <div className="flex items-center gap-2 text-white/70">
          <WebhookIcon className="w-4 h-4 text-brand-primary" />
          <span className="text-[11px] font-black uppercase tracking-widest">Webhooks</span>
        </div>
        <p className="text-white/40 text-xs">
          We POST signed events to your URL (header <code className="text-brand-primary">X-Exos-Signature: sha256=…</code>,
          HMAC of the body with your secret).
        </p>

        {hooks.map((h) => (
          <div key={h.id} className="bg-white/5 border border-white/10 px-3 py-2 space-y-1">
            <div className="flex items-center justify-between gap-2">
              <p className="text-sm text-white font-mono truncate min-w-0">{h.url}</p>
              <div className="flex items-center gap-3 shrink-0">
                {canEdit && (
                  <button
                    type="button"
                    onClick={() => setWebhookEnabled(h.id, !h.enabled).then(reload)}
                    className={`text-[10px] font-black uppercase tracking-widest ${h.enabled ? 'text-green-400' : 'text-white/30'}`}
                  >
                    {h.enabled ? 'Enabled' : 'Disabled'}
                  </button>
                )}
                {canEdit && (
                  <button type="button" onClick={() => deleteWebhook(h.id).then(reload)} className="text-white/40 hover:text-red-400" aria-label="Delete webhook">
                    <Trash2 className="w-4 h-4" />
                  </button>
                )}
              </div>
            </div>
            <p className="text-white/40 text-[11px]">{h.eventTypes.join(', ')}</p>
            <div className="flex items-center gap-2">
              <span className="text-white/30 text-[10px] uppercase tracking-widest">Secret</span>
              <code className="text-white/50 text-[11px] font-mono truncate">{h.secret.slice(0, 10)}…</code>
              <button type="button" onClick={() => copy(h.secret)} className="text-white/40 hover:text-white" aria-label="Copy secret">
                <Copy className="w-3 h-3" />
              </button>
            </div>
          </div>
        ))}

        {canEdit && (
          <div className="space-y-2">
            <input
              value={hookUrl}
              onChange={(e) => setHookUrl(e.target.value)}
              placeholder="https://your-app.com/webhooks/exos"
              className="w-full bg-white/5 border border-white/10 px-3 py-2 text-sm text-white focus:border-brand-primary focus:outline-none"
            />
            <div className="flex flex-wrap gap-2">
              {WEBHOOK_EVENT_TYPES.map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => toggleType(t)}
                  className={`text-[10px] font-bold px-2 py-1 border transition-all ${hookTypes.includes(t) ? 'border-brand-primary text-brand-primary' : 'border-white/15 text-white/40'}`}
                >
                  {t}
                </button>
              ))}
            </div>
            <button type="button" disabled={busy} onClick={addHook} className="flex items-center gap-1 px-3 py-2 bg-white/10 hover:bg-white/20 text-[10px] font-black uppercase tracking-widest text-white disabled:opacity-50">
              <Plus className="w-3 h-3" /> Add webhook
            </button>
          </div>
        )}
      </div>
    </fieldset>
  );
}
