CREATE OR REPLACE FUNCTION public.use_expedition_item(
    p_player_id uuid,
    p_item_id text,
    p_planet_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_item public.expedition_item_definitions%ROWTYPE;
    v_inventory public.player_expedition_items%ROWTYPE;
    v_expiry timestamptz;
BEGIN
    SELECT * INTO v_item
    FROM public.expedition_item_definitions
    WHERE id=p_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive item %',p_item_id; END IF;

    IF p_planet_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.planets
        WHERE id=p_planet_id AND player_id=p_player_id AND is_destroyed=false
    ) THEN
        RAISE EXCEPTION 'Planet % does not belong to player %',p_planet_id,p_player_id;
    END IF;

    SELECT * INTO v_inventory
    FROM public.player_expedition_items
    WHERE player_id=p_player_id AND item_id=p_item_id AND active=true AND quantity>0
    ORDER BY acquired_at
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % not available for player %',p_item_id,p_player_id; END IF;

    IF v_inventory.quantity=1 THEN
        DELETE FROM public.player_expedition_items WHERE id=v_inventory.id;
    ELSE
        UPDATE public.player_expedition_items
        SET quantity=quantity-1
        WHERE id=v_inventory.id;
    END IF;

    v_expiry := CASE
        WHEN v_item.duration_seconds>0 THEN now()+make_interval(secs=>v_item.duration_seconds)
        ELSE NULL
    END;

    INSERT INTO public.expedition_item_uses(
        player_id,item_id,planet_id,quantity,effect_snapshot
    ) VALUES(
        p_player_id,p_item_id,p_planet_id,1,
        jsonb_build_object(
            'effect_key',v_item.effect_key,
            'effect_value',v_item.effect_value,
            'expires_at',v_expiry
        )
    );

    RETURN jsonb_build_object(
        'item_id',p_item_id,
        'effect_key',v_item.effect_key,
        'effect_value',v_item.effect_value,
        'expires_at',v_expiry
    );
END;
$function$;
