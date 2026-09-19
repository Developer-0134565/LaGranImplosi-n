ALTER TABLE public.player_expedition_items DROP CONSTRAINT IF EXISTS player_expedition_items_quantity_check;
ALTER TABLE public.player_expedition_items ADD CONSTRAINT player_expedition_items_quantity_check CHECK (quantity >= 0);

CREATE OR REPLACE FUNCTION public.use_expedition_item(p_player_id uuid,p_item_id text,p_planet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_item public.expedition_item_definitions%ROWTYPE; v_stack public.player_expedition_items%ROWTYPE; v_expiry timestamptz;
BEGIN
    SELECT * INTO v_item FROM public.expedition_item_definitions WHERE id=p_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive item %',p_item_id; END IF;
    SELECT * INTO v_stack FROM public.player_expedition_items
    WHERE player_id=p_player_id AND item_id=p_item_id AND active=true AND quantity>0
    ORDER BY acquired_at LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % not available for player %',p_item_id,p_player_id; END IF;
    UPDATE public.player_expedition_items SET quantity=quantity-1,active=(quantity-1)>0 WHERE id=v_stack.id;
    v_expiry:=CASE WHEN v_item.duration_seconds>0 THEN now()+make_interval(secs=>v_item.duration_seconds) ELSE NULL END;
    INSERT INTO public.expedition_item_uses(player_id,item_id,planet_id,quantity,effect_snapshot)
    VALUES(p_player_id,p_item_id,p_planet_id,1,jsonb_build_object('effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_at',v_expiry));
    RETURN jsonb_build_object('item_id',p_item_id,'effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_at',v_expiry);
END;
$function$;
