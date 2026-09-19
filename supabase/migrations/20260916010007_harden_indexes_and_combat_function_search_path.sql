create index if not exists idx_early_tester_registrations_player_id on public.early_tester_registrations (player_id);

drop index if exists public.idx_players_user_id;

alter function public.apply_attack_loot(uuid) set search_path = pg_catalog, public;
alter function public.resolve_attack_arrival(uuid) set search_path = pg_catalog, public;