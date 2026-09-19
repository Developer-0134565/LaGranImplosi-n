DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'deuteria-fleet-worker') THEN
    PERFORM cron.unschedule('deuteria-fleet-worker');
  END IF;
END $$;

SELECT cron.schedule(
  'deuteria-fleet-worker',
  '1 second',
  $$SELECT public.run_fleet_worker();$$
);