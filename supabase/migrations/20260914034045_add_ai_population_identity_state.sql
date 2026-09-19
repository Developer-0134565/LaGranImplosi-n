alter table public.players add column if not exists player_type text not null default 'HUMAN';
alter table public.players add constraint players_player_type_check check (player_type in ('HUMAN','AI','SYSTEM'));
create table if not exists public.universe_population_state (
  universe_id uuid primary key references public.universes(id) on delete cascade,
  unlocked_systems bigint not null default 0 check (unlocked_systems >= 0),
  unlocked_positions bigint not null default 0 check (unlocked_positions >= 0),
  ai_planets_count bigint not null default 0 check (ai_planets_count >= 0),
  ai_density_target numeric not null default 0.075 check (ai_density_target >= 0 and ai_density_target <= 1),
  ai_density_tolerance numeric not null default 0.0025 check (ai_density_tolerance >= 0 and ai_density_tolerance < 1),
  ai_generation_batch integer not null default 100 check (ai_generation_batch > 0),
  reconciliation_interval_seconds integer not null default 300 check (reconciliation_interval_seconds > 0),
  next_reconciliation_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_players_universe_type on public.players(universe_id, player_type);
create index if not exists idx_planets_universe_player on public.planets(universe_id, player_id);
insert into public.universe_population_state (universe_id, unlocked_systems, unlocked_positions, ai_planets_count, ai_density_target, ai_density_tolerance)
select u.id,
       coalesce(sum(g.system_count),0)::bigint,
       (coalesce(sum(g.system_count),0) * 15)::bigint,
       count(p.id) filter (where p.is_destroyed=false and pl.player_type='AI'),
       u.ai_planet_density_target,
       u.ai_planet_density_tolerance
from public.universes u
left join public.universe_galaxies g on g.universe_id=u.id
left join public.planets p on p.universe_id=u.id
left join public.players pl on pl.id=p.player_id
group by u.id,u.ai_planet_density_target,u.ai_planet_density_tolerance
on conflict (universe_id) do update set
  unlocked_systems=excluded.unlocked_systems,
  unlocked_positions=excluded.unlocked_positions,
  ai_planets_count=excluded.ai_planets_count,
  ai_density_target=excluded.ai_density_target,
  ai_density_tolerance=excluded.ai_density_tolerance,
  updated_at=now();