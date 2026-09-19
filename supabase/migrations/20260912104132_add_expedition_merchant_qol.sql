CREATE TABLE IF NOT EXISTS public.player_expedition_merchants (
    player_id uuid PRIMARY KEY REFERENCES public.players(id) ON DELETE CASCADE,
    resource text NOT NULL CHECK (resource IN ('METAL','CRYSTAL','DEUTERIUM')),
    metal_rate numeric NOT NULL CHECK (metal_rate > 0),
    crystal_rate numeric NOT NULL CHECK (crystal_rate > 0),
    deuterium_rate numeric NOT NULL CHECK (deuterium_rate > 0),
    source text NOT NULL DEFAULT 'EXPEDITION' CHECK (source IN ('EXPEDITION','CALLED')),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.expedition_results ADD COLUMN IF NOT EXISTS merchant_resource text CHECK (merchant_resource IS NULL OR merchant_resource IN ('METAL','CRYSTAL','DEUTERIUM'));
ALTER TABLE public.expedition_results ADD COLUMN IF NOT EXISTS merchant_metal_rate numeric CHECK (merchant_metal_rate IS NULL OR merchant_metal_rate > 0);
ALTER TABLE public.expedition_results ADD COLUMN IF NOT EXISTS merchant_crystal_rate numeric CHECK (merchant_crystal_rate IS NULL OR merchant_crystal_rate > 0);
ALTER TABLE public.expedition_results ADD COLUMN IF NOT EXISTS merchant_deuterium_rate numeric CHECK (merchant_deuterium_rate IS NULL OR merchant_deuterium_rate > 0);
CREATE INDEX IF NOT EXISTS idx_player_expedition_merchants_active ON public.player_expedition_merchants(player_id) WHERE active = true;

CREATE OR REPLACE FUNCTION public.select_expedition_merchant_offer()
RETURNS TABLE(resource text, metal_rate numeric, crystal_rate numeric, deuterium_rate numeric)
LANGUAGE plpgsql VOLATILE AS $function$
DECLARE
    v_resource text;
    v_quality numeric;
BEGIN
    v_resource := (ARRAY['METAL','CRYSTAL','DEUTERIUM'])[floor(random()*3)+1];
    -- QoL range based on expedition merchant guidance: 2.5:1.5:1 up to 3:2:1.
    -- We keep it player-friendly and never worse than the documented expedition range.
    v_quality := round((2.5 + random()*0.5)::numeric, 3);
    resource := v_resource;
    metal_rate := v_quality;
    crystal_rate := greatest(1.5, round((v_quality - 1)::numeric, 3));
    deuterium_rate := 1;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_merchant(p_fleet_id uuid)
RETURNS TABLE(merchant_resource text, metal_rate numeric, crystal_rate numeric, deuterium_rate numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
    v_fleet record;
    v_offer record;
BEGIN
    SELECT fm.id, fm.player_id, fm.mission_type, fm.status
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id=p_fleet_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id; END IF;

    SELECT * INTO v_offer FROM public.select_expedition_merchant_offer();

    INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active)
    VALUES(v_fleet.player_id,v_offer.resource,v_offer.metal_rate,v_offer.crystal_rate,1,'EXPEDITION',true)
    ON CONFLICT(player_id) DO UPDATE SET
        resource=EXCLUDED.resource,
        metal_rate=GREATEST(public.player_expedition_merchants.metal_rate,EXCLUDED.metal_rate),
        crystal_rate=GREATEST(public.player_expedition_merchants.crystal_rate,EXCLUDED.crystal_rate),
        deuterium_rate=1,
        source='EXPEDITION',
        active=true,
        updated_at=now();

    SELECT resource,metal_rate,crystal_rate,deuterium_rate
    INTO merchant_resource,metal_rate,crystal_rate,deuterium_rate
    FROM public.player_expedition_merchants
    WHERE player_id=v_fleet.player_id;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_expedition_merchant_trade(
    p_player_id uuid,
    p_planet_id uuid,
    p_sell_resource text,
    p_sell_amount numeric
)
RETURNS TABLE(sold numeric,bought numeric,bought_resource text,remaining_merchant boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
    v_merchant record;
    v_res record;
    v_ratio numeric;
    v_capacity numeric;
    v_buy numeric;
BEGIN
    IF p_sell_amount <= 0 THEN RAISE EXCEPTION 'Sell amount must be positive'; END IF;
    SELECT * INTO v_merchant FROM public.player_expedition_merchants WHERE player_id=p_player_id AND active=true FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No active merchant for player %',p_player_id; END IF;
    IF p_sell_resource NOT IN ('METAL','CRYSTAL','DEUTERIUM') THEN RAISE EXCEPTION 'Invalid sell resource'; END IF;
    IF p_sell_resource = v_merchant.resource THEN RAISE EXCEPTION 'Merchant buys %, not %',v_merchant.resource,p_sell_resource; END IF;

    SELECT * INTO v_res FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
    IF p_sell_resource='METAL' THEN
        IF v_res.metal < p_sell_amount THEN RAISE EXCEPTION 'Insufficient metal'; END IF;
    ELSIF p_sell_resource='CRYSTAL' THEN
        IF v_res.crystal < p_sell_amount THEN RAISE EXCEPTION 'Insufficient crystal'; END IF;
    ELSE
        IF v_res.deuterium < p_sell_amount THEN RAISE EXCEPTION 'Insufficient deuterium'; END IF;
    END IF;

    -- Rates are normalized against deuterium=1.
    IF v_merchant.resource='METAL' THEN
        v_ratio := v_merchant.metal_rate;
        bought_resource := 'METAL';
    ELSIF v_merchant.resource='CRYSTAL' THEN
        v_ratio := v_merchant.crystal_rate;
        bought_resource := 'CRYSTAL';
    ELSE
        v_ratio := 1;
        bought_resource := 'DEUTERIUM';
    END IF;

    IF p_sell_resource='METAL' THEN
        v_buy := floor(p_sell_amount / v_ratio);
    ELSIF p_sell_resource='CRYSTAL' THEN
        v_buy := floor(p_sell_amount / v_ratio);
    ELSE
        v_buy := floor(p_sell_amount * v_ratio);
    END IF;

    IF bought_resource='METAL' THEN
        v_capacity := GREATEST(0, (SELECT COALESCE(max_storage,0) FROM public.planet_resources WHERE planet_id=p_planet_id) - v_res.metal);
    ELSIF bought_resource='CRYSTAL' THEN
        v_capacity := GREATEST(0, (SELECT COALESCE(max_storage,0) FROM public.planet_resources WHERE planet_id=p_planet_id) - v_res.crystal);
    ELSE
        v_capacity := GREATEST(0, (SELECT COALESCE(max_storage,0) FROM public.planet_resources WHERE planet_id=p_planet_id) - v_res.deuterium);
    END IF;

    -- If planet_resources has no generic max_storage, fall back to the actual storage helper in the next revision.
    IF v_capacity <= 0 THEN RAISE EXCEPTION 'Insufficient storage for merchant purchase'; END IF;
    v_buy := LEAST(v_buy,v_capacity);

    IF bought_resource='METAL' THEN
        UPDATE public.planet_resources SET metal=metal-v_buy*v_ratio, updated_at=now() WHERE planet_id=p_planet_id;
    ELSIF bought_resource='CRYSTAL' THEN
        UPDATE public.planet_resources SET crystal=crystal-v_buy*v_ratio, updated_at=now() WHERE planet_id=p_planet_id;
    ELSE
        UPDATE public.planet_resources SET deuterium=deuterium-v_buy, updated_at=now() WHERE planet_id=p_planet_id;
    END IF;

    IF p_sell_resource='METAL' THEN UPDATE public.planet_resources SET metal=metal-p_sell_amount WHERE planet_id=p_planet_id;
    ELSIF p_sell_resource='CRYSTAL' THEN UPDATE public.planet_resources SET crystal=crystal-p_sell_amount WHERE planet_id=p_planet_id;
    ELSE UPDATE public.planet_resources SET deuterium=deuterium-p_sell_amount WHERE planet_id=p_planet_id;
    END IF;

    IF bought_resource='METAL' THEN UPDATE public.planet_resources SET metal=metal+v_buy WHERE planet_id=p_planet_id;
    ELSIF bought_resource='CRYSTAL' THEN UPDATE public.planet_resources SET crystal=crystal+v_buy WHERE planet_id=p_planet_id;
    ELSE UPDATE public.planet_resources SET deuterium=deuterium+v_buy WHERE planet_id=p_planet_id;
    END IF;

    UPDATE public.player_expedition_merchants SET active=false,updated_at=now() WHERE player_id=p_player_id;
    sold:=p_sell_amount; bought:=v_buy; remaining_merchant:=false; RETURN NEXT;
END;
$function$;