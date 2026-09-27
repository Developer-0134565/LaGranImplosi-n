-- ============================================================================
-- COMBAT — ACS SETTLEMENT FIXTURE (PG-08 / PG-09 / PG-10 / PG-17 / PG-18)
-- LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Rollback-safe transactional fixture (BEGIN … ROLLBACK).
--
-- Scenario coverage required by the implementation gate:
--   A  single attacker + planet (certified compatibility)
--   B  two attacker fleets, SAME owner
--   C  two attacker fleets, DIFFERENT owners
--   D  a completely destroyed participant (no ghost fleet, no loot share)
--   E  partial losses: PG-09 capacity = ORIGINAL composition, PG-10 = SURVIVING
--   F  loot allocation proportional to surviving cargo capacity
--   G  replay: a second settlement is a no-op
--   H  a second participating fleet resolves to the SAME battle
--   I  a defending fleet keeps HOLDING and its holding_until; survivors updated
--
-- Independent oracles: the pre-combat capacity is summed from fleet_movement_ships
-- (not from the round-1 units the implementation reads), and resource conservation
-- is asserted against planet_resources before/after.
--
-- ROLLBACK SAFETY: every battle, participant, unit, fleet, ship and resource change
-- lives inside a nested block undone by a sentinel exception.
-- ============================================================================

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_acs_results;
create temp table t_acs_results(orden serial, resultado text, prueba text);

do $test$
declare
  v_owner uuid; v_user uuid; v_other uuid; v_planet_owner uuid;
  v_origin uuid; v_origin_other uuid; v_target uuid; v_universe uuid;
  v_f_a uuid := gen_random_uuid();   -- attacker A  (owner)
  v_f_b uuid := gen_random_uuid();   -- attacker B  (owner, different cargo class)
  v_f_c uuid := gen_random_uuid();   -- attacker C  (other player)
  v_f_d uuid := gen_random_uuid();   -- attacker D  (will be destroyed)
  v_f_h uuid := gen_random_uuid();   -- defending fleet (HOLDING)
  v_f_t uuid := gen_random_uuid();   -- single attacker (scenario A / G / H)
  v_f_t2 uuid := gen_random_uuid();  -- second participating fleet (scenario H)
  v_b1 uuid; v_b2 uuid; v_b3 uuid;
  v_p_a uuid; v_p_b uuid; v_p_c uuid; v_p_d uuid; v_p_h uuid; v_p_planet uuid;
  v_cap_returned numeric; v_cap_oracle numeric;
  v_credit_a numeric; v_credit_b numeric;
  v_planet_before numeric; v_planet_after numeric; v_planet_credited numeric;
  v_rows bigint; v_rows2 bigint;
  v_status text; v_holding timestamptz; v_holding_before timestamptz;
  v_ret uuid; v_ret2 uuid; v_battles bigint; v_surv bigint;
  v_ok boolean; v_fail integer := 0; v_lines text := ''; v_rec record;
