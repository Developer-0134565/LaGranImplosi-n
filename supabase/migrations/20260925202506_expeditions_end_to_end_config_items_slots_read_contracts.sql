-- EXPEDITIONS OPERATIVAS END-TO-END — configuración + activación de objetos + slots + contratos de lectura
-- ============================================================================================================
-- Alcance de este bloque (SOLO expediciones; nada de moons/ranking/AI/wreck fields/PG-09):
--   1) Configuración de expedición del universo ACTIVO (hoy sin fila en `expedition_settings`).
--   2) Activación de objetos de expedición por su dueño (la lógica ya existía; faltaba autoridad y grant).
--   3) Integración de `expedition_settings.bonus_expedition_slots` en `get_player_expedition_slots`.
--   4) Contratos de LECTURA para la UI (las tablas de expedición están cerradas a clientes por política
--      `deny_direct_api_access`, así que la vista no podía leer resultados ni objetos).
--
-- Sobre los PESOS: NO son inventados. Son la configuración que el propio proyecto ya estableció y que sigue
-- vigente en el universo de pruebas, con provenance en el repositorio:
--   · `20260912092811_fix_expedition_normal_logical_return_time_v2.sql` (siembra inicial)
--   · `20260912105222_restore_expedition_weights_after_timing_audit.sql` (restauración explícita)
--   · `20260912102702_implement_expedition_dark_matter.sql`, `20260912104132_add_expedition_merchant_qol.sql`,
--     `20260912105801_implement_expedition_items.sql` (añaden DM/comerciante/objetos)
-- Este bloque REPLICA esa configuración en el universo activo; los pesos siguen siendo datos ajustables por
-- producto y no se altera ningún valor.

-- ------------------------------------------------------------------ 1) configuración del universo activo
insert into public.expedition_settings (
    universe_id, bonus_expedition_slots,
    reward_multiplier_resources, reward_multiplier_ships, reward_multiplier_dark_matter, reward_multiplier_items,
    weight_ships, weight_resources, weight_delay, weight_speedup, weight_nothing, weight_black_hole,
    weight_pirates, weight_aliens, weight_dark_matter, weight_merchant, weight_items
)
select u.id, src.bonus_expedition_slots,
       src.reward_multiplier_resources, src.reward_multiplier_ships, src.reward_multiplier_dark_matter, src.reward_multiplier_items,
       src.weight_ships, src.weight_resources, src.weight_delay, src.weight_speedup, src.weight_nothing, src.weight_black_hole,
       src.weight_pirates, src.weight_aliens, src.weight_dark_matter, src.weight_merchant, src.weight_items
from public.universes u
cross join lateral (
    select es.* from public.expedition_settings es order by es.created_at, es.universe_id limit 1
) src
where u.is_active
  and not exists (select 1 from public.expedition_settings s where s.universe_id = u.id);

