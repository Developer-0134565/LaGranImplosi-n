-- MESSAGING ENGINE — producers for gameplay events (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- State before this migration: `player_messages` was reachable but EMPTY of producers. The read
-- contract (`get_player_messages`), `mark_message_read` and the ACL hardening already existed
-- (`20260926091605`, `20260926095835`), and the entity was explicitly documented as "0 producers".
-- Product decision of the GAMEPLAY COMPLETION SWEEP: EVERY relevant gameplay event must produce a
-- message, and Messages must be the player's central event inbox.
--
-- Design (no certified engine function is modified):
--   * `dedupe_key` + a partial unique index makes a producer REPLAY-SAFE: an identical event can be
--     produced twice without duplicating the row.
--   * `create_player_message(...)` is the single internal write path (SECURITY DEFINER, EXECUTE only
--     for postgres/service_role). The recipient is always an explicit player id resolved by the
--     producer from OWNERSHIP (fleet_movements.player_id, planets.player_id, combat participants);
--     no client parameter can select a recipient.
--   * Events are captured with TRIGGERS on the tables the engine already writes, so the certified
--     fleet worker, combat engine and expedition resolver stay byte-identical. Every trigger body is
--     wrapped in its own exception handler: a messaging failure can NEVER abort fleet resolution, a
--     combat settlement or an economy update (it only raises a WARNING).
--   * OGameX parity for the message SET (app/GameMessages @ 7c420bad): TransportArrived/Received,
--     ReturnOfFleet(WithResources), FleetDeployment, ColonyEstablished, DebrisFieldHarvest,
--     EspionageReport, DefenderEspionageDetected, BattleReport, Expedition* (outcome), MoonDestroyed.
--     The message is a NOTIFICATION that points at the event; the payload keeps living in its own
--     report table (espionage_reports / combat_battles / expedition_results) — no report is duplicated.
--
-- Certified by `supabase/tests/messaging_engine.sql`.
begin;
-- --------------------------------------------------------------------------- 1) replay-safe identity
alter table public.player_messages
    add column if not exists dedupe_key text;
comment on column public.player_messages.dedupe_key is
$c$Producer-side idempotency stamp (e.g. 'fleet_arrived:<fleet uuid>'). A partial unique index over
(recipient_player_id, dedupe_key) makes message production replay-safe: the same event produced twice inserts
once. NULL keys are unlimited (manual mail is not deduplicated). Not exposed to clients.$c$;
create unique index if not exists player_messages_recipient_dedupe_key_uq
    on public.player_messages(recipient_player_id, dedupe_key)
    where dedupe_key is not null;
-- --------------------------------------------------------------------------- 2) single internal producer
create or replace function public.create_player_message(
    p_recipient_player_id uuid,
    p_sender_player_id uuid,
    p_subject text,
    p_body text,
    p_dedupe_key text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_message_id uuid;
begin
    if p_recipient_player_id is null then
        raise exception 'MESSAGE_RECIPIENT_REQUIRED';
    end if;
    if p_subject is null or length(btrim(p_subject)) = 0 then
        raise exception 'MESSAGE_SUBJECT_REQUIRED';
    end if;
    if not exists (select 1 from public.players pl where pl.id = p_recipient_player_id) then
        raise exception 'MESSAGE_RECIPIENT_UNKNOWN: %', p_recipient_player_id;
    end if;
    insert into public.player_messages (recipient_player_id, sender_player_id, subject, body, dedupe_key)
    values (p_recipient_player_id, p_sender_player_id, left(btrim(p_subject), 200), p_body, p_dedupe_key)
    on conflict (recipient_player_id, dedupe_key) where dedupe_key is not null
    do nothing
    returning id into v_message_id;
    if v_message_id is null then
        select pm.id into v_message_id
        from public.player_messages pm
        where pm.recipient_player_id = p_recipient_player_id
          and pm.dedupe_key = p_dedupe_key;
    end if;
    return v_message_id;
end;
$function$;
comment on function public.create_player_message(uuid, uuid, text, text, text) is
$c$The single internal producer of player messages. SECURITY DEFINER; EXECUTE only for postgres/service_role (never
anon/authenticated). The recipient is an explicit, ownership-resolved player id supplied by an internal producer
(fleet/planet/combat ownership), never a client parameter. Replay-safe: with a non-null p_dedupe_key a repeated
call for the same (recipient, key) returns the stored message instead of inserting a second one.$c$;
-- --------------------------------------------------------------------------- 3) FLEET lifecycle events
-- Fleet arrival and fleet return are the two events every mission shares. They are produced from the
-- fleet row itself (ownership = fleet_movements.player_id), so the worker, the resolvers and the
-- dispatch RPCs are untouched.
create or replace function public.notify_fleet_status_change()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_subject text;
    v_body text;
    v_key text;
