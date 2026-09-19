create table if not exists public.universe_process_health (
  universe_id uuid primary key references public.universes(id) on delete cascade,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  last_ticks_executed integer not null default 0 check (last_ticks_executed >= 0),
  last_systems_expanded integer not null default 0 check (last_systems_expanded >= 0),
  last_error text,
  updated_at timestamptz not null default now()
);

revoke all on public.universe_process_health from anon, authenticated;

grant select on public.universe_process_health to service_role;

create or replace function public.process_universe_heartbeat()
returns table(universes_processed integer, total_ticks_executed integer, systems_expanded integer)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_universe record;
    v_clock record;
    v_roll record;
    v_expansion record;
    v_population record;
    v_universes integer := 0;
    v_ticks integer := 0;
    v_systems integer := 0;
    v_population_due boolean;
    v_started_at timestamptz := clock_timestamp();
begin
    for v_universe in
        select id
        from public.universes
        where is_active = true
        order by created_at, id
    loop
        begin
            select * into v_clock
            from public.process_universe_clock(v_universe.id);

            v_universes := v_universes + 1;
            v_ticks := v_ticks + coalesce(v_clock.ticks_executed, 0);

            if exists (
                select 1
                from public.universe_expansion_state
                where universe_id = v_universe.id
            ) then
                select * into v_roll
                from public.process_universe_galaxy_roll(v_universe.id);

                select * into v_expansion
                from public.process_universe_system_expansion(v_universe.id);

                v_systems := v_systems + coalesce(v_expansion.systems_expanded, 0);

                if coalesce(v_roll.galaxies_created, 0) > 0
                   or coalesce(v_expansion.systems_expanded, 0) > 0 then
                    select * into v_population
                    from public.reconcile_universe_ai_population(v_universe.id);
                end if;
            end if;

            select exists (
                select 1
                from public.universe_population_state
                where universe_id = v_universe.id
                  and next_reconciliation_at <= now()
            ) into v_population_due;

            if v_population_due then
                select * into v_population
                from public.reconcile_universe_ai_population(v_universe.id);
            end if;

            insert into public.universe_process_health (
                universe_id,
                last_success_at,
                consecutive_failures,
                last_ticks_executed,
                last_systems_expanded,
                last_error,
                updated_at
            )
            values (
                v_universe.id,
                clock_timestamp(),
                0,
                coalesce(v_clock.ticks_executed, 0),
                coalesce(v_expansion.systems_expanded, 0),
                null,
                clock_timestamp()
            )
            on conflict (universe_id) do update
            set last_success_at = excluded.last_success_at,
                consecutive_failures = 0,
                last_ticks_executed = excluded.last_ticks_executed,
                last_systems_expanded = excluded.last_systems_expanded,
                last_error = null,
                updated_at = excluded.updated_at;

        exception when others then
            insert into public.universe_process_health (
                universe_id,
                last_failure_at,
                consecutive_failures,
                last_error,
                updated_at
            )
            values (
                v_universe.id,
                clock_timestamp(),
                1,
                left(sqlerrm, 2000),
                clock_timestamp()
            )
            on conflict (universe_id) do update
            set last_failure_at = excluded.last_failure_at,
                consecutive_failures = public.universe_process_health.consecutive_failures + 1,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at;

            raise warning 'Universe heartbeat failed for %: % (%)',
                v_universe.id, sqlerrm, sqlstate;
        end;
    end loop;

    return query
    select v_universes, v_ticks, v_systems;
end;
$function$;