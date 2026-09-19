BEGIN;

CREATE INDEX IF NOT EXISTS fleet_movements_outbound_arrival_idx
  ON public.fleet_movements(arrives_at, id)
  WHERE status='OUTBOUND';

CREATE INDEX IF NOT EXISTS fleet_movements_returning_idx
  ON public.fleet_movements(returns_at, id)
  WHERE status='RETURNING';

REVOKE EXECUTE ON FUNCTION public.process_fleet_movements() FROM PUBLIC, anon, authenticated;

COMMIT;
