-- ============================================================================
-- COMBAT ENGINE PHASE 1 — CB-01 FOLLOW-UP (forward-only)
-- ----------------------------------------------------------------------------
-- The last-round lookup added by 20260921170435 used an unqualified `battle_id`
-- inside the subquery, which is ambiguous in functions that declare a
-- `battle_id` OUT parameter (plpgsql.variable_conflict = error). This migration
-- qualifies it through an explicit alias. Same semantics, no ambiguity.
-- ============================================================================

do $cb01h$
declare
  v_def text;
  v_new text;
  v_occ integer;
  r record;
begin
  for r in
    select * from (values
      (1, 'resolve_expedition_pirates', 'v_battle'),
      (2, 'resolve_expedition_aliens', 'b')
    ) as t(ord, fn, battle_var) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname = r.fn;

    if v_def is null then
      raise exception 'CB-01h: function public.% not found', r.fn;
    end if;

    v_occ := (length(v_def) - length(replace(v_def,
      '(select max(round_number) from public.combat_individual_units where battle_id=' || r.battle_var || ')', '')))
      / length('(select max(round_number) from public.combat_individual_units where battle_id=' || r.battle_var || ')');

    if v_occ <> 2 then
      raise exception 'CB-01h: last-round lookup matched % time(s) in public.% (expected 2)', v_occ, r.fn;
    end if;

    v_new := replace(v_def,
      '(select max(round_number) from public.combat_individual_units where battle_id=' || r.battle_var || ')',
      '(select max(ciu_max.round_number) from public.combat_individual_units ciu_max where ciu_max.battle_id=' || r.battle_var || ')');

    execute v_new;
  end loop;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname in ('resolve_expedition_pirates','resolve_expedition_aliens')
      and p.prosrc like '%(select max(round_number) from public.combat_individual_units where battle_id=%'
  ) then
    raise exception 'CB-01h: ambiguous last-round lookup survived the repair';
  end if;
end
$cb01h$;
