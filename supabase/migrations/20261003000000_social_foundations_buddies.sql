-- FRIENDS / BUDDIES — FOUNDATIONS (social relationship layer)
-- ----------------------------------------------------------------------------
-- NOT DEPLOYED BY THIS MISSION. This file is the LOCAL source of truth; it is
-- forward-only and must be applied with `apply_migration` in a later mission.
--
-- WHY THIS FILE EXISTS
--   LGI has NO social relationship layer at all (measured on LIVE 2026-10-02:
--   zero tables and zero functions matching buddy|friend|alliance|guild). The
--   certified ACS authorization (`planet_support_authorizations`) is
--   PLANET-scoped and deliberately says so: "planet existence is never
--   authorization". OGameX's ACS Defend instead authorizes on a SOCIAL
--   relationship (`AcsDefendMission::isMissionPossible`: buddy OR same
--   alliance). Those two models are different, and neither replaces the other,
--   so this file adds the missing social layer WITHOUT touching ACS_HOLD.
--
-- OGameX REFERENCE (lanedirt/OGameX @ 2649076, read verbatim 2026-10-02)
--   app/Models/BuddyRequest.php
--       columns : sender_user_id, receiver_user_id, status, message, viewed
--       status  : STATUS_PENDING = 0, STATUS_ACCEPTED = 1, STATUS_REJECTED = 2
--   app/Services/BuddyService.php
--       areBuddies() matches the pair in EITHER direction with status=ACCEPTED.
--       sendRequest() refuses sender === receiver.
--
-- MODEL DECISION — DIRECTIONAL ROW, SYMMETRIC MEANING
--   OGameX stores ONE row per request and makes `areBuddies` look at both
--   orientations. LGI adopts exactly that: a single row per unordered pair,
--   enforced by a UNIQUE index over (least, greatest), so two contradictory
--   rows for the same pair are impossible at the storage layer. The row keeps
--   requester/addressee so "who may accept" is unambiguous.
--
-- IDENTITY
--   Every RPC resolves the caller from auth.uid() through the canonical chain
--   `players.user_id = auth.uid()`. The client NEVER supplies "who am I"; the
--   only id it may pass is the COUNTERPART.
--
-- ACL
--   `player_buddies` is NOT granted to `authenticated`/`anon`, following the
--   certified `planet_support_authorizations` precedent: the tables are
--   reachable ONLY through SECURITY DEFINER RPCs, which makes the ownership
--   checks inside those RPCs the single authority.

begin;

-- ---------------------------------------------------------------- identity chain
-- Declared once so the social layer has one source of truth and cannot drift.
create or replace function public.current_player_id()
returns uuid
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
    select pl.id from public.players pl where pl.user_id = auth.uid();
$$;

comment on function public.current_player_id() is
    'Canonical caller identity for the social layer: auth.uid() -> players.id. NULL when there is no session or no player.';

-- ============================================================ TABLE: player_buddies
create table if not exists public.player_buddies (
    id                  uuid primary key default gen_random_uuid(),
    requester_player_id uuid not null references public.players(id) on delete cascade,
    addressee_player_id uuid not null references public.players(id) on delete cascade,
    status              text   not null default 'PENDING',
    message             text,
    responded_at        timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    -- OGameX: cannot send a buddy request to yourself.
    constraint player_buddies_no_self_check
        check (requester_player_id <> addressee_player_id),

    -- OGameX BuddyRequest status values as text, readable and never confused
    -- with a count.
    constraint player_buddies_status_check
        check (status in ('PENDING', 'ACCEPTED', 'REJECTED')),

    -- A decided request always carries its timestamp; a pending one never does.
    -- This makes a contradictory state unrepresentable.
    constraint player_buddies_response_consistency_check
        check ((status = 'PENDING' and responded_at is null)
            or (status <> 'PENDING' and responded_at is not null))
);

comment on table public.player_buddies is
    'Friends/Buddies. One row per UNORDERED player pair (player_buddies_pair_uniq). requester is the only party that may cancel; addressee the only one that may accept or reject. OGameX: app/Models/BuddyRequest.php, app/Services/BuddyService.php.';

-- One row per pair, in EITHER direction: duplicates are impossible in storage,
-- not merely avoided in application code.
create unique index if not exists player_buddies_pair_uniq
    on public.player_buddies (
        least(requester_player_id, addressee_player_id),
        greatest(requester_player_id, addressee_player_id)
    );

create index if not exists player_buddies_addressee_idx
    on public.player_buddies (addressee_player_id, status);
create index if not exists player_buddies_requester_idx
    on public.player_buddies (requester_player_id, status);

-- RLS on with NO policy: the table is unreachable from authenticated/anon
-- because no grant exists. RLS is the second lock, not the only one.
alter table public.player_buddies enable row level security;
revoke all on public.player_buddies from anon, authenticated;

