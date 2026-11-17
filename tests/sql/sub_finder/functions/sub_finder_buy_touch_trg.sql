CREATE OR REPLACE FUNCTION public.sub_finder_buy_touch_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF (NEW.state, NEW.outcome, NEW.buy_order_id, NEW.seats, NEW.order_total_usd, NEW.seller_state)
     IS DISTINCT FROM
     (OLD.state, OLD.outcome, OLD.buy_order_id, OLD.seats, OLD.order_total_usd, OLD.seller_state) THEN
    UPDATE public.sub_finder_order SET updated_at = now() WHERE buy_id = NEW.buy_id;
  END IF;
  RETURN NULL;
END
$function$

