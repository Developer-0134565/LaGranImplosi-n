REVOKE EXECUTE ON FUNCTION public.start_building(uuid, uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.start_fleet(uuid, uuid, uuid, text, bigint, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.start_lifeform_building(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.start_lifeform_research(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.start_research(uuid, uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.start_ship(uuid, uuid, text, bigint) FROM anon;