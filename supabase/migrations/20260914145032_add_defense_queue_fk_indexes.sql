CREATE INDEX IF NOT EXISTS idx_defense_prerequisites_building_id ON public.defense_prerequisites(building_id);
CREATE INDEX IF NOT EXISTS idx_defense_prerequisites_research_id ON public.defense_prerequisites(research_id);
CREATE INDEX IF NOT EXISTS idx_defense_queue_defense_id ON public.defense_queue(defense_id);