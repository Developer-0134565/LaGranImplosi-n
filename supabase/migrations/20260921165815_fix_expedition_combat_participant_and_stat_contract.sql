-- ============================================================================
-- COMBAT ENGINE PHASE 1 — CB-01 REPAIR (forward-only)
-- ----------------------------------------------------------------------------
-- Expedition combat (pirates / aliens) converges onto the SAME authoritative
-- combat-unit + participant contract as the single-attacker ATTACK path:
--
--   1. the battle gains explicit participants:
--        ATTACKER / FLEET  = the expedition movement itself
--        DEFENDER / ENEMY  = the NPC hostile squadron (no player, no planet)
--   2. every combat_individual_units row written by the expedition creators
--      carries participant_id, so the participant-aware damage ledger
--      (calculate_combat_round_pending_damage joins shots to the round snapshot
--      on participant equality) can resolve damage and produce losses;
--   3. unit statistics come from the certified canonical readers
--      get_combat_ship_attack / get_combat_ship_shield / get_combat_ship_hull
--      instead of raw ship_definitions values (same normalization as ATTACK:
--      hull is the canonical hull, structural_integrity is hull*10).
--
-- NO formula, threshold, explosion probability, round count, rapidfire, debris,
-- repair, winner/draw or balance rule is changed here. The alien technology
-- multiplier expression is preserved verbatim (see README_COMBAT_ENGINE section 15
-- for the recorded dead research-id lookup).
--
-- Both expedition creators are patched by exact fragment substitution with
-- occurrence assertions, so every non-targeted character of the LIVE definition
-- stays byte-identical.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Participant model: the NPC hostile side of an expedition battle
-- ---------------------------------------------------------------------------
alter table public.combat_battle_participants
  drop constraint if exists combat_battle_participants_participant_type_check;
alter table public.combat_battle_participants
  add constraint combat_battle_participants_participant_type_check
  check (participant_type = any (array['FLEET'::text,'PLANET'::text,'ENEMY'::text]));

alter table public.combat_battle_participants
  drop constraint if exists combat_battle_participants_shape_check;
alter table public.combat_battle_participants
  add constraint combat_battle_participants_shape_check
  check (
       (participant_type = 'FLEET'  and fleet_id is not null and origin_planet_id is not null and planet_id is null)
    or (participant_type = 'PLANET' and planet_id is not null and fleet_id is null and origin_planet_id is null)
    or (participant_type = 'ENEMY'  and fleet_id is null and planet_id is null and origin_planet_id is null)
  );

alter table public.combat_battle_participants
  drop constraint if exists combat_battle_participants_side_type_check;
alter table public.combat_battle_participants
  add constraint combat_battle_participants_side_type_check
  check (
       (side = 'ATTACKER' and participant_type = 'FLEET')
    or (side = 'DEFENDER' and participant_type = any (array['FLEET'::text,'PLANET'::text,'ENEMY'::text]))
  );

-- An ENEMY participant is an NPC squadron and has no owning player.
-- Every FLEET / PLANET participant still must have one.
alter table public.combat_battle_participants alter column player_id drop not null;
alter table public.combat_battle_participants
  drop constraint if exists combat_battle_participants_player_required;
alter table public.combat_battle_participants
  add constraint combat_battle_participants_player_required
  check (participant_type = 'ENEMY' or player_id is not null);

-- ---------------------------------------------------------------------------
-- 2a. resolve_expedition_pirates: participant identity
-- ---------------------------------------------------------------------------
do $cb01a$
declare
  v_def text; v_new text; v_occ integer; r record;
begin
  for r in
    select * from (values
      (1, 1,
       $o$DECLARE f RECORD;v_battle uuid;pid uuid;$o$,
       $n$DECLARE f RECORD;v_battle uuid;pid uuid;v_attacker_participant uuid;v_enemy_participant uuid;$n$),
      (2, 1,
       $o$RETURNING id INTO v_battle;$o$,
       $n$RETURNING id INTO v_battle;INSERT INTO public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type) VALUES(v_battle,'ATTACKER','FLEET',p_fleet_id,NULL,pid,f.origin_planet_id,f.mission_type) RETURNING id INTO v_attacker_participant;INSERT INTO public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type) VALUES(v_battle,'DEFENDER','ENEMY',NULL,NULL,NULL,NULL,'EXPEDITION') RETURNING id INTO v_enemy_participant;$n$),
      (3, 3,
       $o$combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)$o$,
       $n$combat_individual_units(battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)$n$)
    ) as t(ord, expected, old_frag, new_frag) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='resolve_expedition_pirates';
    if v_def is null then raise exception 'CB-01: resolve_expedition_pirates not found'; end if;

    v_occ := (length(v_def)-length(replace(v_def,r.old_frag,'')))/length(r.old_frag);
    if v_occ <> r.expected then
      raise exception 'CB-01: pirates fragment % matched % time(s), expected %', r.ord, v_occ, r.expected;
    end if;

    v_new := replace(v_def, r.old_frag, r.new_frag);
    execute v_new;
  end loop;
