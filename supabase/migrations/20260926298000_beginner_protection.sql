-- ============================================================================
-- BEGINNER PROTECTION (human targets) — LGI (2026-09-26)
-- ----------------------------------------------------------------------------
-- FASE 2/3 result of the audit (evidence, not assumption):
--   * LGI had NO beginner protection at all: repo-wide search for beginner/newbie/novice/immunity/protected_until
--     returns only documentation notes, and LIVE has zero functions or columns referencing any of them;
--   * OGameX @ 7c420bad has none either: `AttackMission::isMissionPossible` validates target existence, the
--     destroyed-moon rule, own-planet, `checkTargetVacationMode` and `checkAdminProtection` — no protection
--     window, no account-age or points-based attack restriction. `EspionageMission` blocks only the admin
--     planet, and `start_support_fleet` (ACS defend) is support, not attack, so neither is restricted.
--
-- What LGI DOES already own: a 24-hour window anchored on `players.created_at`, approved by the owner for the AI
-- attacker gate of 20260926291000 ("no attack during the AI's first 24 h"). This contract reuses exactly that
-- window — same duration, same anchor, no invented formula — and applies it to the DEFENDING side of a human
-- player, which is what the game was missing.
--
-- Scope, determined by the evidence above and asserted by the fixture:
--   * blocked:  ATTACK missions whose destination belongs to a human inside its first 24 h;
--   * allowed:  espionage, transport, colonisation, recycling and ACS defend/support (none of them is an attack);
--   * NOT invented: an attacker-side restriction for humans (OGameX has none) and a target-side rule for AI
--     empires (AI already has the symmetric attacker-side gate; extending it is a product decision).
--
-- Enforcement is a BEFORE INSERT trigger on `fleet_movements`, the same pattern the certified fleet-slot guard
-- uses, so EVERY dispatch path is covered by construction — `start_fleet`, `start_fleet_mixed` and any future
-- attack dispatcher — and a client cannot bypass it by changing parameters.
-- ============================================================================

create or replace function public.get_player_attack_protection(p_player_id uuid, p_at timestamptz default now())
returns table(out_protected boolean, out_protected_until timestamptz, out_reason text)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_created timestamptz;
    v_human boolean;
begin
    select pl.created_at, (pl.user_id is not null) into v_created, v_human
      from public.players pl
     where pl.id = p_player_id;

    if v_created is null then
        out_protected := false; out_protected_until := null; out_reason := 'PLAYER_NOT_FOUND';
        return next; return;
    end if;

    if not coalesce(v_human, false) then
        /* AI empires already have the owner-approved attacker-side 24 h gate (20260926291000); a target-side
           rule for them would be a new product decision and is deliberately not invented here. */
        out_protected := false; out_protected_until := null; out_reason := 'NOT_HUMAN_TARGET';
        return next; return;
    end if;

    out_protected_until := v_created + interval '24 hours';
    out_protected := coalesce(p_at, now()) < out_protected_until;
    out_reason := case when out_protected then 'BEGINNER_PROTECTION_24H' else 'EXPIRED' end;
    return next;
end;
$function$;

revoke all on function public.get_player_attack_protection(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.get_player_attack_protection(uuid, timestamptz) to service_role;

create or replace function public.enforce_beginner_protection_before_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_target uuid;
    v_prot record;
begin
    if new.mission_type <> 'ATTACK' or new.destination_planet_id is null then
        return new;
    end if;

    select p.player_id into v_target
      from public.planets p
     where p.id = new.destination_planet_id;

    if v_target is null or v_target = new.player_id then
        return new;   /* unowned target or own body: the certified dispatchers already decide those cases */
    end if;

    select * into v_prot
      from public.get_player_attack_protection(v_target, coalesce(new.started_at, now()));

    if coalesce(v_prot.out_protected, false) then
        raise exception 'TARGET_BEGINNER_PROTECTED: player % is protected until %', v_target, v_prot.out_protected_until;
    end if;

    return new;
end;
$function$;

revoke all on function public.enforce_beginner_protection_before_insert() from public, anon, authenticated;

drop trigger if exists trg_enforce_beginner_protection on public.fleet_movements;
create trigger trg_enforce_beginner_protection
    before insert on public.fleet_movements
    for each row
    execute function public.enforce_beginner_protection_before_insert();