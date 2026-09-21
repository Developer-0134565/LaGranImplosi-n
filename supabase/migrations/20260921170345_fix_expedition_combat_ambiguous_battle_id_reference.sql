-- ============================================================================
-- COMBAT ENGINE PHASE 1 — CB-01 FOLLOW-UP (forward-only)
-- ----------------------------------------------------------------------------
-- Both expedition creators declare an OUT parameter named `battle_id`, and their
-- battle-counter UPDATE referenced the column `battle_id` unqualified inside
-- subqueries. With the default plpgsql.variable_conflict = error that raises
--   ERROR: column reference "battle_id" is ambiguous
-- so `resolve_expedition_pirates` / `resolve_expedition_aliens` could never
-- complete: expedition combat neither produced losses nor a DRAW — it aborted
-- (and, because the fleet worker runs the whole batch in one transaction, a
-- failing expedition fleet poisoned the entire tick: see CB-04).
--
-- This migration qualifies the counter subqueries through an explicit alias.
-- The accounting semantics are unchanged: the same six counts are computed from
-- the same rows.
-- ============================================================================

do $cb01f$
declare
  v_def text;
  v_new text;
  v_occ integer;
  r record;
begin
  for r in
    select * from (values
      (1, 'resolve_expedition_pirates', 6),
      (2, 'resolve_expedition_aliens', 6)
    ) as t(ord, fn, expected) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname = r.fn;

    if v_def is null then
      raise exception 'CB-01f: function public.% not found', r.fn;
    end if;

    v_occ := (length(v_def) - length(replace(v_def, 'FROM public.combat_individual_units WHERE battle_id=', '')))
             / length('FROM public.combat_individual_units WHERE battle_id=');

    if v_occ <> r.expected then
      raise exception 'CB-01f: % ambiguous references in public.% (expected %)', v_occ, r.fn, r.expected;
    end if;

    v_new := replace(v_def,
      'FROM public.combat_individual_units WHERE battle_id=',
      'FROM public.combat_individual_units ciu_cnt WHERE ciu_cnt.battle_id=');

    execute v_new;
  end loop;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname in ('resolve_expedition_pirates','resolve_expedition_aliens')
      and p.prosrc like '%FROM public.combat_individual_units WHERE battle_id=%'
  ) then
    raise exception 'CB-01f: ambiguous reference survived the repair';
  end if;
end
$cb01f$;