end
$cb01a$;

-- ---------------------------------------------------------------------------
-- 2b. resolve_expedition_pirates: canonical unit statistics
-- ---------------------------------------------------------------------------
do $cb01b$
declare
  v_def text; v_new text; v_occ integer; r record;
begin
  for r in
    select * from (values
      (1, 1,
       $o$VALUES(v_battle,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);$o$,
       $n$VALUES(v_battle,1,v_attacker_participant,'ATTACKER','SHIP',x.ship_id,n,public.get_combat_ship_attack(pid,x.ship_id),public.get_combat_ship_shield(pid,x.ship_id),public.get_combat_ship_shield(pid,x.ship_id),public.get_combat_ship_hull(pid,x.ship_id)*10,public.get_combat_ship_hull(pid,x.ship_id),public.get_combat_ship_hull(pid,x.ship_id),true);$n$),
      (2, 1,
       $o$VALUES(v_battle,1,'DEFENDER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);$o$,
       $n$VALUES(v_battle,1,v_enemy_participant,'DEFENDER','SHIP',x.ship_id,n,public.get_combat_ship_attack(NULL,x.ship_id),public.get_combat_ship_shield(NULL,x.ship_id),public.get_combat_ship_shield(NULL,x.ship_id),public.get_combat_ship_hull(NULL,x.ship_id)*10,public.get_combat_ship_hull(NULL,x.ship_id),public.get_combat_ship_hull(NULL,x.ship_id),true);$n$),
      (3, 1,
       $o$VALUES(v_battle,1,'DEFENDER','SHIP',fixed_id,100000+n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);$o$,
       $n$VALUES(v_battle,1,v_enemy_participant,'DEFENDER','SHIP',fixed_id,100000+n,public.get_combat_ship_attack(NULL,fixed_id),public.get_combat_ship_shield(NULL,fixed_id),public.get_combat_ship_shield(NULL,fixed_id),public.get_combat_ship_hull(NULL,fixed_id)*10,public.get_combat_ship_hull(NULL,fixed_id),public.get_combat_ship_hull(NULL,fixed_id),true);$n$)
    ) as t(ord, expected, old_frag, new_frag) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='resolve_expedition_pirates';
    if v_def is null then raise exception 'CB-01: resolve_expedition_pirates not found'; end if;

    v_occ := (length(v_def)-length(replace(v_def,r.old_frag,'')))/length(r.old_frag);
    if v_occ <> r.expected then
      raise exception 'CB-01: pirates stat fragment % matched % time(s), expected %', r.ord, v_occ, r.expected;
    end if;

    v_new := replace(v_def, r.old_frag, r.new_frag);
    execute v_new;
  end loop;
end
$cb01b$;

-- ---------------------------------------------------------------------------
-- 3a. resolve_expedition_aliens: participant identity
-- ---------------------------------------------------------------------------
do $cb01c$
declare
  v_def text; v_new text; v_occ integer; r record;
begin
  for r in
    select * from (values
      (1, 1,
       $o$DECLARE f public.fleet_movements%ROWTYPE;b uuid;pid uuid;$o$,
       $n$DECLARE f public.fleet_movements%ROWTYPE;b uuid;pid uuid;v_attacker_participant uuid;v_enemy_participant uuid;$n$),
      (2, 1,
       $o$RETURNING id INTO b;$o$,
       $n$RETURNING id INTO b;INSERT INTO public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type) VALUES(b,'ATTACKER','FLEET',p_fleet_id,NULL,pid,f.origin_planet_id,f.mission_type) RETURNING id INTO v_attacker_participant;INSERT INTO public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type) VALUES(b,'DEFENDER','ENEMY',NULL,NULL,NULL,NULL,'EXPEDITION') RETURNING id INTO v_enemy_participant;$n$),
      (3, 3,
       $o$combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)$o$,
       $n$combat_individual_units(battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)$n$)
    ) as t(ord, expected, old_frag, new_frag) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='resolve_expedition_aliens';
    if v_def is null then raise exception 'CB-01: resolve_expedition_aliens not found'; end if;

    v_occ := (length(v_def)-length(replace(v_def,r.old_frag,'')))/length(r.old_frag);
    if v_occ <> r.expected then
      raise exception 'CB-01: aliens fragment % matched % time(s), expected %', r.ord, v_occ, r.expected;
    end if;

    v_new := replace(v_def, r.old_frag, r.new_frag);
    execute v_new;
  end loop;
