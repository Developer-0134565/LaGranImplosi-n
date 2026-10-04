-- ALLIANCES / GUILDS — FOUNDATIONS (membership, ranks, applications)
-- ----------------------------------------------------------------------------
-- NOT DEPLOYED BY THIS MISSION. Local source of truth; forward-only.
--
-- WHY A SEPARATE MODEL FROM BUDDIES
--   OGameX treats them as different things and so does LGI. `areBuddies()` is a
--   pairwise ACCEPTED request; `arePlayersInSameAlliance()` is "both users carry
--   the same non-null alliance_id". Being buddies does NOT put you in an
--   alliance, and being in an alliance does not make you buddies. Folding them
--   into one table would invent a mechanic neither reference supports, so they
--   stay separate and DEFEND simply accepts EITHER as its authorization.
--
-- OGameX REFERENCE (lanedirt/OGameX @ 2649076, read verbatim 2026-10-02)
--   app/Models/Alliance.php            alliance_tag, alliance_name,
--                                       founder_user_id, internal/external/
--                                       application_text, logo_url, homepage_url,
--                                       is_open, founder_rank_name, newcomer_rank_name
--   app/Models/AllianceMember.php      alliance_id, user_id, rank_id, joined_at
--                                       isFounder() -> alliance.founder_user_id === user_id
--                                       hasPermission() -> FOUNDER HAS ALL, else rank list
--   app/Models/AllianceRank.php        alliance_id, rank_name, permissions[], sort_order
--                                       PERMISSION_SEE_APPLICATIONS, _EDIT_APPLICATIONS,
--                                       _SEE_MEMBERS, _KICK_USER,
--                                       _SEE_MEMBER_ONLINE_STATUS, _SEND_CIRCULAR_MSG,
--                                       _DELETE_ALLY, _MANAGE_ALLY, _RIGHT_HAND,
--                                       _MANAGE_CLASSES
--   app/Models/AllianceApplication.php alliance_id, user_id, application_message,
--                                       status (0 pending/1 accepted/2 rejected), viewed
--   app/Services/AllianceService.php    createAlliance(): tag 3-8, name 3-30, tag unique,
--                                       founder inserted as member with rank_id NULL
--                                       ("founder has all permissions").
--                                       leaveAlliance() refuses when the leaver is the
--                                       founder (the alliance must be deleted instead).
--
-- EXPLICITLY NOT BUILT HERE (out of scope, not verified behaviour)
--   alliance wars, economic bonuses, social rankings, advanced diplomacy,
--   circular messaging, alliance depot / terraformer, highscore tables.
--   AllianceHighscore and sendCircularMsg exist in OGameX but are out of scope;
--   nothing here stubs them.
--
-- IDENTITY
--   Same rule as the buddies layer: the caller comes from auth.uid() via
--   `current_player_id()`. No RPC accepts a caller id.

begin;

-- ========================================================= TABLE: player_alliances
create table if not exists public.player_alliances (
    id                uuid primary key default gen_random_uuid(),
    -- OGameX alliance_tag: the public short name, 3-8 chars.
    alliance_tag      text   not null,
    alliance_name     text   not null,
    -- OGameX founder_user_id, adapted to LGI: a PLAYER id, because every LGI
    -- social relation is player-scoped.
    founder_player_id uuid   not null references public.players(id) on delete restrict,
    -- OGameX is_open: whether the alliance accepts applications. An application
    -- gate only; it grants nothing by itself.
    is_open           boolean not null default true,
    internal_text     text,
    external_text     text,
    application_text  text,
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),

    -- OGameX createAlliance validations, enforced in storage so no other writer
    -- can produce an alliance the contract would refuse.
    constraint player_alliances_tag_format_check
        check (alliance_tag ~ '^[A-Za-z0-9]{3,8}$'),
    constraint player_alliances_name_length_check
        check (length(alliance_name) between 3 and 30)
);

comment on table public.player_alliances is
    'Alliances/Guilds identity. founder_player_id is the founder (OGameX founder_user_id, adapted to LGI player identity). Membership in player_alliance_members; ranks in player_alliance_ranks. OGameX: app/Models/Alliance.php.';

