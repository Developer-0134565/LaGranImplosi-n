-- The frontend is used by signed-in players, so the sanitized monitor RPC
-- must be callable by authenticated users as well as anonymous visitors.
-- The function itself remains SECURITY DEFINER with a restricted, read-only
-- response surface; this migration only expands EXECUTE to the authenticated role.

revoke execute on function public.get_universe_evolution_monitor_public(uuid) from public;

grant execute on function public.get_universe_evolution_monitor_public(uuid)
  to anon, authenticated;
