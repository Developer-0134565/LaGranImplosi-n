UPDATE public.universe_clock
SET tick_interval_seconds = 60,
    next_tick_at = now() + interval '60 seconds',
    updated_at = now()
WHERE tick_interval_seconds <> 60
   OR next_tick_at <= now();