-- Tag is the public identifier -> globally unique, case-insensitive, so "LGI"
-- and "lgi" cannot both exist.
create unique index if not exists player_alliances_tag_uniq
    on public.player_alliances (upper(alliance_tag));

-- ==================================================== TABLE: player_alliance_ranks
create table if not exists public.player_alliance_ranks (
    id          uuid primary key default gen_random_uuid(),
    alliance_id uuid not null references public.player_alliances(id) on delete cascade,
    rank_name   text not null,
    -- OGameX permissions is a string array. text[] plus a CHECK that every
    -- element is a KNOWN OGameX permission, so a typo becomes a refused write
    -- instead of a privilege that silently never matches.
    permissions text[] not null default '{}',
    sort_order  integer not null default 0,
    created_at  timestamptz not null default now(),

    constraint player_alliance_ranks_name_uniq unique (alliance_id, rank_name),
    constraint player_alliance_ranks_known_permissions_check check (
        permissions <@ array[
            'see_applications','edit_applications','see_members','kick_user',
            'see_member_online_status','send_circular_msg','delete_ally',
            'manage_ally','right_hand','manage_classes'
        ]::text[]
    )
);

comment on table public.player_alliance_ranks is
    'Per-alliance ranks and their permission set. Vocabulary is exactly the OGameX AllianceRank::PERMISSION_* constants (app/Models/AllianceRank.php); an unknown permission is refused by CHECK.';

-- =================================================== TABLE: player_alliance_members
create table if not exists public.player_alliance_members (
    id          uuid primary key default gen_random_uuid(),
    alliance_id uuid not null references public.player_alliances(id) on delete cascade,
    player_id   uuid not null references public.players(id) on delete cascade,
    -- OGameX AllianceMember.rank_id is NULLABLE and the founder's row carries
    -- NULL: the founder's authority comes from founder_player_id, not a rank.
    rank_id     uuid references public.player_alliance_ranks(id) on delete set null,
    joined_at   timestamptz not null default now(),
    created_at  timestamptz not null default now(),

    -- OGameX users.alliance_id is a single scalar: ONE alliance per player.
    constraint player_alliance_members_player_uniq unique (player_id)
);

comment on table public.player_alliance_members is
    'Alliance membership: ONE alliance per player (OGameX users.alliance_id). A member with rank_id NULL and no founder row has no administrative permission at all.';

-- A rank must belong to the SAME alliance as the member holding it. Composite
-- FK, so a cross-alliance rank grant is unrepresentable rather than merely
-- discouraged.
create unique index if not exists player_alliance_ranks_alliance_id_id_uniq
    on public.player_alliance_ranks (alliance_id, id);
alter table public.player_alliance_members
    add constraint player_alliance_members_rank_same_alliance_fk
    foreign key (alliance_id, rank_id)
    references public.player_alliance_ranks (alliance_id, id);

create index if not exists player_alliance_members_alliance_idx
    on public.player_alliance_members (alliance_id);

-- ================================================ TABLE: player_alliance_applications
create table if not exists public.player_alliance_applications (
    id                  uuid primary key default gen_random_uuid(),
    alliance_id         uuid not null references public.player_alliances(id) on delete cascade,
    player_id           uuid not null references public.players(id) on delete cascade,
    application_message text,
    -- OGameX AllianceApplication status 0/1/2, as text like the buddy layer.
    status              text   not null default 'PENDING',
    viewed              boolean not null default false,
    responded_at        timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    constraint player_alliance_applications_status_check
        check (status in ('PENDING', 'ACCEPTED', 'REJECTED')),
    constraint player_alliance_applications_response_consistency_check
        check ((status = 'PENDING' and responded_at is null)
            or (status <> 'PENDING' and responded_at is not null))
);

