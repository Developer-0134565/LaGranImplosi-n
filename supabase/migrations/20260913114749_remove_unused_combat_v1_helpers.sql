DROP FUNCTION IF EXISTS public.apply_combat_damage_v1(uuid,integer,text,text,text,numeric);
DROP FUNCTION IF EXISTS public.calculate_combat_damage_v1(numeric,numeric,numeric);
DROP FUNCTION IF EXISTS public.calculate_combat_hull_v1(numeric);
DROP FUNCTION IF EXISTS public.calculate_combat_shot_v1(numeric,numeric,numeric);
DROP FUNCTION IF EXISTS public.calculate_combat_shot_v2(numeric,numeric,numeric);
DROP FUNCTION IF EXISTS public.select_combat_target_v1(uuid,integer,text);
DROP FUNCTION IF EXISTS public.resolve_combat_shot_v2(uuid,integer,integer);