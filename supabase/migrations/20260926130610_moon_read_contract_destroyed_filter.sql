-- FIX — `get_player_moons()` must exclude destroyed moons (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- The contract created moments earlier (`20260926130600_moon_read_contracts`) selected every moon of the caller.
-- A destroyed moon keeps its row (`is_destroyed = true`, so every relation stays intact) and must not be listed,
-- exactly like a destroyed planet is excluded from the planet contracts.
-- Applied as a catalog fragment replacement so the definition itself stays authoritative; a fresh replay reproduces
-- the same result because the catalog still holds the unpatched definition when this migration runs.
begin;

do $patch$
declare
    v_def text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_player_moons';

    if v_def is null then
        raise exception 'MOONS_FILTER_PATCH: get_player_moons not found';
    end if;

    v_new := replace(v_def,
        'where m.kind = ''MOON''',
        'where m.kind = ''MOON''' || chr(10) || '       and not m.is_destroyed');

    if v_new = v_def then
        raise exception 'MOONS_FILTER_PATCH: fragment not found in get_player_moons';
    end if;

    execute v_new;
end;
$patch$;

commit;