-- The founder must not be able to apply to their own alliance.
-- WHY A TRIGGER AND NOT A CHECK: PostgreSQL forbids subqueries inside a CHECK
-- constraint ("cannot use subquery in check constraint"), and the rule needs to
-- compare against player_alliances.founder_player_id. A BEFORE INSERT/UPDATE
-- trigger enforces the same rule and, unlike application code, holds for every
-- writer including future ones.
create or replace function public.player_alliance_applications_no_self_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if exists (
        select 1 from public.player_alliances a
         where a.id = new.alliance_id
           and a.founder_player_id = new.player_id
    ) then
        raise exception 'ALLIANCE_FOUNDER_CANNOT_APPLY: you already lead this alliance';
    end if;
    return new;
end;
$$;

drop trigger if exists player_alliance_applications_no_self_trg on public.player_alliance_applications;
create trigger player_alliance_applications_no_self_trg
    before insert or update on public.player_alliance_applications
    for each row execute function public.player_alliance_applications_no_self_guard();

comment on function public.player_alliance_applications_no_self_guard() is
    'Enforces that an alliance founder cannot hold a join application for their own alliance. A trigger, not a CHECK, because CHECK cannot contain a subquery.';

comment on table public.player_alliance_applications is
    'Join requests. OGameX app/Models/AllianceApplication.php. One application row per player+alliance; a decided one may be re-applied by reusing the row.';

create unique index if not exists player_alliance_applications_pair_uniq
    on public.player_alliance_applications (alliance_id, player_id);
create index if not exists player_alliance_applications_alliance_status_idx
    on public.player_alliance_applications (alliance_id, status);

-- ================================================ helper: alliance_member_permission
-- OGameX AllianceMember::hasPermission(): "Founder has all permissions",
-- otherwise the rank's list. Adapted to LGI player identity. This is the ONE
-- place the permission rule lives, so no RPC can re-implement it differently.
create or replace function public.alliance_member_permission(
    p_player_id uuid,
    p_alliance_id uuid,
    p_permission text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1
          from public.player_alliances a
         where a.id = p_alliance_id
           -- OGameX: the founder implicitly holds every permission.
           and (a.founder_player_id = p_player_id
                or exists (
                    select 1
                      from public.player_alliance_members m
                      join public.player_alliance_ranks r on r.id = m.rank_id
                     where m.player_id = p_player_id
                       and m.alliance_id = p_alliance_id
                       and p_permission = any (r.permissions)
                ))
    );
$$;

comment on function public.alliance_member_permission(uuid, uuid, text) is
    'True when the player is the alliance founder (OGameX: founder holds ALL permissions) or holds a rank carrying the permission. Single source of truth for alliance authorization.';

-- ------------------------------------------------- ACL: RPC-only, never direct
alter table public.player_alliances            enable row level security;
alter table public.player_alliance_ranks       enable row level security;
alter table public.player_alliance_members     enable row level security;
alter table public.player_alliance_applications enable row level security;

revoke all on public.player_alliances            from anon, authenticated;
revoke all on public.player_alliance_ranks       from anon, authenticated;
revoke all on public.player_alliance_members     from anon, authenticated;
revoke all on public.player_alliance_applications from anon, authenticated;

grant execute on function public.alliance_member_permission(uuid, uuid, text) to authenticated, service_role;
revoke  execute on function public.alliance_member_permission(uuid, uuid, text) from anon;

-- ================================================= RPC: create_alliance
create or replace function public.create_alliance(p_tag text, p_name text)
returns table (out_alliance_id uuid, out_alliance_tag text, out_alliance_name text)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me       uuid;
    v_alliance uuid;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;

    if p_tag is null or p_tag !~ '^[A-Za-z0-9]{3,8}$' then
        raise exception 'ALLIANCE_TAG_INVALID: 3 to 8 alphanumeric characters are required';
    end if;
    if p_name is null or length(btrim(p_name)) not between 3 and 30 then
        raise exception 'ALLIANCE_NAME_INVALID: 3 to 30 characters are required';
    end if;

    -- OGameX createAlliance: "User is already in an alliance".
    if exists (select 1 from public.player_alliance_members m where m.player_id = v_me) then
        raise exception 'ALLIANCE_ALREADY_MEMBER: leave your current alliance first';
    end if;

    -- Tag uniqueness is a unique INDEX, so the race is decided by the database
    -- rather than by a check-then-insert window.
    insert into public.player_alliances(alliance_tag, alliance_name, founder_player_id)
    values (p_tag, btrim(p_name), v_me)
    returning id, alliance_tag, alliance_name into out_alliance_id, out_alliance_tag, out_alliance_name;

    -- OGameX: the founder is inserted as a member with rank_id NULL, because
    -- the founder's authority is founder_player_id, not a rank.
    insert into public.player_alliance_members(alliance_id, player_id, rank_id)
    values (out_alliance_id, v_me, null);

    return next;
