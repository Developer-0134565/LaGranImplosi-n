CREATE OR REPLACE FUNCTION public.resolve_expedition_merchant(p_fleet_id uuid)
RETURNS TABLE(merchant_resource text, metal_rate numeric, crystal_rate numeric, deuterium_rate numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
    v_fleet record;
    v_offer record;
    v_existing record;
    v_has_existing boolean := false;
BEGIN
    SELECT fm.id,fm.player_id,fm.mission_type,fm.status INTO v_fleet
    FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id; END IF;

    SELECT * INTO v_existing FROM public.player_expedition_merchants
    WHERE player_id=v_fleet.player_id AND active=true FOR UPDATE;
    v_has_existing := FOUND;

    SELECT * INTO v_offer FROM public.select_expedition_merchant_offer();

    IF v_has_existing THEN
        INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active)
        VALUES(v_fleet.player_id,v_existing.resource,
               GREATEST(v_existing.metal_rate,v_offer.metal_rate),
               GREATEST(v_existing.crystal_rate,v_offer.crystal_rate),1,'EXPEDITION',true)
        ON CONFLICT(player_id) DO UPDATE SET
            resource=public.player_expedition_merchants.resource,
            metal_rate=LEAST(3,GREATEST(public.player_expedition_merchants.metal_rate,EXCLUDED.metal_rate)),
            crystal_rate=LEAST(2,GREATEST(public.player_expedition_merchants.crystal_rate,EXCLUDED.crystal_rate)),
            deuterium_rate=1,
            active=true,
            source='EXPEDITION',
            updated_at=now();
    ELSE
        INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active)
        VALUES(v_fleet.player_id,v_offer.resource,v_offer.metal_rate,v_offer.crystal_rate,1,'EXPEDITION',true)
        ON CONFLICT(player_id) DO UPDATE SET
            resource=EXCLUDED.resource,
            metal_rate=EXCLUDED.metal_rate,
            crystal_rate=EXCLUDED.crystal_rate,
            deuterium_rate=1,
            active=true,
            source='EXPEDITION',
            updated_at=now();
    END IF;

    RETURN QUERY SELECT pem.resource,pem.metal_rate,pem.crystal_rate,pem.deuterium_rate
    FROM public.player_expedition_merchants pem WHERE pem.player_id=v_fleet.player_id;
END;
$function$;