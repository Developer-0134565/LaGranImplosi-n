-- COORDINATE LOOKUPS — explicit `kind = 'PLANET'` filter (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Accepted model (user decision): every coordinate lookup that means "a planet" must filter explicitly on
-- `kind = 'PLANET'`. Four LIVE functions matched coordinates against `public.planets` and therefore could resolve a
-- moon by accident:
--   * `start_colonize_fleet`           occupancy check of the target position
--   * `resolve_colonize_arrival`       the same check when the colony ship arrives
--   * `provision_player`               first free position for a new homeworld (anti-join on `existing.*`)
--   * `reconcile_universe_ai_population`  first free position for a new AI planet (anti-join on `existing.*`)
--
-- Instead of re-declaring four certified functions by hand (and risking a typo in a body the engine already
-- certifies), this migration REPLACES the exact matched fragment inside the LIVE definition read back from the
-- catalog and re-executes it. Every replacement is asserted: if a fragment is not found (already patched, or the
-- function changed), the migration RAISES and writes nothing. A fresh replay of the repository reproduces the same
-- result, because the catalog still holds the unpatched definition when this migration runs.
--
-- Behaviour note: a moon always belongs to a live planet, so these filters are also semantically stricter — after a
-- planet is destroyed a surviving moon can no longer keep its position marked as occupied by a planet.
begin;

do $patch$
declare
    v_def text;
    v_new text;
    v_target text := 'public.start_colonize_fleet';
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'start_colonize_fleet';

    if v_def is null then
        raise exception 'COORD_KIND_PATCH: % not found', v_target;
    end if;

    v_new := replace(v_def,
        'p.position=p_position and not p.is_destroyed)',
        'p.position=p_position and p.kind=''PLANET'' and not p.is_destroyed)');

    if v_new = v_def then
        raise exception 'COORD_KIND_PATCH: colonize occupancy fragment not found in %', v_target;
    end if;

    execute v_new;
end;
$patch$;

do $patch$
declare
    v_def text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'resolve_colonize_arrival';

    if v_def is null then
        raise exception 'COORD_KIND_PATCH: resolve_colonize_arrival not found';
    end if;

    v_new := replace(v_def,
        'AND p.position=v_fleet.destination_position',
        'AND p.position=v_fleet.destination_position' || chr(10) || '     AND p.kind = ''PLANET''');

    if v_new = v_def then
        raise exception 'COORD_KIND_PATCH: colonize arrival fragment not found';
    end if;

    execute v_new;
end;
$patch$;

do $patch$
declare
    v_def text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'provision_player';

    if v_def is null then
        raise exception 'COORD_KIND_PATCH: provision_player not found';
    end if;

    v_new := replace(v_def,
        'and existing.position = slot.planet_position',
        'and existing.position = slot.planet_position' || chr(10) || '           and existing.kind = ''PLANET''');

    if v_new = v_def then
        raise exception 'COORD_KIND_PATCH: provision_player anti-join fragment not found';
    end if;

    execute v_new;
end;
$patch$;

do $patch$
declare
    v_def text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'reconcile_universe_ai_population';

    if v_def is null then
        raise exception 'COORD_KIND_PATCH: reconcile_universe_ai_population not found';
    end if;

    v_new := replace(v_def,
        'AND existing.position = pos.position',
        'AND existing.position = pos.position' || chr(10) || '             AND existing.kind = ''PLANET''');

    if v_new = v_def then
        raise exception 'COORD_KIND_PATCH: reconcile anti-join fragment not found';
    end if;

    execute v_new;
end;
$patch$;

commit;