exception
    when unique_violation then
        raise exception 'ALLIANCE_TAG_TAKEN: that tag is already in use';
end;
$$;

comment on function public.create_alliance(text, text) is
    'Creates an alliance with the authenticated player as founder, and inserts the founder membership row with rank_id NULL (OGameX AllianceService::createAlliance). One alliance per player.';

-- ==================================================== RPC: apply_to_alliance
create or replace function public.apply_to_alliance(
    p_alliance_id uuid,
    p_message     text default null
)
returns table (out_application_id uuid, out_status text)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me        uuid;
    v_open      boolean;
    v_founder   uuid;
    v_existing  public.player_alliance_applications%rowtype;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;
    if p_alliance_id is null then
        raise exception 'ALLIANCE_ID_REQUIRED';
    end if;
    if p_message is not null and length(p_message) > 500 then
        raise exception 'ALLIANCE_MESSAGE_TOO_LONG: at most 500 characters';
    end if;

    select a.is_open, a.founder_player_id into v_open, v_founder
      from public.player_alliances a where a.id = p_alliance_id;

    if not found then
        raise exception 'ALLIANCE_NOT_FOUND';
    end if;
    -- OGameX isOpen() gates applications. A closed alliance refuses them.
    if not v_open then
        raise exception 'ALLIANCE_NOT_ACCEPTING_APPLICATIONS';
    end if;
    if v_founder = v_me then
        raise exception 'ALLIANCE_FOUNDER_CANNOT_APPLY: you already lead this alliance';
    end if;

    -- One alliance per player (OGameX users.alliance_id is a single scalar).
    if exists (select 1 from public.player_alliance_members m where m.player_id = v_me) then
        raise exception 'ALLIANCE_ALREADY_MEMBER: leave your current alliance first';
    end if;

    select * into v_existing from public.player_alliance_applications a
     where a.alliance_id = p_alliance_id and a.player_id = v_me for update;

    if v_existing.id is not null then
        if v_existing.status = 'PENDING' then
            raise exception 'ALLIANCE_APPLICATION_ALREADY_PENDING: you already applied to this alliance';
        end if;
        if v_existing.status = 'ACCEPTED' then
            raise exception 'ALLIANCE_APPLICATION_ALREADY_ACCEPTED';
        end if;
        -- Rejected: re-issue by reusing the row (one row per pair).
        update public.player_alliance_applications a
           set status = 'PENDING', application_message = p_message,
               viewed = false, responded_at = null, updated_at = now()
         where a.id = v_existing.id
        returning a.id, a.status into out_application_id, out_status;
        return next;
    end if;

    insert into public.player_alliance_applications(alliance_id, player_id, application_message, status)
    values (p_alliance_id, v_me, p_message, 'PENDING')
    returning id, status into out_application_id, out_status;

    return next;
end;
$$;

comment on function public.apply_to_alliance(uuid, text) is
    'Submits a join request. Requires an OPEN alliance, a caller without an alliance, and a caller who is not the founder (OGameX AllianceService apply flow).';