-- ====================================================== RPC: send_buddy_request
create or replace function public.send_buddy_request(
    p_addressee_player_id uuid,
    p_message            text default null
)
returns table (out_id uuid, out_addressee_player_id uuid, out_status text)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_sender uuid;
    v_row    public.player_buddies%rowtype;
begin
    v_sender := public.current_player_id();

    if v_sender is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;
    if p_addressee_player_id is null then
        raise exception 'BUDDY_ADDRESSEE_REQUIRED';
    end if;
    -- OGameX BuddyService::sendRequest: "cannot send to self".
    if p_addressee_player_id = v_sender then
        raise exception 'BUDDY_SELF_NOT_ALLOWED: a buddy request requires a different player';
    end if;
    if not exists (select 1 from public.players pl where pl.id = p_addressee_player_id) then
        raise exception 'BUDDY_ADDRESSEE_NOT_FOUND';
    end if;
    if p_message is not null and length(p_message) > 500 then
        raise exception 'BUDDY_MESSAGE_TOO_LONG: at most 500 characters';
    end if;

    if exists (
        select 1 from public.player_buddies b
        where (b.requester_player_id = v_sender and b.addressee_player_id = p_addressee_player_id)
           or (b.requester_player_id = p_addressee_player_id and b.addressee_player_id = v_sender)
    ) then
        select * into v_row from public.player_buddies b
        where (b.requester_player_id = v_sender and b.addressee_player_id = p_addressee_player_id)
           or (b.requester_player_id = p_addressee_player_id and b.addressee_player_id = v_sender);

        -- Already friends: refuse rather than silently downgrade the relation.
        if v_row.status = 'ACCEPTED' then
            raise exception 'BUDDY_ALREADY_ESTABLISHED: you are already buddies';
        end if;

        -- REJECTED or stale PENDING: re-issue as a fresh request owned by the
        -- current sender. Reusing the row preserves the one-row-per-pair rule.
        update public.player_buddies b
           set requester_player_id = v_sender,
               addressee_player_id = p_addressee_player_id,
               status = 'PENDING',
               message = p_message,
               responded_at = null,
               updated_at = now()
         where b.id = v_row.id
        returning b.id, b.addressee_player_id, b.status into out_id, out_addressee_player_id, out_status;

        return next;
        return;
    end if;

    insert into public.player_buddies(requester_player_id, addressee_player_id, status, message)
    values (v_sender, p_addressee_player_id, 'PENDING', p_message)
    returning id, addressee_player_id, status into out_id, out_addressee_player_id, out_status;

    return next;
end;
$$;

comment on function public.send_buddy_request(uuid, text) is
    'Sends or re-issues a buddy request from the authenticated player to a counterpart. Refuses self, unknown players and duplicates. One row per unordered pair.';

-- ==================================================== RPC: respond_buddy_request
create or replace function public.respond_buddy_request(
    p_request_id uuid,
    p_accept     boolean
)
returns table (out_id uuid, out_status text)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me  uuid;
    v_row public.player_buddies%rowtype;
begin
    v_me := public.current_player_id();

    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;
    if p_request_id is null then
        raise exception 'BUDDY_REQUEST_ID_REQUIRED';
    end if;

    -- FOR UPDATE so two concurrent accepts cannot both observe PENDING.
    select * into v_row from public.player_buddies b where b.id = p_request_id for update;

    if not found then
        raise exception 'BUDDY_REQUEST_NOT_FOUND';
    end if;

    -- Ownership: ONLY the addressee may answer. The requester answering their
    -- own request is exactly the cross-player access this must refuse.
    if v_row.addressee_player_id <> v_me then
        raise exception 'BUDDY_REQUEST_NOT_ADDRESSED_TO_YOU: only the recipient may answer';
    end if;
    if v_row.status <> 'PENDING' then
        raise exception 'BUDDY_REQUEST_ALREADY_ANSWERED: status is %', v_row.status;
    end if;

    update public.player_buddies b
       set status = case when p_accept then 'ACCEPTED' else 'REJECTED' end,
           responded_at = now(),
           updated_at = now()
     where b.id = p_request_id
    returning b.id, b.status into out_id, out_status;

    return next;
end;
$$;

comment on function public.respond_buddy_request(uuid, boolean) is
    'Accepts or rejects a PENDING request. Only the addressee may call it; a non-existent or already-answered request is refused rather than silently created.';