end
$cb01c$;

-- ---------------------------------------------------------------------------
-- 3b. resolve_expedition_aliens: canonical unit statistics
--     (the alien multiplier expression is preserved verbatim)
-- ---------------------------------------------------------------------------
do $cb01d$
declare
  v_def text; v_new text; v_occ integer; r record;
begin
  for r in
    select * from (values
      (1, 1,
       $o$VALUES(b,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);$o$,
       $n$VALUES(b,1,v_attacker_participant,'ATTACKER','SHIP',x.ship_id,n,public.get_combat_ship_attack(pid,x.ship_id),public.get_combat_ship_shield(pid,x.ship_id),public.get_combat_ship_shield(pid,x.ship_id),public.get_combat_ship_hull(pid,x.ship_id)*10,public.get_combat_ship_hull(pid,x.ship_id),public.get_combat_ship_hull(pid,x.ship_id),true);$n$),
      (2, 1,
       $o$VALUES(b,1,'DEFENDER','SHIP',x.ship_id,n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true);$o$,
       $n$VALUES(b,1,v_enemy_participant,'DEFENDER','SHIP',x.ship_id,n,round(public.get_combat_ship_attack(NULL,x.ship_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_shield(NULL,x.ship_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_shield(NULL,x.ship_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_hull(NULL,x.ship_id)*(1+alien_tech*0.10))*10,round(public.get_combat_ship_hull(NULL,x.ship_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_hull(NULL,x.ship_id)*(1+alien_tech*0.10)),true);$n$),
      (3, 1,
       $o$VALUES(b,1,'DEFENDER','SHIP',fixed_id,100000+n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true);$o$,
       $n$VALUES(b,1,v_enemy_participant,'DEFENDER','SHIP',fixed_id,100000+n,round(public.get_combat_ship_attack(NULL,fixed_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_shield(NULL,fixed_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_shield(NULL,fixed_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_hull(NULL,fixed_id)*(1+alien_tech*0.10))*10,round(public.get_combat_ship_hull(NULL,fixed_id)*(1+alien_tech*0.10)),round(public.get_combat_ship_hull(NULL,fixed_id)*(1+alien_tech*0.10)),true);$n$)
    ) as t(ord, expected, old_frag, new_frag) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='resolve_expedition_aliens';
    if v_def is null then raise exception 'CB-01: resolve_expedition_aliens not found'; end if;

    v_occ := (length(v_def)-length(replace(v_def,r.old_frag,'')))/length(r.old_frag);
    if v_occ <> r.expected then
      raise exception 'CB-01: aliens stat fragment % matched % time(s), expected %', r.ord, v_occ, r.expected;
    end if;

    v_new := replace(v_def, r.old_frag, r.new_frag);
    execute v_new;
  end loop;
end
$cb01d$;

-- ---------------------------------------------------------------------------
-- 4. Post-conditions: both expedition creators now satisfy the combat contract
-- ---------------------------------------------------------------------------
do $cb01e$
declare
  v_def text;
  v_fn text;
begin
  foreach v_fn in array array['resolve_expedition_pirates','resolve_expedition_aliens'] loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname=v_fn;

    if v_def is null then
      raise exception 'CB-01: % missing after repair', v_fn;
    end if;
    if v_def not like '%participant_id,side,unit_type%' then
      raise exception 'CB-01: % still writes combat units without participant_id', v_fn;
    end if;
    if v_def not like '%INTO v_attacker_participant%' or v_def not like '%INTO v_enemy_participant%' then
      raise exception 'CB-01: % does not create both battle participants', v_fn;
    end if;
    if v_def not like '%get_combat_ship_attack(%' then
      raise exception 'CB-01: % does not use the canonical combat stat readers', v_fn;
    end if;
  end loop;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname in ('resolve_expedition_pirates','resolve_expedition_aliens')
      and (p.prosrc like '%VALUES(v_battle,1,''ATTACKER''%' or p.prosrc like '%VALUES(b,1,''ATTACKER''%')
  ) then
    raise exception 'CB-01: a raw-stat expedition unit insert survived the repair';
  end if;
end
$cb01e$;
