ALTER TABLE public.players ADD COLUMN IF NOT EXISTS dark_matter numeric NOT NULL DEFAULT 0 CHECK (dark_matter >= 0);

CREATE INDEX IF NOT EXISTS idx_players_dark_matter ON public.players (id, dark_matter);