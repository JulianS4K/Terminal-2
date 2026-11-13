CREATE OR REPLACE FUNCTION public.manual_sub_buy_total_ceiling(b manual_sub_buy)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- The most an automatic buy may cost in total, tax included. A need2buy order: the sale plus the
  -- loss allowed for its marketplace. Any other order: under the sale (a profit), mig 20261113320000.
  SELECT CASE WHEN b.requested_by LIKE 'sub finder auto (key %' AND b.sold_ea > 0
              THEN CASE WHEN l.pct IS NULL THEN round(b.sold_ea * b.qty, 2) - 0.01
                        ELSE round(b.sold_ea * b.qty * (1 + greatest(l.pct, 0) / 100.0), 2) END END
  FROM (SELECT public.sub_finder_max_loss_pct(
                 b.sale_site, public.sub_finder_order_is_need2buy(b.sale_order_number)) AS pct) l;
$function$

