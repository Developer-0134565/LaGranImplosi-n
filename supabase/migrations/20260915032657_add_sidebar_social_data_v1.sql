create table if not exists public.player_notes (
  player_id uuid primary key references public.players(id) on delete cascade,
  content text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.player_messages (
  id uuid primary key default gen_random_uuid(),
  sender_player_id uuid references public.players(id) on delete set null,
  recipient_player_id uuid not null references public.players(id) on delete cascade,
  subject text not null default '',
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists player_messages_recipient_created_idx
  on public.player_messages(recipient_player_id, created_at desc);

create index if not exists player_messages_sender_idx
  on public.player_messages(sender_player_id);

grant select, insert, update, delete on table public.player_notes to anon, authenticated;
grant select, insert, update, delete on table public.player_messages to anon, authenticated;

alter table public.player_notes enable row level security;
alter table public.player_messages enable row level security;

drop policy if exists player_notes_dev_access on public.player_notes;
create policy player_notes_dev_access on public.player_notes
  for all to anon, authenticated
  using (true) with check (true);

drop policy if exists player_messages_dev_access on public.player_messages;
create policy player_messages_dev_access on public.player_messages
  for all to anon, authenticated
  using (true) with check (true);
