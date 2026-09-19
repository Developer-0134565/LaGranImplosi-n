alter table public.dashboard_widgets drop constraint if exists dashboard_widgets_widget_type_check;
alter table public.dashboard_widgets add constraint dashboard_widgets_widget_type_check check (widget_type in (
  'image','panel','text','button','resource','planet','fleet','galaxy',
  'minimap','clock','alerts','queue','production','energy','storage',
  'construction','research','shipyard','defense','missions','chat',
  'stats','evolution','universe_clock','leaderboard','quick_actions'
));