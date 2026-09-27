-- COMBAT - participant settlement replay
--
-- A settled non-initiating participant is already RETURNING/COMPLETED, so
-- resolve_attack_arrival() must find its battle through the participant row
-- before falling back to the historic battle-header anchor.

do $migration$
declare
  v_def text;
  v_old text;
  v_new text;
  v_occ integer;
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  where p.pronamespace='public'::regnamespace
    and p.proname='resolve_attack_arrival'
    and pg_get_function_identity_arguments(p.oid)='p_fleet_id uuid';

  if v_def is null then
    raise exception 'PARTICIPANT-REPLAY: resolve_attack_arrival(uuid) not found';
  end if;

  v_old := $old$
  if v_fleet.status<>'ARRIVED' then
    select cb.id into v_battle_id from public.combat_battles cb where cb.fleet_id=p_fleet_id order by cb.created_at limit 1;
    if v_battle_id is null then raise exception 'Attack fleet % has no combat battle',p_fleet_id; end if;
    return v_battle_id;
  end if;
$old$;

  v_new := $new$
  if v_fleet.status<>'ARRIVED' then
    select cb.id into v_battle_id
    from public.combat_battle_participants part
    join public.combat_battles cb on cb.id=part.battle_id
    where part.fleet_id=p_fleet_id
      and part.side='ATTACKER'
      and part.participant_type='FLEET'
    order by part.created_at,part.id
    limit 1;

    -- Historic DG-10 anchor for the initiating fleet and pre-participant rows.
    if v_battle_id is null then
      select cb.id into v_battle_id
      from public.combat_battles cb
      where cb.fleet_id=p_fleet_id
      order by cb.created_at
      limit 1;
    end if;

    if v_battle_id is null then raise exception 'Attack fleet % has no combat battle',p_fleet_id; end if;
    return v_battle_id;
  end if;
$new$;

  -- EOL-agnostic patch form: the stored body may use LF or CRLF (and this file may be
  -- checked out with either), so both fragments are canonicalised to LF first and then
  -- matched to the body's OWN line-ending style. position()/replace() therefore always
  -- agree and the definition keeps its original line endings (non-destructive).
  v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
  v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
  if position(chr(13) in v_def) > 0 then
    v_old := replace(v_old, chr(10), chr(13)||chr(10));
    v_new := replace(v_new, chr(10), chr(13)||chr(10));
  end if;
  if position(v_old in v_def)=0 then
    raise exception 'PARTICIPANT-REPLAY: expected early-return fragment not found';
  end if;

  select (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old) into v_occ;
  if v_occ <> 1 then
    raise exception 'PARTICIPANT-REPLAY: early-return fragment matched % time(s), expected 1', v_occ;
  end if;

  execute replace(v_def, v_old, v_new);
end
$migration$;

revoke all on function public.resolve_attack_arrival(uuid) from public, anon, authenticated;
grant execute on function public.resolve_attack_arrival(uuid) to service_role;