-- ============================================ RPC: respond_alliance_application
create or replace function public.respond_alliance_application(
    p_application_id uuid,
    p_accept        boolean
)
returns table (out_status text, out_member_player_id uuid)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me  uuid;
    v_app public.player_alliance_applications%rowtype;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;
    if p_application_id is null then
        raise exception 'ALLIANCE_APPLICATION_ID_REQUIRED';
    end if;

    select * into v_app from public.player_alliance_applications a
     where a.id = p_application_id for update;

    if not found then
        raise exception 'ALLIANCE_APPLICATION_NOT_FOUND';
    end if;

    -- OGameX: only members holding PERMISSION_EDIT_APPLICATIONS may act on an
    -- application; the founder holds every permission by definition.
    if not public.alliance_member_permission(v_me, v_app.alliance_id, 'edit_applications') then
        raise exception 'ALLIANCE_PERMISSION_DENIED: edit_applications is required';
    end if;
    if v_app.status <> 'PENDING' then
        raise exception 'ALLIANCE_APPLICATION_ALREADY_ANSWERED: status is %', v_app.status;
    end if;

    if p_accept then
        -- A player who joined another alliance in the meantime must not be
        -- silently moved; re-check under the same transaction.
        if exists (select 1 from public.player_alliance_members m where m.player_id = v_app.player_id) then
            raise exception 'ALLIANCE_APPLICANT_ALREADY_MEMBER';
        end if;

        update public.player_alliance_applications a
           set status = 'ACCEPTED', viewed = true, responded_at = now(), updated_at = now()
         where a.id = p_application_id
        returning a.status into out_status;

        insert into public.player_alliance_members(alliance_id, player_id, rank_id)
        values (v_app.alliance_id, v_app.player_id, null);
    else
        update public.player_alliance_applications a
           set status = 'REJECTED', viewed = true, responded_at = now(), updated_at = now()
         where a.id = p_application_id
        returning a.status into out_status;
    end if;

    out_member_player_id := v_app.player_id;
    return next;
end;
$$;

comment on function public.respond_alliance_application(uuid, boolean) is
    'Accepts or rejects a join request. Requires the edit_applications permission (OGameX AllianceRank::PERMISSION_EDIT_APPLICATIONS; the founder holds all). Acceptance atomically creates the membership row.';

-- ================================================= RPC: leave_alliance
create or replace function public.leave_alliance()
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me       uuid;
    v_alliance uuid;
    v_founder  uuid;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;

    select m.alliance_id, a.founder_player_id into v_alliance, v_founder
      from public.player_alliance_members m
      join public.player_alliances a on a.id = m.alliance_id
     where m.player_id = v_me
     for update of m;

    if v_alliance is null then
        raise exception 'ALLIANCE_MEMBERSHIP_NOT_FOUND: you are not in an alliance';
    end if;

    -- OGameX leaveAlliance() refuses when the leaver is the founder: the
    -- alliance must be dissolved, not orphaned.
    if v_founder = v_me then
        raise exception 'ALLIANCE_FOUNDER_CANNOT_LEAVE: dissolve the alliance instead';
    end if;

    delete from public.player_alliance_members m
     where m.player_id = v_me and m.alliance_id = v_alliance;
    return true;
end;
$$;

comment on function public.leave_alliance() is
    'Leaves the current alliance. The founder cannot leave (OGameX): an alliance must be dissolved explicitly.';

-- ================================================= RPC: dissolve_alliance
create or replace function public.dissolve_alliance()
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me       uuid;
    v_alliance uuid;
    v_members  integer;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;

    select a.id into v_alliance
      from public.player_alliances a
     where a.founder_player_id = v_me
     for update;

    if v_alliance is null then
        raise exception 'ALLIANCE_NOT_FOUND_OR_NOT_FOUNDER: only the founder may dissolve an alliance';
    end if;

    -- Memberships and applications cascade; ranks cascade from the alliance.
    delete from public.player_alliances a where a.id = v_alliance;

    select count(*) into v_members from public.player_alliance_members m
     where m.alliance_id = v_alliance;
    if v_members > 0 then
        raise exception 'ALLIANCE_DISSOLVE_INCOMPLETE: % membership row(s) survived', v_members;
    end if;
    return true;
end;
$$;

comment on function public.dissolve_alliance() is
    'Dissolves an alliance. Founder-only (OGameX delete alliance). Cascades memberships, ranks and applications, and re-checks that nothing survived.';

