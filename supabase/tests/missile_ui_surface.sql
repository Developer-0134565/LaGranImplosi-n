-- MISSILE UI SURFACE FIXTURE - LA GRAN IMPLOSION
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract (20260930231000 + 20260930231100): the Missile System UI is a thin
-- layer over the already-certified backend. This fixture certifies the SECURITY
-- POSTURE that layer depends on. It does NOT re-test the 67 missile cases.
--
-- What it proves:
--   1. `authenticated` keeps EXECUTE on every RPC the UI actually calls, including
--      the newly granted `start_missile_attack`. Without that grant the panel simply
--      cannot launch anything.
--   2. `anon` does NOT reach `start_missile_attack`.
--   3. The read-only missile helpers stay CLOSED to the client. Granting them would
--      bypass the owner-scoped RLS on planet_buildings and expose another empire's
--      silo level, so the UI computes capacity for DISPLAY ONLY and every
--      authoritative gate stays server-side.
--   4. The client cannot write the missile stock or the movement table directly, so
--      the UI can only act through `start_defense` / `start_missile_attack`.
--   5. The launch RPC still resolves ownership through the session and locks the rows.
--
-- LIMITATION: this is a permissions fixture, not a browser run. Browser
-- certification is BLOCKED (no DEV_EMAIL / DEV_PASSWORD) - see README_MISSILE_SYSTEM.md.

begin;

create temp table acl_r(n serial, resultado text, prueba text);

do $t$
declare
  v_client  int;
  v_anon     int;
  v_helpers  int;
  v_missing  text;
  v_ok       boolean;
begin
  -- 1. every client RPC stays authenticated-executable
  select count(*) into v_client
  from (values ('start_missile_attack'),('start_defense'),('can_build_defense'),
               ('start_demolition'),('can_start_demolition'),('start_fleet_mixed'),
               ('start_moon_destruction'),('get_player_messages')) as c(name)
  where exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = c.name
      and has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  select string_agg(c.name, ', ') into v_missing
  from (values ('start_missile_attack'),('start_defense'),('can_build_defense'),
               ('start_demolition'),('can_start_demolition'),('start_fleet_mixed'),
               ('start_moon_destruction'),('get_player_messages')) as c(name)
  where not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = c.name
      and has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  v_ok := v_client = 8 and v_missing is null;
  insert into acl_r(resultado, prueba) values (
    case when v_ok then 'PASS' else 'FAIL' end,
    format('1. authenticated keeps EXECUTE on every client RPC incl. start_missile_attack (%s/8, missing: %s)',
           v_client, coalesce(v_missing, 'none')));

  -- 2. anon must not reach the missile action
  select count(*) into v_anon
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'start_missile_attack'
    and has_function_privilege('anon', p.oid, 'EXECUTE');

  insert into acl_r(resultado, prueba) values (
    case when v_anon = 0 then 'PASS' else 'FAIL' end,
    format('2. anon has NO EXECUTE on start_missile_attack (%s)', v_anon));

  -- 3. read-only helpers stay closed (RLS bypass guard)
  select count(*) into v_helpers
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'calculate_missile_silo_slots','calculate_used_missile_slots',
      'calculate_queued_missile_slots','calculate_free_missile_slots',
      'calculate_missile_range_systems','calculate_missile_flight_seconds',
      'calculate_missile_system_distance','can_fit_missile_slots',
      'missile_slot_rejection_reason','missile_demolition_rejection_reason',
      'order_defenses_for_missile_attack','resolve_missile_attack_arrival')
    and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
      or has_function_privilege('anon', p.oid, 'EXECUTE'));

  insert into acl_r(resultado, prueba) values (
    case when v_helpers = 0 then 'PASS' else 'FAIL' end,
    format('3. missile helpers stay closed to the client, owner-scoped RLS not bypassed (%s exposed)', v_helpers));

  -- 4. the UI cannot write the missile stock or the movement table
  v_ok := has_table_privilege('authenticated','public.planet_defenses','INSERT') = false
     and has_table_privilege('authenticated','public.planet_buildings','INSERT')  = false
     and has_table_privilege('authenticated','public.fleet_movements','INSERT')  = false
     and has_table_privilege('authenticated','public.fleet_movements','UPDATE')  = false;

  insert into acl_r(resultado, prueba) values (
    case when v_ok then 'PASS' else 'FAIL' end,
    '4. client cannot INSERT planet_defenses/planet_buildings nor INSERT/UPDATE fleet_movements');

  -- 5. the launch RPC keeps the ownership chain it was certified with
  select coalesce(bool_and(
           position('user_id = v_auth_user' in p.prosrc) > 0
       and position('auth.uid()' in p.prosrc) > 0
       and position('FOR UPDATE' in p.prosrc) > 0), false)
    into v_ok
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'start_missile_attack';

  v_missing := '5. start_missile_attack resolves ownership via user_id = auth.uid() and locks with FOR UPDATE';
  insert into acl_r(resultado, prueba) values (
    case when v_ok then 'PASS' else 'FAIL' end, v_missing);

  raise notice 'MISSILE UI SURFACE: % PASS of %',
    (select count(*) from acl_r where resultado = 'PASS'),
    (select count(*) from acl_r);
end;
$t$;

select n, resultado, prueba from acl_r order by n;

rollback;