DROP INDEX IF EXISTS public.ux_combat_debris_generations_battle;
COMMENT ON INDEX public.combat_debris_generations_battle_unique IS 'Exactly one debris generation record per combat battle';