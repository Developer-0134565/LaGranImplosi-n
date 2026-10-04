-- Resource settlement must not destroy cargo that was legitimately delivered.
--
-- THE DEFECT (proven against LIVE, 2026-09-30)
--   `update_planet_resources_until_raw` and `update_planet_resources` both ended with
--
--       v_metal := LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced));
--
--   That clamps the RUNNING TOTAL to the storage capacity. But the arrival resolvers
--   (`resolve_transport_arrival`, `resolve_deploy_arrival`, `resolve_expedition_return`)
--   credit cargo with an unconditional `metal = pr.metal + cargo`, exactly like OGameX's
--   `PlanetService::addResources()`, which clamps only at zero and never at capacity.
--
--   So a transport that overflows a full planet is credited in full, and then the very next
--   settlement tick silently DELETES the overflow:
--
--       capacity 100 000 · stock 99 000 · transport delivers 50 000
--       -> arrival  : 149 000 metal on the planet
--       -> next tick: 100 000 metal, i.e. 49 000 metal destroyed with no event and no report
--
-- OGameX evidence (`app/Services/PlanetService.php`, `updateResourcesUntil`):
--
--       $max_metal     = $this->metalStorage()->get();
--       $current_metal = $this->metal()->get();
--       if ($current_metal < $max_metal) {
--           $add_resources->metal->add(new Resource($this->planet->metal_production * $hours_difference));
--           // Prevent adding more metal than the max limit can support (storage limit).
--           if (($current_metal + $add_resources->metal->get()) > $max_metal) {
--               $add_resources->metal->set($max_metal - $current_metal);
--           }
--       }
--
--   The cap is applied to the amount being ADDED, never to the stock already held. A planet
--   that is over its capacity therefore keeps its resources and simply stops producing until
--   the player spends the excess down. Upstream loses nothing.
--
-- THE FIX
--   One immutable helper, `settle_resource_stock(current, delta, capacity)`, holds the whole
--   rule and both settlement functions delegate to it, so there is a single authority:
--
--       positive delta -> may only fill the FREE space, never more
--       negative delta -> always applied in full (the fusion plant consumes deuterium)
--       result         -> floored at 0
--
--   `LEAST(capacity, current + delta)` is deliberately NOT used: that is the expression that
--   destroys the overflow. The delivery paths keep crediting cargo exactly as OGameX does;
--   this migration only stops the settlement from taking it back.
--
-- NOT CHANGED: costs, times, production formulas, energy, queues, fleet dispatch, combat.
-- No balance is invented here: this restores upstream's demonstrated behaviour.

create or replace function public.settle_resource_stock(
    p_current numeric,
    p_delta   numeric,
    p_capacity numeric
)
returns numeric
language sql
immutable
set search_path to 'public', 'pg_temp'
as $$
    select greatest(
        0::numeric,
        p_current
        -- production may only occupy the free space; overflow already on the planet is left alone
        + least(greatest(p_delta, 0::numeric), greatest(p_capacity - p_current, 0::numeric))
        -- consumption is never throttled by capacity
        + least(p_delta, 0::numeric)
    );
$$;

comment on function public.settle_resource_stock(numeric, numeric, numeric) is
    'Storage settlement for one resource. Caps only the incoming PRODUCTION against the free '
    'space (OGameX PlanetService::updateResourcesUntil) and never reduces stock already held, '
    'so cargo credited by a transport/deploy/expedition arrival is not destroyed by a later tick. '
    'Consumption (negative delta, e.g. the fusion plant) always applies in full; the result is '
    'floored at 0.';

revoke all on function public.settle_resource_stock(numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function public.settle_resource_stock(numeric, numeric, numeric) to service_role;