create or replace function public.get_player_attack_protection(
  p_player_id uuid,
  p_at timestamptz default now()
)
returns table(
  out_protected boolean,
  out_protected_until timestamptz,
  out_reason text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_created timestamptz;
begin
  select pl.created_at
    into v_created
    from public.players pl
   where pl.id = p_player_id;

  if v_created is null then
    out_protected := false;
    out_protected_until := null;
    out_reason := 'PLAYER_NOT_FOUND';
    return next;
    return;
  end if;

  out_protected_until := v_created + interval '24 hours';
  out_protected := coalesce(p_at, now()) < out_protected_until;
  out_reason := case
    when out_protected then 'BEGINNER_PROTECTION_24H'
    else 'EXPIRED'
  end;
  return next;
end;
$function$;
