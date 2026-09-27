-- MESSAGING ENGINE — event producers (combat / expedition / colonisation)  (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Second half of the messaging engine (the base — dedupe key, `create_player_message`, `format_coordinates` —
-- is `20260926120000_messaging_engine`). Same design rules: producers are triggers on the tables the engine
-- already writes, ownership is taken from the row the engine wrote, every body is replay-safe through the
-- message dedupe key, and every producer is wrapped in its own exception handler so a messaging failure can
-- never abort a fleet resolution, a combat settlement or an economy update.
begin;

-- --------------------------------------------------------------------------- 4) COMBAT events
-- The battle report is produced for the DEFENDER on every battle (OGameX parity: a counter-espionage
-- skirmish notifies the defender, an attack notifies the defender) and for an ATTACK initiator on its
-- own attack. Expedition battles insert a DEFENDER/ENEMY participant without a player, so nothing is
-- produced for the NPC side. The payload stays in the combat engine tables — the message is a pointer.
create or replace function public.notify_combat_participant()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_battle record;
    v_subject text;
    v_body text;
begin
    select cb.id, cb.fleet_id, cb.attacker_player_id, cb.defender_planet_id,
           fm.mission_type as attacker_mission_type,
           fm.destination_galaxy, fm.destination_system, fm.destination_position
      into v_battle
      from public.combat_battles cb
      left join public.fleet_movements fm on fm.id = cb.fleet_id
     where cb.id = new.battle_id;

    if not found then
        return new;
    end if;

    if new.side = 'ATTACKER'
       and new.mission_type = 'ATTACK'
       and new.player_id is not null then
        begin
            perform public.create_player_message(
                new.player_id, null, 'Battle report',
                format('The battle at %s is resolved. Open your battle reports for the full rounds.',
                       public.format_coordinates(v_battle.destination_galaxy, v_battle.destination_system,
                                                 v_battle.destination_position)),
                'battle_report:' || new.battle_id::text);
        exception when others then
            raise warning 'MESSAGE_PRODUCER_FAILED battle=% error=%', new.battle_id, sqlerrm;
        end;

    elsif new.side = 'DEFENDER'
          and new.participant_type in ('PLANET', 'FLEET')
          and new.player_id is not null then
        begin
            perform public.create_player_message(
                new.player_id, null, 'Battle report',
                format('Your %s was attacked and the battle is resolved.',
                       case when new.participant_type = 'PLANET' then 'planet' else 'fleet' end),
                'battle_report_defender:' || new.battle_id::text);
        exception when others then
            raise warning 'MESSAGE_PRODUCER_FAILED battle=% error=%', new.battle_id, sqlerrm;
        end;

        if v_battle.attacker_mission_type = 'ATTACK' then
            begin
                perform public.create_player_message(
                    new.player_id, null, 'Attack received',
                    format('An attack from an enemy fleet reached %s.',
                           public.format_coordinates(v_battle.destination_galaxy, v_battle.destination_system,
                                                     v_battle.destination_position)),
                    'attack_received:' || new.battle_id::text);
            exception when others then
                raise warning 'MESSAGE_PRODUCER_FAILED battle=% error=%', new.battle_id, sqlerrm;
            end;
        end if;
    end if;

    return new;
end;
$function$;

comment on function public.notify_combat_participant() is
$c$AFTER INSERT trigger on combat_battle_participants: produces the battle report for an ATTACK initiator, the battle
report for a defending planet/fleet, and the "attack received" notice. Expedition NPC battles (DEFENDER/ENEMY, no
player) produce nothing. Ownership comes from the participant row the engine itself wrote.$c$;

drop trigger if exists trg_notify_combat_participant on public.combat_battle_participants;
create trigger trg_notify_combat_participant
    after insert on public.combat_battle_participants
    for each row
    execute function public.notify_combat_participant();

-- --------------------------------------------------------------------------- 5) EXPEDITION events
create or replace function public.notify_expedition_result()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    if new.player_id is null then
        return new;
    end if;

    begin
        perform public.create_player_message(
            new.player_id, null,
            'Expedition report: ' || coalesce(new.outcome, 'UNKNOWN'),
            format('Your expedition resolved with the outcome %s. Open your expedition reports for the details.',
                   coalesce(new.outcome, 'UNKNOWN')),
            'expedition:' || new.fleet_id::text);
    exception when others then
        raise warning 'MESSAGE_PRODUCER_FAILED expedition=% error=%', new.fleet_id, sqlerrm;
    end;

    return new;
end;
$function$;

comment on function public.notify_expedition_result() is
$c$AFTER INSERT trigger on expedition_results: notifies the expedition owner (ownership = expedition_results.player_id)
that an outcome was resolved. The detailed payload remains expedition_results / get_player_expedition_reports; the
message is a pointer, never a second report copy.$c$;

drop trigger if exists trg_notify_expedition_result on public.expedition_results;
create trigger trg_notify_expedition_result
    after insert on public.expedition_results
    for each row
    execute function public.notify_expedition_result();

-- --------------------------------------------------------------------------- 6) COLONISATION event
create or replace function public.notify_colony_established()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    if new.player_id is null or coalesce(new.is_homeworld, false) then
        return new;
    end if;

    begin
        perform public.create_player_message(
            new.player_id, null, 'Colony established',
            format('Your colony ship founded %s at %s.', new.name,
                   public.format_coordinates(new.galaxy, new.system, new.position)),
            'colony:' || new.id::text);
    exception when others then
        raise warning 'MESSAGE_PRODUCER_FAILED colony=% error=%', new.id, sqlerrm;
    end;

    return new;
end;
$function$;

comment on function public.notify_colony_established() is
$c$AFTER INSERT trigger on planets: notifies the owner that a colony was founded. Homeworlds and planets without an
owner produce nothing. A failed colonisation produces no planet, so the failure signal is the "Fleet returning"
message the fleet trigger already emits.$c$;

drop trigger if exists trg_notify_colony_established on public.planets;
create trigger trg_notify_colony_established
    after insert on public.planets
    for each row
    execute function public.notify_colony_established();

-- --------------------------------------------------------------------------- 7) ACL
revoke all on function public.create_player_message(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.create_player_message(uuid, uuid, text, text, text) to service_role;

revoke all on function public.format_coordinates(integer, integer, integer) from public, anon, authenticated;
grant execute on function public.format_coordinates(integer, integer, integer) to service_role;

revoke all on function public.notify_fleet_status_change() from public, anon, authenticated;
revoke all on function public.notify_combat_participant() from public, anon, authenticated;
revoke all on function public.notify_expedition_result() from public, anon, authenticated;
revoke all on function public.notify_colony_established() from public, anon, authenticated;

commit;
