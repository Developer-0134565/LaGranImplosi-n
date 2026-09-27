-- OWNER-SCOPED READ CONTRACTS — espionage reports and player messages (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Gap closed: `espionage_reports` and `player_messages` both refuse direct API access
-- (`deny_direct_api_access`) and NO function returned their rows, so a browser could never display an
-- espionage report — the mission's data existed but was unreachable. This migration adds the read contracts
-- only; it does not create producers (which events become a message is a product decision, see the gap notes).
--
-- Ownership is never taken from the client: every contract derives the caller's players from
-- `auth.uid()` → `players.user_id` and filters by them. `p_limit` is clamped to 1..200.
--
-- `player_messages` keeps the shape it already had (sender_player_id nullable, recipient, subject, body,
-- read_at, created_at): the read contract exposes the recipient's own inbox and a mark-as-read transition that
-- is idempotent (`read_at` is written once). No new message status, no chat, no alliance/buddy/notes surface.

create or replace function public.get_player_espionage_reports(p_limit integer default 50)
returns table(
    out_report_id uuid,
    out_player_id uuid,
    out_fleet_id uuid,
    out_target_planet_id uuid,
    out_target_name text,
    out_galaxy integer,
    out_system integer,
    out_position integer,
    out_espionage_level integer,
    out_target_espionage_level integer,
    out_metal numeric,
    out_crystal numeric,
    out_deuterium numeric,
    out_energy numeric,
    out_fleet jsonb,
    out_defenses jsonb,
    out_created_at timestamp with time zone
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select er.id,
           er.player_id,
           er.fleet_id,
           er.target_planet_id,
           p.name,
           p.galaxy,
           p.system,
           p.position,
           er.espionage_level,
           er.target_espionage_level,
           er.metal,
           er.crystal,
           er.deuterium,
           er.energy,
           er.fleet,
           er.defenses,
           er.created_at
    from public.espionage_reports er
    left join public.planets p on p.id = er.target_planet_id
    where er.player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())
    order by er.created_at desc, er.id
    limit greatest(1, least(coalesce(p_limit, 50), 200));
$function$;

comment on function public.get_player_espionage_reports(integer) is
$c$Client read contract for the caller's own espionage reports (a report belongs to the ATTACKER: player_id is the
fleet owner). Rows are selected strictly through auth.uid() → players.user_id; the caller cannot ask for another
player's reports, and no parameter selects a player or a planet. Exposes what the report already stores (target
coordinates and name, both espionage levels, resources, fleet, defences). Level gating of the contents is NOT
applied here: that rule is not verified (documented gap in README_ESPIONAGE_ENGINE.md). Limit clamped to 1..200.$c$;

create or replace function public.get_player_messages(p_limit integer default 50, p_unread_only boolean default false)
returns table(
    out_message_id uuid,
    out_sender_player_id uuid,
    out_sender_username text,
    out_subject text,
    out_body text,
    out_read_at timestamp with time zone,
    out_created_at timestamp with time zone,
    out_is_read boolean
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select pm.id,
           pm.sender_player_id,
           sp.username,
           pm.subject,
           pm.body,
           pm.read_at,
           pm.created_at,
           (pm.read_at is not null)
    from public.player_messages pm
    left join public.players sp on sp.id = pm.sender_player_id
    where pm.recipient_player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())
      and (coalesce(p_unread_only, false) = false or pm.read_at is null)
    order by pm.created_at desc, pm.id
    limit greatest(1, least(coalesce(p_limit, 50), 200));
$function$;

comment on function public.get_player_messages(integer, boolean) is
$c$Client read contract for the caller's OWN inbox: recipient_player_id is matched against the players owned by
auth.uid(), so no parameter can select another player's mail and no sender identity is trusted. Returns the
sender username, subject, body, read state and timestamps; `p_unread_only` filters unread rows; limit clamped to
1..200. There are still NO producers (which gameplay events become messages is a product decision) — this contract
only makes the existing table reachable in an owner-scoped way.$c$;

create or replace function public.mark_message_read(p_message_id uuid)
returns table(
    out_message_id uuid,
    out_read_at timestamp with time zone,
    out_already_read boolean
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_row public.player_messages%rowtype;
    v_read_at timestamp with time zone;
begin
    v_auth_user := auth.uid();
    if v_auth_user is null then
        raise exception 'Authentication required';
    end if;

    select pm.* into v_row
    from public.player_messages pm
    where pm.id = p_message_id
      and pm.recipient_player_id in (select pl.id from public.players pl where pl.user_id = v_auth_user)
    for update;

    if not found then
        raise exception 'PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED: %', p_message_id;
    end if;

    /* Idempotent: a second call never moves read_at, it reports the stored value. */
    if v_row.read_at is not null then
        return query select v_row.id, v_row.read_at, true;
        return;
    end if;

    update public.player_messages pm
       set read_at = clock_timestamp()
     where pm.id = p_message_id
    returning pm.read_at into v_read_at;

    return query select v_row.id, v_read_at, false;
end;
$function$;

comment on function public.mark_message_read(uuid) is
$c$Marks one message of the caller's own inbox as read. Ownership: the row must be addressed to a player owned by
auth.uid() (recipient match + FOR UPDATE); a foreign or unknown message raises
PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED and writes nothing. Idempotent and replay-safe: read_at is written once and
a second call returns the stored timestamp with already_read = true.$c$;

revoke all on function public.get_player_espionage_reports(integer) from public;
revoke all on function public.get_player_espionage_reports(integer) from anon;
grant execute on function public.get_player_espionage_reports(integer) to authenticated;
grant execute on function public.get_player_espionage_reports(integer) to service_role;

revoke all on function public.get_player_messages(integer, boolean) from public;
revoke all on function public.get_player_messages(integer, boolean) from anon;
grant execute on function public.get_player_messages(integer, boolean) to authenticated;
grant execute on function public.get_player_messages(integer, boolean) to service_role;

revoke all on function public.mark_message_read(uuid) from public;
revoke all on function public.mark_message_read(uuid) from anon;
grant execute on function public.mark_message_read(uuid) to authenticated;
grant execute on function public.mark_message_read(uuid) to service_role;