-- ------------------------------------------------- 2) activación de objetos por su dueño (autoridad LGI)
create or replace function public.use_expedition_item(p_player_id uuid, p_item_id text, p_planet_id uuid DEFAULT NULL::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
    v_auth_user uuid := auth.uid();
    v_owner uuid;
    v_item public.expedition_item_definitions%ROWTYPE;
    v_stack public.player_expedition_items%ROWTYPE;
    v_expiry timestamptz;
BEGIN
    -- Identidad: el actor debe existir y ser el dueño del jugador indicado.
    IF v_auth_user IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT pl.id INTO v_owner FROM public.players pl
    WHERE pl.id = p_player_id AND pl.user_id = v_auth_user;

    IF v_owner IS NULL THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;

    -- Si el efecto se limita a un planeta, ese planeta debe ser del jugador.
    IF p_planet_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.planets p
        WHERE p.id = p_planet_id AND p.player_id = p_player_id AND NOT p.is_destroyed
    ) THEN
        RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    END IF;

    SELECT * INTO v_item FROM public.expedition_item_definitions WHERE id = p_item_id AND active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive item %', p_item_id; END IF;

    SELECT * INTO v_stack FROM public.player_expedition_items
    WHERE player_id = p_player_id AND item_id = p_item_id AND active = true AND quantity > 0
    ORDER BY acquired_at LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % not available for player %', p_item_id, p_player_id; END IF;

    UPDATE public.player_expedition_items
    SET quantity = quantity - 1, active = (quantity - 1) > 0
    WHERE id = v_stack.id;

    v_expiry := CASE WHEN v_item.duration_seconds > 0
                     THEN now() + make_interval(secs => v_item.duration_seconds)
                     ELSE NULL END;

    INSERT INTO public.expedition_item_uses (player_id, item_id, planet_id, quantity, effect_snapshot)
    VALUES (p_player_id, p_item_id, p_planet_id, 1,
            jsonb_build_object('effect_key', v_item.effect_key,
                               'effect_value', v_item.effect_value,
                               'expires_at', v_expiry,
                               'item_name', v_item.name,
                               'category', v_item.category));

    RETURN jsonb_build_object('item_id', p_item_id, 'effect_key', v_item.effect_key,
                              'effect_value', v_item.effect_value, 'expires_at', v_expiry);
END;
$function$;

revoke all on function public.use_expedition_item(uuid, text, uuid) from public;
revoke all on function public.use_expedition_item(uuid, text, uuid) from anon;
grant execute on function public.use_expedition_item(uuid, text, uuid) to authenticated;
grant execute on function public.use_expedition_item(uuid, text, uuid) to service_role;

-- ---------------------------------- 3) slots: base + ajustes del universo + objetos activos (sin inventar)
create or replace function public.get_player_expedition_slots(p_player_id uuid)
returns integer
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    SELECT 1
         + floor(COALESCE(public.get_active_expedition_item_effect(p_player_id, NULL, 'expedition_slots'), 0))::integer
         + COALESCE((
               SELECT es.bonus_expedition_slots
               FROM public.expedition_settings es
               JOIN public.players pl ON pl.universe_id = es.universe_id
               WHERE pl.id = p_player_id
           ), 0)::integer;
$function$;

-- --------------------------------------------------------- 4) contratos de lectura para el cliente
create or replace function public.get_player_expedition_reports(p_limit integer DEFAULT 25)
returns table(
    fleet_id uuid, created_at timestamp with time zone, resolved_at timestamp with time zone,
    outcome text, event_type text,
    metal numeric, crystal numeric, deuterium numeric, dark_matter numeric,
    ships jsonb, item_id text, item_name text, item_quantity integer,
    merchant_resource text, merchant_metal_rate numeric, merchant_crystal_rate numeric, merchant_deuterium_rate numeric,
    battle_id uuid, enemy_ships jsonb,
    delay_seconds numeric, speedup_seconds numeric,
    lost_ships jsonb, loss_percentage numeric,
    reward_tier text, reward_multiplier numeric, cargo_capacity numeric,
    max_resource_find numeric, scaled_resource_find numeric
)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
with me as (
    select pl.id as player_id from public.players pl where pl.user_id = auth.uid()
)
select
    er.fleet_id, er.created_at, er.resolved_at, er.outcome, er.event_type,
    er.metal, er.crystal, er.deuterium, er.dark_matter,
    er.ships, er.item_id, d.name, er.item_quantity,
    er.merchant_resource, er.merchant_metal_rate, er.merchant_crystal_rate, er.merchant_deuterium_rate,
    er.battle_id, er.enemy_ships,
    er.delay_seconds, er.speedup_seconds,
    er.lost_ships, er.loss_percentage,
    er.reward_tier, er.reward_multiplier, er.cargo_capacity,
    er.max_resource_find, er.scaled_resource_find
from public.expedition_results er
left join public.expedition_item_definitions d on d.id = er.item_id
where (select count(*) from me) = 1
  and er.player_id = (select me.player_id from me)