-- ============================================= RPC: create_alliance_rank
create or replace function public.create_alliance_rank(
    p_rank_name   text,
    p_permissions text[] default '{}',
    p_sort_order  integer default 0
)
returns table (out_rank_id uuid, out_rank_name text, out_permissions text[])
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me       uuid;
    v_alliance uuid;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;
    if p_rank_name is null or length(btrim(p_rank_name)) not between 1 and 40 then
        raise exception 'ALLIANCE_RANK_NAME_INVALID: 1 to 40 characters are required';
    end if;

    select m.alliance_id into v_alliance
      from public.player_alliance_members m where m.player_id = v_me;

    if v_alliance is null then
        raise exception 'ALLIANCE_MEMBERSHIP_NOT_FOUND: you are not in an alliance';
    end if;

    -- OGameX: rank management is PERMISSION_MANAGE_CLASSES; founder holds all.
    if not public.alliance_member_permission(v_me, v_alliance, 'manage_classes') then
        raise exception 'ALLIANCE_PERMISSION_DENIED: manage_classes is required';
    end if;

    insert into public.player_alliance_ranks(alliance_id, rank_name, permissions, sort_order)
    values (v_alliance, btrim(p_rank_name), coalesce(p_permissions, '{}'), coalesce(p_sort_order, 0))
    returning id, rank_name, permissions into out_rank_id, out_rank_name, out_permissions;

    return next;
exception
    when check_violation then
        raise exception 'ALLIANCE_PERMISSION_UNKNOWN: every permission must be an OGameX AllianceRank constant';
    when unique_violation then
        raise exception 'ALLIANCE_RANK_NAME_TAKEN';
end;
$$;

comment on function public.create_alliance_rank(text, text[], integer) is
    'Creates a rank with an OGameX permission set. Requires manage_classes (OGameX PERMISSION_MANAGE_CLASSES); the founder holds all permissions.';