-- ==================================================== RPC: cancel_buddy_request
create or replace function public.cancel_buddy_request(p_request_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me  uuid;
    v_row public.player_buddies%rowtype;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;

    select * into v_row from public.player_buddies b where b.id = p_request_id for update;
    if not found then
        raise exception 'BUDDY_REQUEST_NOT_FOUND';
    end if;

    -- Only the requester may withdraw, and only while it is still pending.
    if v_row.requester_player_id <> v_me then
        raise exception 'BUDDY_REQUEST_NOT_OWNED_BY_YOU: only the sender may cancel';
    end if;
    if v_row.status <> 'PENDING' then
        raise exception 'BUDDY_REQUEST_ALREADY_ANSWERED: status is %', v_row.status;
    end if;

    delete from public.player_buddies b where b.id = p_request_id;
    return true;
end;
$$;

comment on function public.cancel_buddy_request(uuid) is
    'Withdraws a PENDING request. Only its sender may cancel; an accepted relationship is removed with remove_buddy, not here.';

-- ============================================================ RPC: remove_buddy
create or replace function public.remove_buddy(p_buddy_player_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me uuid;
    v_id uuid;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;
    if p_buddy_player_id is null or p_buddy_player_id = v_me then
        raise exception 'BUDDY_SELF_NOT_ALLOWED';
    end if;

    select b.id into v_id
      from public.player_buddies b
     where ((b.requester_player_id = v_me and b.addressee_player_id = p_buddy_player_id)
         or (b.requester_player_id = p_buddy_player_id and b.addressee_player_id = v_me))
       and b.status = 'ACCEPTED'
     for update;

    if v_id is null then
        raise exception 'BUDDY_RELATION_NOT_FOUND: there is no established relationship with that player';
    end if;

    -- EITHER side may end the friendship (OGameX BuddyRemoved is symmetric);
    -- deleting the single row is precisely what makes it symmetric.
    delete from public.player_buddies b where b.id = v_id;
    return true;
end;
$$;

comment on function public.remove_buddy(uuid) is
    'Ends an ACCEPTED relationship. Either party may call it; the single relationship row is the source of truth and is removed outright.';

-- ============================================================ RPC: list_buddies
create or replace function public.list_buddies()
returns table (
    out_relation_id     uuid,
    out_buddy_player_id uuid,
    out_buddy_username  text,
    out_status          text,
    out_direction       text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    with me as (select public.current_player_id() as player_id)
    select b.id,
           case when b.requester_player_id = me.player_id
                then b.addressee_player_id else b.requester_player_id end as buddy_player_id,
           other.username,
           b.status,
           case when b.status <> 'PENDING' then 'ESTABLISHED'
                when b.addressee_player_id = me.player_id then 'INCOMING_PENDING'
                else 'OUTGOING_PENDING' end
      from public.player_buddies b
      join me on true
      join public.players other
        on other.id = case when b.requester_player_id = me.player_id
                           then b.addressee_player_id else b.requester_player_id end
     where b.requester_player_id = me.player_id
        or b.addressee_player_id = me.player_id
     order by b.status, lower(other.username);
$$;

comment on function public.list_buddies() is
    'Read contract: the caller''s own relationships with direction. Never exposes another player''s relationships and never accepts a player_id.';

-- ================================================== RPC: players_are_buddies
-- The social authorization primitive. Read-only and takes NO caller id: it
-- answers only "are THESE two players buddies", which is what a DEFEND dispatch
-- needs and what a client must never decide for itself.
create or replace function public.players_are_buddies(p_player_a uuid, p_player_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1
          from public.player_buddies b
         where b.status = 'ACCEPTED'
           and ((b.requester_player_id = p_player_a and b.addressee_player_id = p_player_b)
             or (b.requester_player_id = p_player_b and b.addressee_player_id = p_player_a))
    );
$$;

comment on function public.players_are_buddies(uuid, uuid) is
    'True when two players hold an ACCEPTED buddy relationship in either orientation (OGameX BuddyService::areBuddies). Symmetric by construction.';

-- ------------------------------------------------------------------------ ACL
grant execute on function public.current_player_id()                  to authenticated, service_role;
grant execute on function public.send_buddy_request(uuid, text)       to authenticated;
grant execute on function public.respond_buddy_request(uuid, boolean) to authenticated;
grant execute on function public.cancel_buddy_request(uuid)            to authenticated;
grant execute on function public.remove_buddy(uuid)                    to authenticated;
grant execute on function public.list_buddies()                        to authenticated;
grant execute on function public.players_are_buddies(uuid, uuid)       to authenticated, service_role;

-- anon must never reach any of it.
revoke execute on function public.current_player_id()                  from anon;
revoke execute on function public.send_buddy_request(uuid, text)       from anon;
revoke execute on function public.respond_buddy_request(uuid, boolean) from anon;
revoke execute on function public.cancel_buddy_request(uuid)            from anon;
revoke execute on function public.remove_buddy(uuid)                    from anon;
revoke execute on function public.list_buddies()                        from anon;
revoke execute on function public.players_are_buddies(uuid, uuid)       from anon;

commit;