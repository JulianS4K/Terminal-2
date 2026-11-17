CREATE OR REPLACE FUNCTION public.manual_sub_buy_changed_trg()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF (NEW.state, NEW.outcome, NEW.buy_order_id, NEW.buy_state, NEW.seller_state, NEW.order_state,
      NEW.order_total_usd, NEW.bought_total_usd, NEW.seats, NEW.bought_section, NEW.bought_row,
      NEW.reasons, NEW.rejection_reason)
     IS DISTINCT FROM
     (OLD.state, OLD.outcome, OLD.buy_order_id, OLD.buy_state, OLD.seller_state, OLD.order_state,
      OLD.order_total_usd, OLD.bought_total_usd, OLD.seats, OLD.bought_section, OLD.bought_row,
      OLD.reasons, OLD.rejection_reason) THEN
    NEW.changed_at := now();
  END IF;
  RETURN NEW;
END
$function$