begin
    if new.status is not distinct from old.status then
        return new;
    end if;
    if new.player_id is null then
        return new;
    end if;
    if new.status = 'ARRIVED' then
        v_subject := 'Fleet arrived';
        v_key := 'fleet_arrived:' || new.id::text;
        v_body := format('Your %s fleet reached %s.', new.mission_type,
                         public.format_coordinates(new.destination_galaxy, new.destination_system,
                                                   new.destination_position));
    elsif new.status = 'HOLDING' then
        v_subject := 'Fleet holding';
        v_key := 'fleet_holding:' || new.id::text;
        v_body := format('Your %s fleet is holding at %s until %s.', new.mission_type,
                         public.format_coordinates(new.destination_galaxy, new.destination_system,
                                                   new.destination_position),
                         coalesce(new.holding_until::text, 'the end of its window'));
    elsif new.status = 'RETURNING' then
        if new.mission_type = 'RECYCLE' then
            v_subject := 'Debris field harvested';
            v_body := format('Recyclers left %s carrying %s metal and %s crystal. Return due %s.',
                             public.format_coordinates(new.destination_galaxy, new.destination_system,
                                                       new.destination_position),
                             coalesce(new.metal, 0), coalesce(new.crystal, 0),
                             coalesce(new.returns_at::text, 'soon'));
        else
            v_subject := 'Fleet returning';
            v_body := format('Your %s fleet (%s) is returning home. Arrival at the origin planet: %s.',
                             new.mission_type,
                             public.format_coordinates(new.destination_galaxy, new.destination_system,
                                                       new.destination_position),
                             coalesce(new.returns_at::text, 'soon'));
        end if;
        v_key := 'fleet_returning:' || new.id::text;
    elsif new.status = 'COMPLETED' then
        v_subject := 'Fleet returned';
        v_key := 'fleet_returned:' || new.id::text;
        v_body := format('Your %s fleet is back at its origin planet.', new.mission_type);
    else
        return new;
    end if;
    begin
        perform public.create_player_message(new.player_id, null, v_subject, v_body, v_key);
    exception when others then
        raise warning 'MESSAGE_PRODUCER_FAILED fleet=% status=% error=%', new.id, new.status, sqlerrm;
    end;
    return new;
end;
$function$;
comment on function public.notify_fleet_status_change() is
$c$AFTER UPDATE OF status trigger on fleet_movements: produces Fleet arrived / holding / returning / returned (and the
recycle-specific harvest body) to the fleet OWNER. Replay-safe through the message dedupe key. The body is wrapped in
its own exception handler so a messaging failure can never abort fleet resolution.$c$;
drop trigger if exists trg_notify_fleet_status_change on public.fleet_movements;
create trigger trg_notify_fleet_status_change
    after update of status on public.fleet_movements
    for each row
    execute function public.notify_fleet_status_change();
-- message rendering helper: human-readable coordinate string
create or replace function public.format_coordinates(p_galaxy integer, p_system integer, p_position integer)
returns text
language sql
immutable
as $function$
    select format('[%s:%s:%s]', p_galaxy, p_system, p_position);
$function$;
comment on function public.format_coordinates(integer, integer, integer) is
$c$Read-only formatting helper used by message producers: '[galaxy:system:position]'.$c$;
commit;