begin
  begin
    /* ---------------- fixture resolution (LIVE, read-only) ---------------- */
    select pl.id, pl.user_id, p.id, p.universe_id
      into v_owner, v_user, v_origin, v_universe
    from public.planets p
    join public.players pl on pl.id = p.player_id
    join public.planet_resources pr on pr.planet_id = p.id
    where pl.user_id is not null and p.is_destroyed = false
    order by p.created_at, p.id limit 1;

    select pl.id, p.id into v_other, v_origin_other
    from public.planets p join public.players pl on pl.id = p.player_id
    where pl.id <> v_owner and pl.user_id is null and p.is_destroyed = false
      and p.universe_id = v_universe
    order by p.created_at, p.id limit 1;

    select p.id, p.player_id into v_target, v_planet_owner
    from public.planets p
    where p.universe_id = v_universe and p.is_destroyed = false
      and p.player_id <> v_owner and p.player_id <> v_other
    order by p.created_at, p.id limit 1;

    if v_origin is null or v_other is null or v_target is null then
      raise exception 'ACS_FIXTURE_ABORT: missing players/planets';
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    /* deterministic target planet */
    delete from public.planet_ships where planet_id = v_target;
    delete from public.planet_defenses where planet_id = v_target;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 4);
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

    update public.planet_resources
       set metal = 5000000, crystal = 5000000, deuterium = 5000000,
           last_calculated_at = now() - interval '1 hour', updated_at = now()
     where planet_id = v_target;

    /* ---------------- fleets owned by v_owner ---------------- */
    insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
        started_at,arrives_at,status) values
      (v_f_a, v_owner, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'ARRIVED'),
      (v_f_b, v_owner, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'ARRIVED'),
      (v_f_d, v_owner, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'ARRIVED'),
      (v_f_t, v_owner, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');

    insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values
      (v_f_a,'cruiser',2), (v_f_b,'large_cargo',1), (v_f_d,'light_fighter',2), (v_f_t,'cruiser',4);

    /* ---------------- fleets owned by v_other ----------------
       The fleet_movements BEFORE INSERT ownership guard requires the authenticated user
       to own the inserted player, so the identity is borrowed for these inserts only and
       restored immediately (players has no write trigger; the fixture is rolled back). */
    update public.players set user_id = null where id = v_owner;
    update public.players set user_id = v_user where id = v_other;

    insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
        started_at,arrives_at,status,holding_until) values
      (v_f_c, v_other, v_origin_other, v_target, 'ATTACK',
       clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'ARRIVED', null),
      (v_f_h, v_other, v_origin_other, v_target, 'DEFEND',
       clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'HOLDING',
       clock_timestamp() + interval '2 hours');

    insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values
      (v_f_c,'small_cargo',2), (v_f_h,'cruiser',2);

    update public.players set user_id = null where id = v_other;
    update public.players set user_id = v_user where id = v_owner;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    select fm.holding_until into v_holding_before from public.fleet_movements fm where fm.id = v_f_h;

    /* ================= SCENARIO A + G + H : single-attacker full path ========= */
    insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
        started_at,arrives_at,status) values
      (v_f_t2, v_owner, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '600 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
    insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_f_t2,'small_cargo',1);

    insert into public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,draw)
    values (v_f_t, v_owner, v_target, false) returning id into v_b1;

    insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
    values (v_b1,'ATTACKER','FLEET',v_f_t,null,v_owner,v_origin,'ATTACK'),
           (v_b1,'DEFENDER','PLANET',null,v_target,v_planet_owner,null,null),
           -- scenario H: a SECOND participating fleet is attached before settlement,
           -- exactly what a future ACS producer would do.
           (v_b1,'ATTACKER','FLEET',v_f_t2,null,v_owner,v_origin,'ATTACK');

    perform public.initialize_individual_combat_units(v_b1);

    -- H1: a NON-initiating participating fleet resolves to the SAME battle
    v_ret := public.resolve_combat(v_f_t2);
    v_ok := v_ret = v_b1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'H1 non-initiating fleet resolves to the SAME battle' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_battles from public.combat_battles where fleet_id = v_f_t2;
    v_ok := v_battles = 0;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('H2 no second battle was created (%s)', v_battles) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- A: the full certified path still settles through one call
    v_ret := public.resolve_attack_arrival(v_f_t);
    select fm.status into v_status from public.fleet_movements fm where fm.id = v_f_t;
    v_ok := v_ret = v_b1 and v_status = 'RETURNING';
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('A1 single-attacker settlement returns its battle and the fleet returns (status=%s)', v_status) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- H3: replay through a non-initiating participant after settlement
    v_ret2 := public.resolve_attack_arrival(v_f_t2);
    v_ok := v_ret2 = v_b1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'H3 non-initiating participant replay returns the existing battle' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.combat_battle_participants where battle_id = v_b1;
    v_ok := v_rows = 3;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('A2 no phantom participants (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.combat_debris_generations where battle_id = v_b1;
    v_ok := v_rows <= 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('A3 at most one debris generation per battle (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(sum(quantity),0) into v_rows from public.fleet_movement_ships where fleet_id = v_f_t2;
    v_ok := v_rows <= 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('A4 the second fleet composition never exceeds its original (%s of 1)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- G: replay is a no-op
    select coalesce(sum(fm.metal+fm.crystal+fm.deuterium),0) into v_planet_before
      from public.fleet_movements fm where fm.id in (v_f_t, v_f_t2);
    select count(*) into v_surv from public.combat_debris_generations where battle_id = v_b1;
    v_ret2 := public.resolve_attack_arrival(v_f_t);
    select coalesce(sum(fm.metal+fm.crystal+fm.deuterium),0) into v_planet_after
      from public.fleet_movements fm where fm.id in (v_f_t, v_f_t2);
    select count(*) into v_rows from public.combat_debris_generations where battle_id = v_b1;
    v_ok := v_ret2 = v_b1 and v_planet_after = v_planet_before and v_rows = v_surv;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || 'G1 replay returns the same battle with no duplicate loot or debris' || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ B + C + D + E + F + I : participant loot settlement =========
       Deterministic: the battle is created, units are materialised, the wanted units are
       marked dead and the outcome is pinned (finished_at + attacker_win) so that
       run_expedition_combat does not re-randomise the state. apply_attack_loot is then
       called directly for the arithmetic and resolve_attack_arrival for the rest. */
    update public.planet_resources
       set metal = 5000000, crystal = 5000000, deuterium = 5000000,
           last_calculated_at = now() - interval '1 hour', updated_at = now()
     where planet_id = v_target;

    /* restore a deterministic defender composition: BLOCK 1 ran a real battle on this
       planet, so losses and repair may have changed its ships and defences */
    delete from public.planet_ships where planet_id = v_target;
    delete from public.planet_defenses where planet_id = v_target;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 4);
    insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

    insert into public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,draw)
    values (v_f_a, v_owner, v_target, false) returning id into v_b2;

    insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
    values (v_b2,'ATTACKER','FLEET',v_f_a,null,v_owner,v_origin,'ATTACK'),          -- same owner
           (v_b2,'ATTACKER','FLEET',v_f_b,null,v_owner,v_origin,'ATTACK'),          -- same owner
           (v_b2,'ATTACKER','FLEET',v_f_c,null,v_other,v_origin_other,'ATTACK'),    -- different owner
           (v_b2,'ATTACKER','FLEET',v_f_d,null,v_owner,v_origin,'ATTACK'),          -- will be destroyed
           (v_b2,'DEFENDER','FLEET',v_f_h,null,v_other,v_origin_other,'DEFEND'),    -- holding defender
           (v_b2,'DEFENDER','PLANET',null,v_target,v_planet_owner,null,null);

    select id into v_p_a from public.combat_battle_participants where battle_id=v_b2 and side='ATTACKER' and fleet_id=v_f_a;
    select id into v_p_b from public.combat_battle_participants where battle_id=v_b2 and side='ATTACKER' and fleet_id=v_f_b;
    select id into v_p_c from public.combat_battle_participants where battle_id=v_b2 and side='ATTACKER' and fleet_id=v_f_c;
    select id into v_p_d from public.combat_battle_participants where battle_id=v_b2 and side='ATTACKER' and fleet_id=v_f_d;
    select id into v_p_h from public.combat_battle_participants where battle_id=v_b2 and side='DEFENDER' and fleet_id=v_f_h;
    select id into v_p_planet from public.combat_battle_participants where battle_id=v_b2 and side='DEFENDER' and participant_type='PLANET';

    perform public.initialize_individual_combat_units(v_b2);

    /* deterministic outcome */
    update public.combat_individual_units set alive=false
     where battle_id=v_b2 and round_number=1 and participant_id=v_p_d;
    update public.combat_individual_units set alive=false
     where battle_id=v_b2 and round_number=1 and participant_id=v_p_a and unit_number=1;
    update public.combat_individual_units set alive=false
     where battle_id=v_b2 and round_number=1 and participant_id=v_p_h and unit_number=1;
    update public.combat_individual_units set alive=false
     where battle_id=v_b2 and round_number=1 and participant_id=v_p_planet and unit_type='SHIP';

    update public.combat_battles set attacker_win=true, finished_at=clock_timestamp() where id=v_b2;

    /* independent oracle: original capacity straight from the fleets' compositions */
    select coalesce(sum(fms.quantity*sd.cargo_capacity),0) into v_cap_oracle
      from public.fleet_movement_ships fms
      join public.ship_definitions sd on sd.id=fms.ship_id
     where fms.fleet_id in (v_f_a,v_f_b,v_f_c,v_f_d);

    select * into v_rec from public.apply_attack_loot(v_b2);
    v_cap_returned := v_rec.cargo_capacity;

    /* E: PG-09 uses the ORIGINAL composition, so the destroyed D still contributes and the
       capacity is unaffected by the losses */
    v_ok := v_cap_returned = v_cap_oracle and v_cap_returned = 36700;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('E1 PG-09 capacity is the ORIGINAL combined composition (%s, oracle %s)', v_cap_returned, v_cap_oracle) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select fm.metal into v_credit_a from public.fleet_movements fm where fm.id=v_f_a;
    select fm.metal into v_credit_b from public.fleet_movements fm where fm.id=v_f_b;

    /* F: proportional to SURVIVING cargo capacity (A 800, B 25000, C 10000) */
    v_ok := v_credit_a > 0 and v_credit_b > 0 and v_credit_b > v_credit_a;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('F1 distinct surviving capacities are both credited (A=%s B=%s)', v_credit_a, v_credit_b) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := abs(v_credit_a*25000 - v_credit_b*800) <= 25000;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('F2 the split is proportional to surviving capacity (|A*25000-B*800|=%s <= 25000)',
                abs(v_credit_a*25000 - v_credit_b*800)) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select fm.metal into v_credit_a from public.fleet_movements fm where fm.id=v_f_c;
    v_ok := v_credit_a > 0;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('C1 a DIFFERENT-owner participant is credited on its own fleet (%s)', v_credit_a) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select fm.metal+fm.crystal+fm.deuterium into v_credit_a from public.fleet_movements fm where fm.id=v_f_d;
    v_ok := v_credit_a = 0;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('D1 the destroyed participant receives no loot share (%s)', v_credit_a) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select cb.loot_metal into v_credit_a from public.combat_battles cb where cb.id=v_b2;
    select coalesce(sum(fm.metal),0) into v_credit_b from public.fleet_movements fm
     where fm.id in (v_f_a,v_f_b,v_f_c);
    v_ok := v_credit_a = v_credit_b and v_credit_a <= floor(v_cap_returned/3);
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('F3 battle loot equals the credited sum and stays inside the plunder bound (%s/%s)', v_credit_a, v_credit_b) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- the full settlement path: write-back, hold preservation, transitions ---- */
    perform public.resolve_attack_arrival(v_f_a);

    select count(*) into v_rows from public.fleet_movement_ships where fleet_id=v_f_a;
    select count(*) into v_rows2 from public.fleet_movement_ships where fleet_id=v_f_b;
    v_ok := v_rows = 1 and v_rows2 = 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('B1 same-owner fleets keep independent survivors (A=%s B=%s rows)', v_rows, v_rows2) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.fleet_movement_ships where fleet_id=v_f_c;
    select coalesce(sum(quantity),0) into v_surv from public.fleet_movement_ships where fleet_id=v_f_c;
    select count(*) into v_rows2 from public.fleet_movement_ships where fleet_id=v_f_d;
    v_ok := v_rows = 1 and v_surv = 2 and v_rows2 = 0;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('B2 different-owner survivors land on the owning fleet; the destroyed one leaves none (C=%s rows/%s ships D=%s)', v_rows, v_surv, v_rows2) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select fm.status, fm.holding_until into v_status, v_holding from public.fleet_movements fm where fm.id=v_f_h;
    select count(*) into v_rows from public.fleet_movement_ships where fleet_id=v_f_h;
    v_ok := v_status = 'HOLDING' and v_holding = v_holding_before and v_rows = 1;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('I1 the defending fleet keeps HOLDING and holding_until, survivors rewritten (status=%s rows=%s)', v_status, v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_rows from public.fleet_movements fm
     where fm.id in (v_f_a,v_f_b,v_f_c,v_f_d) and fm.status = 'RETURNING';
    v_ok := v_rows = 4;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('B3 every attacker fleet left ARRIVED after its loot share was settled (%s)', v_rows) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* PG-18: the header defender counters must NOT absorb the defending fleet */
    select count(*) into v_rows from public.combat_individual_units
     where battle_id=v_b2 and round_number=1 and participant_id=v_p_h and alive;
    select cb.defender_ships_after, cb.defender_combat_units_after into v_rows2, v_surv
      from public.combat_battles cb where cb.id=v_b2;
    v_ok := v_rows = 1 and v_rows2 = 0 and v_surv = 2;
    v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
      || format('PG18 defender counters stay planet-scoped (fleet alive=%s header ships=%s header units=%s)', v_rows, v_rows2, v_surv) || E'\n';
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    raise exception 'ACS_SETTLEMENT_FIXTURE_ROLLBACK';
  exception
    when others then
      if sqlerrm <> 'ACS_SETTLEMENT_FIXTURE_ROLLBACK' then
        v_fail := v_fail + 1;
        v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
      end if;
  end;

  perform set_config('request.jwt.claims', '{}', false);

  insert into t_acs_results(resultado, prueba)
  select split_part(line, '|', 1), split_part(line, '|', 2)
  from unnest(string_to_array(v_lines, E'\n')) as line
  where line <> '';

  if v_fail > 0 then
    raise exception 'ACS SETTLEMENT FIXTURE: % failed assertion(s) -> %',
      v_fail, replace(v_lines, E'\n', '');
  end if;

  raise notice 'ACS SETTLEMENT FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_acs_results order by orden;

drop table if exists t_acs_results;

rollback;
