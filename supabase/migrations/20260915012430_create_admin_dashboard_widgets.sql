create table if not exists public.dashboard_widgets (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  widget_type text not null check (widget_type in ('image','panel','text','button','resource','planet','fleet','galaxy')),
  name text not null default 'Widget',
  x numeric(12,2) not null default 0,
  y numeric(12,2) not null default 0,
  width numeric(12,2) not null default 320,
  height numeric(12,2) not null default 180,
  z_index integer not null default 1,
  opacity numeric(4,3) not null default 1 check (opacity >= 0 and opacity <= 1),
  visible boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists dashboard_widgets_player_idx on public.dashboard_widgets(player_id);

alter table public.dashboard_widgets enable row level security;

create policy dashboard_widgets_select on public.dashboard_widgets for select using (true);
create policy dashboard_widgets_insert on public.dashboard_widgets for insert with check (true);
create policy dashboard_widgets_update on public.dashboard_widgets for update using (true) with check (true);
create policy dashboard_widgets_delete on public.dashboard_widgets for delete using (true);
