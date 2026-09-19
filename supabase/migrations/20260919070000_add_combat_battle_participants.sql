CREATE TABLE IF NOT EXISTS public.combat_battle_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  battle_id uuid NOT NULL REFERENCES public.combat_battles(id) ON DELETE CASCADE,
  side text NOT NULL CHECK (side IN ('ATTACKER','DEFENDER')),
  participant_type text NOT NULL CHECK (participant_type IN ('FLEET','PLANET')),
  fleet_id uuid NULL REFERENCES public.fleet_movements(id) ON DELETE RESTRICT,
  planet_id uuid NULL REFERENCES public.planets(id) ON DELETE RESTRICT,
  player_id uuid NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
  origin_planet_id uuid NULL REFERENCES public.planets(id) ON DELETE RESTRICT,
  mission_type text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT combat_battle_participants_shape_check CHECK (
    (participant_type = 'FLEET' AND fleet_id IS NOT NULL AND origin_planet_id IS NOT NULL AND planet_id IS NULL)
    OR
    (participant_type = 'PLANET' AND planet_id IS NOT NULL AND fleet_id IS NULL AND origin_planet_id IS NULL)
  ),
  CONSTRAINT combat_battle_participants_side_type_check CHECK (
    (side = 'ATTACKER' AND participant_type = 'FLEET')
    OR
    (side = 'DEFENDER' AND participant_type IN ('FLEET','PLANET'))
  ),
  CONSTRAINT combat_battle_participants_fleet_unique UNIQUE (battle_id, fleet_id),
  CONSTRAINT combat_battle_participants_planet_unique UNIQUE (battle_id, planet_id)
);

CREATE INDEX IF NOT EXISTS combat_battle_participants_battle_side_idx
  ON public.combat_battle_participants(battle_id, side, participant_type);
CREATE INDEX IF NOT EXISTS combat_battle_participants_player_idx
  ON public.combat_battle_participants(player_id);

ALTER TABLE public.combat_individual_units
  ADD COLUMN IF NOT EXISTS participant_id uuid NULL REFERENCES public.combat_battle_participants(id) ON DELETE CASCADE;
ALTER TABLE public.combat_round_snapshot_units
  ADD COLUMN IF NOT EXISTS participant_id uuid NULL REFERENCES public.combat_battle_participants(id) ON DELETE CASCADE;
ALTER TABLE public.combat_shots
  ADD COLUMN IF NOT EXISTS attacker_participant_id uuid NULL REFERENCES public.combat_battle_participants(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS target_participant_id uuid NULL REFERENCES public.combat_battle_participants(id) ON DELETE CASCADE;
ALTER TABLE public.combat_round_damage
  ADD COLUMN IF NOT EXISTS target_participant_id uuid NULL REFERENCES public.combat_battle_participants(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS combat_individual_units_participant_idx ON public.combat_individual_units(participant_id);
CREATE INDEX IF NOT EXISTS combat_round_snapshot_units_participant_idx ON public.combat_round_snapshot_units(participant_id);
CREATE INDEX IF NOT EXISTS combat_shots_attacker_participant_idx ON public.combat_shots(attacker_participant_id);
CREATE INDEX IF NOT EXISTS combat_shots_target_participant_idx ON public.combat_shots(target_participant_id);
CREATE INDEX IF NOT EXISTS combat_round_damage_target_participant_idx ON public.combat_round_damage(target_participant_id);