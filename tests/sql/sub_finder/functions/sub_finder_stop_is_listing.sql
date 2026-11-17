CREATE OR REPLACE FUNCTION public.sub_finder_stop_is_listing(p_reasons text[])
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(cardinality(p_reasons), 0) > 0
     AND p_reasons <@ ARRAY['listing_gone', 'price_above_ceiling', 'short_quantity', 'split_not_allowed',
                            'our_own_listing', 'unknown_format', 'no_seller_office', 'listing_read_failed',
                            'buy_failed', 'total_above_ceiling', 'tax_quote_failed', 'no_electronic_delivery',
                            'price_unknown', 'listing_unreadable', 'own_listing_check_failed',
                            'seller_rejected', 'order_canceled']::text[]
$function$