order by er.created_at desc
limit greatest(1, least(coalesce(p_limit, 25), 100));
$function$;

create or replace function public.get_player_expedition_item_status()
returns table(
    kind text, item_id text, item_name text, category text,
    effect_key text, effect_value numeric, quantity integer,
    expires_at timestamp with time zone, remaining_seconds integer
)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
with me as (
    select pl.id as player_id from public.players pl where pl.user_id = auth.uid()
),
stacks as (
    select 'STACK'::text as kind, pei.item_id, d.name as item_name, d.category,
           d.effect_key, d.effect_value, pei.quantity, pei.expires_at,
           null::integer as remaining_seconds
    from public.player_expedition_items pei
    join public.expedition_item_definitions d on d.id = pei.item_id
    where (select count(*) from me) = 1
      and pei.player_id = (select me.player_id from me)
      and pei.active = true and pei.quantity > 0
),
effects as (
    select 'EFFECT'::text as kind, eu.item_id,
           coalesce(eu.effect_snapshot->>'item_name', d.name) as item_name,
           coalesce(eu.effect_snapshot->>'category', d.category) as category,
           eu.effect_snapshot->>'effect_key' as effect_key,
           (eu.effect_snapshot->>'effect_value')::numeric as effect_value,
           eu.quantity,
           (eu.effect_snapshot->>'expires_at')::timestamptz as expires_at,
           greatest(0, floor(extract(epoch from ((eu.effect_snapshot->>'expires_at')::timestamptz - now()))))::integer as remaining_seconds
    from public.expedition_item_uses eu
    left join public.expedition_item_definitions d on d.id = eu.item_id
    where (select count(*) from me) = 1
      and eu.player_id = (select me.player_id from me)
      and (eu.effect_snapshot->>'expires_at' IS NULL
           OR (eu.effect_snapshot->>'expires_at')::timestamptz > now())
)
select * from stacks
union all
select * from effects
order by kind desc, item_id;
$function$;

create or replace function public.get_player_expedition_slot_status()
returns table(
    base_slots integer, settings_bonus integer, item_bonus integer,
    total_slots integer, used_slots integer, available_slots integer
)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
with me as (
    select pl.id as player_id from public.players pl where pl.user_id = auth.uid()
),
p as (select me.player_id from me where (select count(*) from me) = 1),
vals as (
    select 1 as base_slots,
           coalesce((select es.bonus_expedition_slots
                     from public.expedition_settings es
                     join public.players pl on pl.universe_id = es.universe_id
                     where pl.id = (select p.player_id from p)), 0)::integer as settings_bonus,
           floor(coalesce((select public.get_active_expedition_item_effect((select p.player_id from p), NULL, 'expedition_slots')), 0))::integer as item_bonus,
           coalesce((select public.get_active_expedition_count((select p.player_id from p))), 0)::integer as used_slots
)
select v.base_slots, v.settings_bonus, v.item_bonus,
       v.base_slots + v.settings_bonus + v.item_bonus as total_slots,
       v.used_slots,
       greatest(0, v.base_slots + v.settings_bonus + v.item_bonus - v.used_slots) as available_slots
from vals v
where (select count(*) from p) = 1;
$function$;

revoke all on function public.get_player_expedition_reports(integer) from public;
revoke all on function public.get_player_expedition_reports(integer) from anon;
grant execute on function public.get_player_expedition_reports(integer) to authenticated;
grant execute on function public.get_player_expedition_reports(integer) to service_role;

revoke all on function public.get_player_expedition_item_status() from public;
revoke all on function public.get_player_expedition_item_status() from anon;
grant execute on function public.get_player_expedition_item_status() to authenticated;
grant execute on function public.get_player_expedition_item_status() to service_role;

revoke all on function public.get_player_expedition_slot_status() from public;
revoke all on function public.get_player_expedition_slot_status() from anon;
grant execute on function public.get_player_expedition_slot_status() to authenticated;
grant execute on function public.get_player_expedition_slot_status() to service_role;
