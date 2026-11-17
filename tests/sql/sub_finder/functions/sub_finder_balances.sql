CREATE OR REPLACE FUNCTION public.sub_finder_balances(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.sub_finder_config;
  v_evo bigint;
  v_gt  bigint;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.balances_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read balances');
  END IF;
  SELECT max(run_id) INTO v_evo FROM public.account_balance_run WHERE evo_http = 200 AND evo_rows > 0;
  SELECT max(run_id) INTO v_gt  FROM public.account_balance_run WHERE gt_http = 200;
  RETURN jsonb_build_object(
    'evo', (SELECT jsonb_build_object(
              'taken_at', r.taken_at, 'stale', r.taken_at < now() - interval '2 hours',
              'total_balance',   (SELECT coalesce(sum(b.balance), 0)   FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'),
              'total_pending',   (SELECT coalesce(sum(b.pending), 0)   FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'),
              'total_spendable', (SELECT coalesce(sum(b.spendable), 0) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'),
              'accounts', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                             'office_id', b.account_id, 'currency', b.currency, 'balance', b.balance,
                             'pending', b.pending, 'pending_sent', b.pending_sent, 'spendable', b.spendable)
                             ORDER BY b.spendable DESC NULLS LAST, b.account_id), '[]'::jsonb)
                           FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'))
            FROM public.account_balance_run r WHERE r.run_id = v_evo),
    'gotickets_gift_cards', (SELECT jsonb_build_object(
              'taken_at', r.taken_at, 'stale', r.taken_at < now() - interval '2 hours',
              'card_count',        (SELECT count(*) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card'),
              'cards_with_balance',(SELECT count(*) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card' AND b.balance > 0),
              'total_issued',      (SELECT coalesce(sum(b.issued), 0)  FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card'),
              'total_remaining',   (SELECT coalesce(sum(b.balance), 0) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card'),
              -- only cards that still hold money are listed; the spent ones are in the counts
              'cards', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', b.account_id, 'description', b.label, 'issued', b.issued, 'remaining', b.balance)
                          ORDER BY b.balance DESC, b.account_id), '[]'::jsonb)
                        FROM public.account_balance b
                        WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card' AND b.balance > 0))
            FROM public.account_balance_run r WHERE r.run_id = v_gt),
    'generated_at', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
END
$function$

