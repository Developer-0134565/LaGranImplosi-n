grant select, insert, update, delete on table public.dashboard_widgets to anon, authenticated;

-- Keep RLS enabled. The current guest/dev frontend has no authenticated identity yet,
-- so the existing development policies continue to control row visibility.
