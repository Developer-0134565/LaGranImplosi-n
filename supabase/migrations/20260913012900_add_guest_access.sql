ALTER TABLE public.players ADD COLUMN IF NOT EXISTS is_guest boolean NOT NULL DEFAULT false;

UPDATE public.players
SET is_guest = true
WHERE username = 'DevPlayer';

DROP POLICY IF EXISTS players_select_guest ON public.players;
CREATE POLICY players_select_guest
ON public.players
FOR SELECT
TO anon, authenticated
USING (is_guest = true);

DROP POLICY IF EXISTS planets_select_guest ON public.planets;
CREATE POLICY planets_select_guest
ON public.planets
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.players pl
    WHERE pl.id = planets.player_id
      AND pl.is_guest = true
  )
);

DROP POLICY IF EXISTS planet_resources_select_guest ON public.planet_resources;
CREATE POLICY planet_resources_select_guest
ON public.planet_resources
FOR SELECT
TO anon, authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.planets p
    JOIN public.players pl ON pl.id = p.player_id
    WHERE p.id = planet_resources.planet_id
      AND pl.is_guest = true
  )
);