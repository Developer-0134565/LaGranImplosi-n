CREATE TABLE IF NOT EXISTS public.expedition_item_definitions (
    id text PRIMARY KEY,
    name text NOT NULL,
    description text NOT NULL DEFAULT '',
    category text NOT NULL CHECK (category IN ('RESOURCE','PRODUCTION','STORAGE','BUILDING','RESEARCH','FLEET','EXPEDITION','UTILITY')),
    effect_key text NOT NULL,
    effect_value numeric NOT NULL,
    max_stacks integer NOT NULL DEFAULT 1 CHECK (max_stacks >= 1),
    duration_seconds bigint NOT NULL DEFAULT 0 CHECK (duration_seconds >= 0),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.player_expedition_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
    item_id text NOT NULL REFERENCES public.expedition_item_definitions(id),
    quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    acquired_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    active boolean NOT NULL DEFAULT true,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_player_expedition_items_player_active
ON public.player_expedition_items(player_id, active, item_id);

CREATE TABLE IF NOT EXISTS public.expedition_item_uses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
    item_id text NOT NULL REFERENCES public.expedition_item_definitions(id),
    planet_id uuid REFERENCES public.planets(id) ON DELETE SET NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    effect_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    used_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_expedition_item_uses_player_time
ON public.expedition_item_uses(player_id, used_at DESC);

INSERT INTO public.expedition_item_definitions
(id,name,description,category,effect_key,effect_value,max_stacks,duration_seconds)
VALUES
('resource_boost_10','Resource Boost I','Aumenta temporalmente la producción de recursos de un planeta.','RESOURCE','production_percent',10,1,86400),
('resource_boost_20','Resource Boost II','Aumenta temporalmente la producción de recursos de un planeta.','RESOURCE','production_percent',20,1,86400),
('storage_boost_25','Storage Expansion I','Aumenta temporalmente la capacidad de almacenes de un planeta.','STORAGE','storage_percent',25,1,86400),
('building_boost_10','Construction Matrix I','Reduce temporalmente el tiempo de construcción de edificios.','BUILDING','building_speed_percent',10,1,86400),
('research_boost_10','Research Matrix I','Reduce temporalmente el tiempo de investigación.','RESEARCH','research_speed_percent',10,1,86400),
('fleet_boost_10','Fleet Matrix I','Aumenta temporalmente la velocidad de flota.','FLEET','fleet_speed_percent',10,1,86400),
('expedition_boost_15','Expedition Matrix I','Aumenta temporalmente el valor de las recompensas de expedición.','EXPEDITION','expedition_reward_percent',15,1,86400),
('expedition_slots_1','Expedition Slot','Añade temporalmente un hueco de expedición.','UTILITY','expedition_slots',1,1,86400)
ON CONFLICT (id) DO UPDATE SET
    name=EXCLUDED.name,
    description=EXCLUDED.description,
    category=EXCLUDED.category,
    effect_key=EXCLUDED.effect_key,
    effect_value=EXCLUDED.effect_value,
    max_stacks=EXCLUDED.max_stacks,
    duration_seconds=EXCLUDED.duration_seconds,
    active=true;

ALTER TABLE public.expedition_results
    ADD COLUMN IF NOT EXISTS item_id text REFERENCES public.expedition_item_definitions(id),
    ADD COLUMN IF NOT EXISTS item_quantity integer NOT NULL DEFAULT 0 CHECK (item_quantity >= 0);

CREATE OR REPLACE FUNCTION public.select_expedition_item()
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_roll numeric := random() * 100;
BEGIN
    IF v_roll < 55 THEN RETURN 'resource_boost_10';
    ELSIF v_roll < 70 THEN RETURN 'resource_boost_20';
    ELSIF v_roll < 80 THEN RETURN 'storage_boost_25';
    ELSIF v_roll < 87 THEN RETURN 'building_boost_10';
    ELSIF v_roll < 94 THEN RETURN 'research_boost_10';
    ELSIF v_roll < 97 THEN RETURN 'fleet_boost_10';
    ELSIF v_roll < 99 THEN RETURN 'expedition_boost_15';
    ELSE RETURN 'expedition_slots_1';
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_item(p_fleet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_fleet public.fleet_movements%ROWTYPE;
    v_item_id text;
    v_item public.expedition_item_definitions%ROWTYPE;
    v_existing integer;
BEGIN
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id=p_fleet_id AND mission_type='EXPEDITION'
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id; END IF;

    v_item_id := public.select_expedition_item();
    SELECT * INTO v_item FROM public.expedition_item_definitions WHERE id=v_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % is not active', v_item_id; END IF;

    SELECT COALESCE(sum(quantity),0)::integer INTO v_existing
    FROM public.player_expedition_items
    WHERE player_id=v_fleet.player_id AND item_id=v_item_id AND active=true
      AND (expires_at IS NULL OR expires_at > now());

    IF v_existing >= v_item.max_stacks THEN
        UPDATE public.player_expedition_items
        SET quantity=quantity+1, updated_at=now()
        WHERE player_id=v_fleet.player_id AND item_id=v_item_id AND active=true
          AND (expires_at IS NULL OR expires_at > now());
    ELSE
        INSERT INTO public.player_expedition_items(player_id,item_id,quantity,expires_at)
        VALUES(v_fleet.player_id,v_item_id,1,CASE WHEN v_item.duration_seconds>0 THEN now()+make_interval(secs=>v_item.duration_seconds) ELSE NULL END);
    END IF;

    UPDATE public.expedition_results
    SET item_id=v_item_id,item_quantity=1
    WHERE fleet_id=p_fleet_id;

    RETURN jsonb_build_object('item_id',v_item_id,'name',v_item.name,'category',v_item.category,'effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_in_seconds',v_item.duration_seconds);
END;
$function$;

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
    SELECT * INTO v_item FROM public.expedition_item_definitions WHERE id=p_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive item %',p_item_id; END IF;

    UPDATE public.player_expedition_items
    SET quantity=quantity-1
    WHERE id=(SELECT id FROM public.player_expedition_items
              WHERE player_id=p_player_id AND item_id=p_item_id AND active=true
                AND (expires_at IS NULL OR expires_at>now()) AND quantity>0
              ORDER BY acquired_at LIMIT 1)
    RETURNING * INTO v_inventory;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % not available for player %',p_item_id,p_player_id; END IF;

    IF v_inventory.quantity=0 THEN UPDATE public.player_expedition_items SET active=false WHERE id=v_inventory.id; END IF;
    v_expiry := CASE WHEN v_item.duration_seconds>0 THEN now()+make_interval(secs=>v_item.duration_seconds) ELSE NULL END;

    INSERT INTO public.expedition_item_uses(player_id,item_id,planet_id,quantity,effect_snapshot)
    VALUES(p_player_id,p_item_id,p_planet_id,1,jsonb_build_object('effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_at',v_expiry));

    RETURN jsonb_build_object('item_id',p_item_id,'effect_key',v_item.effect_key,'effect_value',v_item.effect_value,'expires_at',v_expiry);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.select_expedition_item() TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_expedition_item(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.use_expedition_item(uuid,text,uuid) TO authenticated;
