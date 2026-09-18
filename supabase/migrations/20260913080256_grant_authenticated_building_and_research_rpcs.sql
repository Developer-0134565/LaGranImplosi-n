BEGIN;

-- These functions already distinguish authenticated owners from guest callers
-- using auth.uid() and is_guest. Their missing authenticated EXECUTE grant
-- made the authenticated path unreachable through PostgREST.
GRANT EXECUTE ON FUNCTION public.start_building(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_research(uuid, uuid, text) TO authenticated;

COMMIT;
