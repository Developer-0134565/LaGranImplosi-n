create or replace function public.complete_research(p_queue_id uuid)
returns boolean
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
declare
    v_player_id uuid;
    v_planet_id uuid;
    v_research_id text;
    v_target_level integer;
    v_status text;
    v_finishes_at timestamptz;
begin
    /*
     * Lock the queue so the same research cannot be completed twice.
     */
    select
        player_id,
        planet_id,
        research_id,
        target_level,
        status,
        finishes_at
    into
        v_player_id,
        v_planet_id,
        v_research_id,
        v_target_level,
        v_status,
        v_finishes_at
    from public.research_queue
    where id = p_queue_id
    for update;

    if not found then
        raise exception 'Research queue does not exist: %', p_queue_id;
    end if;

    if v_status <> 'RESEARCHING' then
        raise exception
            'Research queue is not active. Current status: %',
            v_status;
    end if;

    if v_finishes_at > now() then
        raise exception
            'Research is not finished yet. Finishes at: %',
            v_finishes_at;
    end if;

    /*
     * Temporal boundary:
     *
     * Production must be calculated with the OLD research level up to the
     * exact completion timestamp. Only after that timestamp may the new
     * research bonus affect production.
     *
     * This also makes offline completion deterministic: the resource engine
     * catches up only to finishes_at, then the research level is committed.
     */
    if v_planet_id is not null then
        perform public.update_planet_resources_until(
            v_planet_id,
            v_finishes_at
        );
    end if;

    /*
     * Apply the completed research level only after the temporal boundary.
     */
    insert into public.player_research (
        player_id,
        research_id,
        level
    )
    values (
        v_player_id,
        v_research_id,
        v_target_level
    )
    on conflict (player_id, research_id)
    do update
    set level = excluded.level;

    /* Close the queue entry. */
    update public.research_queue
    set status = 'COMPLETED'
    where id = p_queue_id;

    return true;
end;
$$;