-- ================================= RPC: set_alliance_member_rank
create or replace function public.set_alliance_member_rank(p_player_id uuid, p_rank_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
    v_me             uuid;
    v_alliance       uuid;
    v_target_founder boolean;
begin
    v_me := public.current_player_id();
    if v_me is null then
        raise exception 'AUTHENTICATION_REQUIRED: a signed-in player is required';
    end if;

    select m.alliance_id into v_alliance from public.player_alliance_members m
     where m.player_id = v_me;

    if v_alliance is null then
        raise exception 'ALLIANCE_MEMBERSHIP_NOT_FOUND: you are not in an alliance';
    end if;
    if not public.alliance_member_permission(v_me, v_alliance, 'manage_classes') then
        raise exception 'ALLIANCE_PERMISSION_DENIED: manage_classes is required';
    end if;

    if not exists (select 1 from public.player_alliance_members m
                    where m.player_id = p_player_id and m.alliance_id = v_alliance) then
        raise exception 'ALLIANCE_TARGET_NOT_MEMBER: that player is not in your alliance';
    end if;

    select a.founder_player_id = p_player_id into v_target_founder
      from public.player_alliances a where a.id = v_alliance;

    -- The founder's authority comes from founder_player_id. Re-ranking the
    -- founder would be a no-op or a privilege escalation, so refuse it.
    if v_target_founder then
        raise exception 'ALLIANCE_FOUNDER_RANK_IS_FIXED: the founder''s authority is not a rank';
    end if;

    if p_rank_id is not null and not exists (
        select 1 from public.player_alliance_ranks r
         where r.id = p_rank_id and r.alliance_id = v_alliance
    ) then
        raise exception 'ALLIANCE_RANK_NOT_FOUND_IN_ALLIANCE';
    end if;

    update public.player_alliance_members m set rank_id = p_rank_id
     where m.player_id = p_player_id and m.alliance_id = v_alliance;
    return true;
end;
$$;

comment on function public.set_alliance_member_rank(uuid, uuid) is
    'Assigns or clears a rank for a member of the caller''s alliance. Requires manage_classes. The founder''s rank is fixed and cannot be set.';

-- =============================================== RPC: list_alliance_members
create or replace function public.list_alliance_members(p_alliance_id uuid)
returns table (
    out_player_id   uuid,
    out_username    text,
    out_rank_id     uuid,
    out_rank_name   text,
    out_is_founder  boolean,
    out_permissions text[]
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    -- OGameX PERMISSION_SEE_MEMBERS gates the roster; the founder passes by
    -- definition. Read-only and identity-scoped: a non-member sees nothing.
    select m.player_id, pl.username, m.rank_id, r.rank_name,
           (a.founder_player_id = m.player_id),
           coalesce(r.permissions, '{}')
      from public.player_alliances a
      join public.player_alliance_members m on m.alliance_id = a.id
      join public.players pl on pl.id = m.player_id
      left join public.player_alliance_ranks r on r.id = m.rank_id
     where a.id = p_alliance_id
       and public.alliance_member_permission(public.current_player_id(), a.id, 'see_members')
     order by (a.founder_player_id = m.player_id) desc, lower(pl.username);
$$;

comment on function public.list_alliance_members(uuid) is
    'Read contract: the alliance roster, gated by see_members (OGameX PERMISSION_SEE_MEMBERS; the founder holds all). Returns nothing for a non-member.';

-- ================================================== RPC: players_in_same_alliance
-- The alliance authorization primitive for DEFEND. Takes no caller id.
--
-- WHY THE FOUNDER IS CHECKED DIRECTLY AND NOT ONLY THROUGH THE MEMBER ROW
--   `create_alliance` always inserts the founder's membership row, so reading
--   only `player_alliance_members` would work today. It is nonetheless fragile:
--   the whole DEFEND authorization would silently stop recognising the founder
--   if that row were ever absent, with no error anywhere. Since
--   founder_player_id is unique per alliance, testing it directly cannot make
--   this return true by accident, and it removes the silent dependency.
create or replace function public.players_in_same_alliance(p_player_a uuid, p_player_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    -- Both players must resolve to the SAME alliance. A player "belongs" to an
    -- alliance either as its FOUNDER or through a membership row, so BOTH sides
    -- are tested that way. Reading only player_alliance_members would make the
    -- answer depend on a founder membership row existing, which is exactly the
    -- kind of silent dependency that breaks DEFEND authorization later.
    select exists (
        select 1
          from public.player_alliances a
         where (a.founder_player_id = p_player_a
                or exists (select 1 from public.player_alliance_members ma
                            where ma.alliance_id = a.id and ma.player_id = p_player_a))
           and (a.founder_player_id = p_player_b
                or exists (select 1 from public.player_alliance_members mb
                            where mb.alliance_id = a.id and mb.player_id = p_player_b))
    );
$$;

comment on function public.players_in_same_alliance(uuid, uuid) is
    'True when both players are members of the SAME alliance (OGameX arePlayersInSameAlliance). False for non-members, so it can never be true by default.';

-- ---------------------------------------------------------------------- ACL
grant execute on function public.create_alliance(text, text)                 to authenticated;
grant execute on function public.apply_to_alliance(uuid, text)               to authenticated;
grant execute on function public.respond_alliance_application(uuid, boolean) to authenticated;
grant execute on function public.leave_alliance()                            to authenticated;
grant execute on function public.dissolve_alliance()                         to authenticated;
grant execute on function public.create_alliance_rank(text, text[], integer) to authenticated;
grant execute on function public.set_alliance_member_rank(uuid, uuid)        to authenticated;
grant execute on function public.list_alliance_members(uuid)                 to authenticated;
grant execute on function public.players_in_same_alliance(uuid, uuid)        to authenticated, service_role;

revoke execute on function public.create_alliance(text, text)                 from anon;
revoke execute on function public.apply_to_alliance(uuid, text)               from anon;
revoke execute on function public.respond_alliance_application(uuid, boolean) from anon;
revoke execute on function public.leave_alliance()                            from anon;
revoke execute on function public.dissolve_alliance()                         from anon;
revoke execute on function public.create_alliance_rank(text, text[], integer) from anon;
revoke execute on function public.set_alliance_member_rank(uuid, uuid)        from anon;
revoke execute on function public.list_alliance_members(uuid)                 from anon;
revoke execute on function public.players_in_same_alliance(uuid, uuid)        from anon;

commit;