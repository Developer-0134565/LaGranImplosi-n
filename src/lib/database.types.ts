export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      building_definitions: {
        Row: {
          base_build_time_seconds: number
          base_crystal: number
          base_deuterium: number
          base_metal: number
          cost_factor: number
          created_at: string
          description: string | null
          id: string
          max_level: number | null
          name: string
          time_factor: number | null
          valid_kinds: string[]
        }
        Insert: {
          base_build_time_seconds?: number
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          cost_factor?: number
          created_at?: string
          description?: string | null
          id: string
          max_level?: number | null
          name: string
          time_factor?: number | null
          valid_kinds?: string[]
        }
        Update: {
          base_build_time_seconds?: number
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          cost_factor?: number
          created_at?: string
          description?: string | null
          id?: string
          max_level?: number | null
          name?: string
          time_factor?: number | null
          valid_kinds?: string[]
        }
        Relationships: []
      }
      building_energy_definitions: {
        Row: {
          base_consumption: number
          building_id: string
          consumption_factor: number
          created_at: string
        }
        Insert: {
          base_consumption?: number
          building_id: string
          consumption_factor?: number
          created_at?: string
        }
        Update: {
          base_consumption?: number
          building_id?: string
          consumption_factor?: number
          created_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "building_energy_definitions_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: true
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "building_energy_definitions_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: true
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      building_prerequisites: {
        Row: {
          building_id: string
          prerequisite_building_id: string
          required_level: number
        }
        Insert: {
          building_id: string
          prerequisite_building_id: string
          required_level?: number
        }
        Update: {
          building_id?: string
          prerequisite_building_id?: string
          required_level?: number
        }
        Relationships: [
          {
            foreignKeyName: "building_prerequisites_building_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "building_prerequisites_building_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "building_prerequisites_required_building_fkey"
            columns: ["prerequisite_building_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "building_prerequisites_required_building_fkey"
            columns: ["prerequisite_building_id"]
            isOneToOne: false
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      building_queue: {
        Row: {
          building_id: string
          created_at: string
          finishes_at: string
          id: string
          is_downgrade: boolean
          planet_id: string
          started_at: string
          status: string
          target_level: number
        }
        Insert: {
          building_id: string
          created_at?: string
          finishes_at: string
          id?: string
          is_downgrade?: boolean
          planet_id: string
          started_at: string
          status?: string
          target_level: number
        }
        Update: {
          building_id?: string
          created_at?: string
          finishes_at?: string
          id?: string
          is_downgrade?: boolean
          planet_id?: string
          started_at?: string
          status?: string
          target_level?: number
        }
        Relationships: [
          {
            foreignKeyName: "building_queue_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "building_queue_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "building_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "building_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "building_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      combat_battles: {
        Row: {
          attacker_player_id: string
          attacker_ships_after: number
          attacker_ships_before: number
          attacker_win: boolean | null
          created_at: string
          defender_combat_units_after: number
          defender_combat_units_before: number
          defender_defenses_after: number
          defender_defenses_before: number
          defender_planet_id: string | null
          defender_ships_after: number
          defender_ships_before: number
          defender_win: boolean | null
          draw: boolean
          finished_at: string | null
          fleet_id: string
          id: string
          loot_applied_at: string | null
          loot_crystal: number
          loot_deuterium: number
          loot_metal: number
          started_at: string
        }
        Insert: {
          attacker_player_id: string
          attacker_ships_after?: number
          attacker_ships_before?: number
          attacker_win?: boolean | null
          created_at?: string
          defender_combat_units_after?: number
          defender_combat_units_before?: number
          defender_defenses_after?: number
          defender_defenses_before?: number
          defender_planet_id?: string | null
          defender_ships_after?: number
          defender_ships_before?: number
          defender_win?: boolean | null
          draw?: boolean
          finished_at?: string | null
          fleet_id: string
          id?: string
          loot_applied_at?: string | null
          loot_crystal?: number
          loot_deuterium?: number
          loot_metal?: number
          started_at?: string
        }
        Update: {
          attacker_player_id?: string
          attacker_ships_after?: number
          attacker_ships_before?: number
          attacker_win?: boolean | null
          created_at?: string
          defender_combat_units_after?: number
          defender_combat_units_before?: number
          defender_defenses_after?: number
          defender_defenses_before?: number
          defender_planet_id?: string | null
          defender_ships_after?: number
          defender_ships_before?: number
          defender_win?: boolean | null
          draw?: boolean
          finished_at?: string | null
          fleet_id?: string
          id?: string
          loot_applied_at?: string | null
          loot_crystal?: number
          loot_deuterium?: number
          loot_metal?: number
          started_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "combat_battles_attacker_player_id_fkey"
            columns: ["attacker_player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "combat_battles_defender_planet_id_fkey"
            columns: ["defender_planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "combat_battles_defender_planet_id_fkey"
            columns: ["defender_planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "combat_battles_defender_planet_id_fkey"
            columns: ["defender_planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "combat_battles_fleet_id_fkey"
            columns: ["fleet_id"]
            isOneToOne: false
            referencedRelation: "fleet_movements"
            referencedColumns: ["id"]
          },
        ]
      }
      combat_debris_generations: {
        Row: {
          battle_id: string
          created_at: string
          crystal_generated: number
          debris_field_id: string
          id: string
          metal_generated: number
        }
        Insert: {
          battle_id: string
          created_at?: string
          crystal_generated?: number
          debris_field_id: string
          id?: string
          metal_generated?: number
        }
        Update: {
          battle_id?: string
          created_at?: string
          crystal_generated?: number
          debris_field_id?: string
          id?: string
          metal_generated?: number
        }
        Relationships: [
          {
            foreignKeyName: "combat_debris_generations_battle_id_fkey"
            columns: ["battle_id"]
            isOneToOne: true
            referencedRelation: "combat_battles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "combat_debris_generations_debris_field_id_fkey"
            columns: ["debris_field_id"]
            isOneToOne: false
            referencedRelation: "debris_fields"
            referencedColumns: ["id"]
          },
        ]
      }
      combat_defense_repairs: {
        Row: {
          battle_id: string
          created_at: string
          defense_id: string
          destroyed_quantity: number
          id: string
          planet_id: string
          repaired_quantity: number
        }
        Insert: {
          battle_id: string
          created_at?: string
          defense_id: string
          destroyed_quantity: number
          id?: string
          planet_id: string
          repaired_quantity: number
        }
        Update: {
          battle_id?: string
          created_at?: string
          defense_id?: string
          destroyed_quantity?: number
          id?: string
          planet_id?: string
          repaired_quantity?: number
        }
        Relationships: [
          {
            foreignKeyName: "combat_defense_repairs_battle_id_fkey"
            columns: ["battle_id"]
            isOneToOne: false
            referencedRelation: "combat_battles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "combat_defense_repairs_defense_id_fkey"
            columns: ["defense_id"]
            isOneToOne: false
            referencedRelation: "defense_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "combat_defense_repairs_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "combat_defense_repairs_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "combat_defense_repairs_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      combat_individual_units: {
        Row: {
          alive: boolean
          attack: number
          battle_id: string
          created_at: string
          hull_current: number
          hull_max: number
          id: string
          round_number: number
          shield_current: number
          shield_max: number
          side: string
          structural_integrity: number
          unit_id: string
          unit_number: number
          unit_type: string
        }
        Insert: {
          alive?: boolean
          attack: number
          battle_id: string
          created_at?: string
          hull_current: number
          hull_max: number
          id?: string
          round_number: number
          shield_current: number
          shield_max: number
          side: string
          structural_integrity: number
          unit_id: string
          unit_number: number
          unit_type: string
        }
        Update: {
          alive?: boolean
          attack?: number
          battle_id?: string
          created_at?: string
          hull_current?: number
          hull_max?: number
          id?: string
          round_number?: number
          shield_current?: number
          shield_max?: number
          side?: string
          structural_integrity?: number
          unit_id?: string
          unit_number?: number
          unit_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "combat_individual_units_battle_id_fkey"
            columns: ["battle_id"]
            isOneToOne: false
            referencedRelation: "combat_battles"
            referencedColumns: ["id"]
          },
        ]
      }
      combat_rapidfire: {
        Row: {
          attacker_unit_id: string
          attacker_unit_type: string
          created_at: string
          id: string
          rapidfire: number
          target_unit_id: string
          target_unit_type: string
        }
        Insert: {
          attacker_unit_id: string
          attacker_unit_type: string
          created_at?: string
          id?: string
          rapidfire: number
          target_unit_id: string
          target_unit_type: string
        }
        Update: {
          attacker_unit_id?: string
          attacker_unit_type?: string
          created_at?: string
          id?: string
          rapidfire?: number
          target_unit_id?: string
          target_unit_type?: string
        }
        Relationships: []
      }
      combat_round_damage: {
        Row: {
          attack_value: number
          battle_id: string
          created_at: string
          exploded: boolean
          hull_damage: number
          id: string
          round_number: number
          shield_damage: number
          source_shot_number: number
          target_side: string
          target_unit_id: string
          target_unit_number: number
          target_unit_type: string
        }
        Insert: {
          attack_value?: number
          battle_id: string
          created_at?: string
          exploded?: boolean
          hull_damage?: number
          id?: string
          round_number: number
          shield_damage?: number
          source_shot_number: number
          target_side: string
          target_unit_id: string
          target_unit_number: number
          target_unit_type: string
        }
        Update: {
          attack_value?: number
          battle_id?: string
          created_at?: string
          exploded?: boolean
          hull_damage?: number
          id?: string
          round_number?: number
          shield_damage?: number
          source_shot_number?: number
          target_side?: string
          target_unit_id?: string
          target_unit_number?: number
          target_unit_type?: string
        }
        Relationships: []
      }
      combat_round_snapshot_units: {
        Row: {
          alive_start: boolean
          attack: number
          battle_id: string
          created_at: string
          hull_max: number
          hull_start: number
          id: string
          round_number: number
          shield_max: number
          shield_start: number
          side: string
          unit_id: string
          unit_number: number
          unit_type: string
        }
        Insert: {
          alive_start?: boolean
          attack?: number
          battle_id: string
          created_at?: string
          hull_max?: number
          hull_start?: number
          id?: string
          round_number: number
          shield_max?: number
          shield_start?: number
          side: string
          unit_id: string
          unit_number: number
          unit_type: string
        }
        Update: {
          alive_start?: boolean
          attack?: number
          battle_id?: string
          created_at?: string
          hull_max?: number
          hull_start?: number
          id?: string
          round_number?: number
          shield_max?: number
          shield_start?: number
          side?: string
          unit_id?: string
          unit_number?: number
          unit_type?: string
        }
        Relationships: []
      }
      combat_rounds: {
        Row: {
          attacker_attack: number
          attacker_hull: number
          attacker_shield: number
          attacker_units_after: number
          attacker_units_before: number
          battle_id: string
          created_at: string
          defender_attack: number
          defender_combat_units_after: number
          defender_combat_units_before: number
          defender_hull: number
          defender_shield: number
          defender_units_after: number
          defender_units_before: number
          id: string
          round_number: number
        }
        Insert: {
          attacker_attack?: number
          attacker_hull?: number
          attacker_shield?: number
          attacker_units_after?: number
          attacker_units_before?: number
          battle_id: string
          created_at?: string
          defender_attack?: number
          defender_combat_units_after?: number
          defender_combat_units_before?: number
          defender_hull?: number
          defender_shield?: number
          defender_units_after?: number
          defender_units_before?: number
          id?: string
          round_number: number
        }
        Update: {
          attacker_attack?: number
          attacker_hull?: number
          attacker_shield?: number
          attacker_units_after?: number
          attacker_units_before?: number
          battle_id?: string
          created_at?: string
          defender_attack?: number
          defender_combat_units_after?: number
          defender_combat_units_before?: number
          defender_hull?: number
          defender_shield?: number
          defender_units_after?: number
          defender_units_before?: number
          id?: string
          round_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "combat_rounds_battle_id_fkey"
            columns: ["battle_id"]
            isOneToOne: false
            referencedRelation: "combat_battles"
            referencedColumns: ["id"]
          },
        ]
      }
      combat_shots: {
        Row: {
          attack_value: number
          attacker_side: string
          attacker_unit_id: string
          attacker_unit_number: number | null
          attacker_unit_type: string
          battle_id: string
          created_at: string
          effective_damage: number
          hull_damage: number
          id: string
          is_initial_shot: boolean
          rapidfire_probability: number | null
          rapidfire_roll: number | null
          rapidfire_triggered: boolean
          rapidfire_value: number
          raw_damage: number
          round_number: number
          shield_damage: number
          shot_number: number
          target_destroyed: boolean
          target_shield_before: number
          target_unit_id: string
          target_unit_number: number | null
          target_unit_type: string
        }
        Insert: {
          attack_value: number
          attacker_side: string
          attacker_unit_id: string
          attacker_unit_number?: number | null
          attacker_unit_type: string
          battle_id: string
          created_at?: string
          effective_damage: number
          hull_damage?: number
          id?: string
          is_initial_shot?: boolean
          rapidfire_probability?: number | null
          rapidfire_roll?: number | null
          rapidfire_triggered?: boolean
          rapidfire_value?: number
          raw_damage: number
          round_number: number
          shield_damage?: number
          shot_number: number
          target_destroyed?: boolean
          target_shield_before: number
          target_unit_id: string
          target_unit_number?: number | null
          target_unit_type: string
        }
        Update: {
          attack_value?: number
          attacker_side?: string
          attacker_unit_id?: string
          attacker_unit_number?: number | null
          attacker_unit_type?: string
          battle_id?: string
          created_at?: string
          effective_damage?: number
          hull_damage?: number
          id?: string
          is_initial_shot?: boolean
          rapidfire_probability?: number | null
          rapidfire_roll?: number | null
          rapidfire_triggered?: boolean
          rapidfire_value?: number
          raw_damage?: number
          round_number?: number
          shield_damage?: number
          shot_number?: number
          target_destroyed?: boolean
          target_shield_before?: number
          target_unit_id?: string
          target_unit_number?: number | null
          target_unit_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "combat_shots_battle_id_fkey"
            columns: ["battle_id"]
            isOneToOne: false
            referencedRelation: "combat_battles"
            referencedColumns: ["id"]
          },
        ]
      }
      combat_unit_state: {
        Row: {
          attack: number
          battle_id: string
          created_at: string
          hull_current: number
          hull_max: number
          id: string
          quantity: number
          quantity_alive: number
          round_number: number
          shield_current: number
          shield_max: number
          side: string
          structural_integrity: number
          unit_id: string
          unit_type: string
        }
        Insert: {
          attack: number
          battle_id: string
          created_at?: string
          hull_current: number
          hull_max: number
          id?: string
          quantity: number
          quantity_alive: number
          round_number: number
          shield_current: number
          shield_max: number
          side: string
          structural_integrity: number
          unit_id: string
          unit_type: string
        }
        Update: {
          attack?: number
          battle_id?: string
          created_at?: string
          hull_current?: number
          hull_max?: number
          id?: string
          quantity?: number
          quantity_alive?: number
          round_number?: number
          shield_current?: number
          shield_max?: number
          side?: string
          structural_integrity?: number
          unit_id?: string
          unit_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "combat_unit_state_battle_id_fkey"
            columns: ["battle_id"]
            isOneToOne: false
            referencedRelation: "combat_battles"
            referencedColumns: ["id"]
          },
        ]
      }
      dashboard_widgets: {
        Row: {
          config: Json
          created_at: string
          height: number
          id: string
          name: string
          opacity: number
          player_id: string
          updated_at: string
          visible: boolean
          widget_type: string
          width: number
          x: number
          y: number
          z_index: number
        }
        Insert: {
          config?: Json
          created_at?: string
          height?: number
          id?: string
          name?: string
          opacity?: number
          player_id: string
          updated_at?: string
          visible?: boolean
          widget_type: string
          width?: number
          x?: number
          y?: number
          z_index?: number
        }
        Update: {
          config?: Json
          created_at?: string
          height?: number
          id?: string
          name?: string
          opacity?: number
          player_id?: string
          updated_at?: string
          visible?: boolean
          widget_type?: string
          width?: number
          x?: number
          y?: number
          z_index?: number
        }
        Relationships: [
          {
            foreignKeyName: "dashboard_widgets_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      debris_fields: {
        Row: {
          created_at: string
          crystal: number
          galaxy: number
          id: string
          metal: number
          position: number
          system: number
          universe_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          crystal?: number
          galaxy: number
          id?: string
          metal?: number
          position: number
          system: number
          universe_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          crystal?: number
          galaxy?: number
          id?: string
          metal?: number
          position?: number
          system?: number
          universe_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "debris_fields_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: false
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      defense_definitions: {
        Row: {
          attack: number
          base_build_time: number
          created_at: string
          crystal_cost: number
          description: string | null
          deuterium_cost: number
          hull: number
          id: string
          metal_cost: number
          name: string
          shield: number
          slots_per_unit: number
          target_priority: number
        }
        Insert: {
          attack?: number
          base_build_time?: number
          created_at?: string
          crystal_cost?: number
          description?: string | null
          deuterium_cost?: number
          hull?: number
          id: string
          metal_cost?: number
          name: string
          shield?: number
          slots_per_unit?: number
          target_priority?: number
        }
        Update: {
          attack?: number
          base_build_time?: number
          created_at?: string
          crystal_cost?: number
          description?: string | null
          deuterium_cost?: number
          hull?: number
          id?: string
          metal_cost?: number
          name?: string
          shield?: number
          slots_per_unit?: number
          target_priority?: number
        }
        Relationships: []
      }
      defense_prerequisites: {
        Row: {
          building_id: string | null
          created_at: string
          defense_id: string
          id: string
          prerequisite_type: string
          required_level: number
          research_id: string | null
        }
        Insert: {
          building_id?: string | null
          created_at?: string
          defense_id: string
          id?: string
          prerequisite_type: string
          required_level: number
          research_id?: string | null
        }
        Update: {
          building_id?: string | null
          created_at?: string
          defense_id?: string
          id?: string
          prerequisite_type?: string
          required_level?: number
          research_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "defense_prerequisites_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "defense_prerequisites_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "defense_prerequisites_defense_id_fkey"
            columns: ["defense_id"]
            isOneToOne: false
            referencedRelation: "defense_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "defense_prerequisites_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["research_id"]
          },
          {
            foreignKeyName: "defense_prerequisites_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      defense_queue: {
        Row: {
          created_at: string
          defense_id: string
          finishes_at: string
          id: string
          planet_id: string
          quantity: number
          started_at: string
          status: string
        }
        Insert: {
          created_at?: string
          defense_id: string
          finishes_at: string
          id?: string
          planet_id: string
          quantity: number
          started_at?: string
          status?: string
        }
        Update: {
          created_at?: string
          defense_id?: string
          finishes_at?: string
          id?: string
          planet_id?: string
          quantity?: number
          started_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "defense_queue_defense_id_fkey"
            columns: ["defense_id"]
            isOneToOne: false
            referencedRelation: "defense_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "defense_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "defense_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "defense_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      early_tester_registrations: {
        Row: {
          country_code: string
          created_at: string
          id: number
          ip_hash: string
          player_id: string
          tester_number: number
        }
        Insert: {
          country_code?: string
          created_at?: string
          id?: never
          ip_hash: string
          player_id: string
          tester_number: number
        }
        Update: {
          country_code?: string
          created_at?: string
          id?: never
          ip_hash?: string
          player_id?: string
          tester_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "early_tester_registrations_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      espionage_reports: {
        Row: {
          created_at: string
          crystal: number
          defenses: Json
          deuterium: number
          energy: number
          espionage_level: number
          fleet: Json
          fleet_id: string
          id: string
          metal: number
          player_id: string
          target_espionage_level: number
          target_planet_id: string
        }
        Insert: {
          created_at?: string
          crystal?: number
          defenses?: Json
          deuterium?: number
          energy?: number
          espionage_level?: number
          fleet?: Json
          fleet_id: string
          id?: string
          metal?: number
          player_id: string
          target_espionage_level?: number
          target_planet_id: string
        }
        Update: {
          created_at?: string
          crystal?: number
          defenses?: Json
          deuterium?: number
          energy?: number
          espionage_level?: number
          fleet?: Json
          fleet_id?: string
          id?: string
          metal?: number
          player_id?: string
          target_espionage_level?: number
          target_planet_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "espionage_reports_fleet_id_fkey"
            columns: ["fleet_id"]
            isOneToOne: true
            referencedRelation: "fleet_movements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "espionage_reports_target_planet_id_fkey"
            columns: ["target_planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "espionage_reports_target_planet_id_fkey"
            columns: ["target_planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "espionage_reports_target_planet_id_fkey"
            columns: ["target_planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      expedition_item_definitions: {
        Row: {
          active: boolean
          category: string
          created_at: string
          description: string
          duration_seconds: number
          effect_key: string
          effect_value: number
          id: string
          max_stacks: number
          name: string
        }
        Insert: {
          active?: boolean
          category: string
          created_at?: string
          description?: string
          duration_seconds?: number
          effect_key: string
          effect_value: number
          id: string
          max_stacks?: number
          name: string
        }
        Update: {
          active?: boolean
          category?: string
          created_at?: string
          description?: string
          duration_seconds?: number
          effect_key?: string
          effect_value?: number
          id?: string
          max_stacks?: number
          name?: string
        }
        Relationships: []
      }
      expedition_item_uses: {
        Row: {
          effect_snapshot: Json
          id: string
          item_id: string
          planet_id: string | null
          player_id: string
          quantity: number
          used_at: string
        }
        Insert: {
          effect_snapshot?: Json
          id?: string
          item_id: string
          planet_id?: string | null
          player_id: string
          quantity: number
          used_at?: string
        }
        Update: {
          effect_snapshot?: Json
          id?: string
          item_id?: string
          planet_id?: string | null
          player_id?: string
          quantity?: number
          used_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expedition_item_uses_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "expedition_item_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expedition_item_uses_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "expedition_item_uses_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expedition_item_uses_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "expedition_item_uses_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      expedition_resource_caps: {
        Row: {
          created_at: string
          id: number
          max_resource_find: number
          max_top1_points: number | null
          min_top1_points: number
        }
        Insert: {
          created_at?: string
          id?: never
          max_resource_find: number
          max_top1_points?: number | null
          min_top1_points: number
        }
        Update: {
          created_at?: string
          id?: never
          max_resource_find?: number
          max_top1_points?: number | null
          min_top1_points?: number
        }
        Relationships: []
      }
      expedition_results: {
        Row: {
          battle_id: string | null
          cargo_capacity: number
          created_at: string
          crystal: number
          dark_matter: number
          delay_seconds: number
          deuterium: number
          enemy_ships: Json
          event_type: string | null
          fleet_id: string
          hold_seconds: number
          id: string
          item_id: string | null
          item_quantity: number
          loss_percentage: number
          lost_ships: Json
          max_resource_find: number
          merchant_crystal_rate: number | null
          merchant_deuterium_rate: number | null
          merchant_metal_rate: number | null
          merchant_resource: string | null
          metal: number
          outcome: string
          player_id: string
          random_roll: number | null
          resolved_at: string
          reward_level: string | null
          reward_multiplier: number
          reward_tier: string | null
          scaled_resource_find: number
          ships: Json
          speedup_seconds: number
          weight_total: number | null
        }
        Insert: {
          battle_id?: string | null
          cargo_capacity?: number
          created_at?: string
          crystal?: number
          dark_matter?: number
          delay_seconds?: number
          deuterium?: number
          enemy_ships?: Json
          event_type?: string | null
          fleet_id: string
          hold_seconds?: number
          id?: string
          item_id?: string | null
          item_quantity?: number
          loss_percentage?: number
          lost_ships?: Json
          max_resource_find?: number
          merchant_crystal_rate?: number | null
          merchant_deuterium_rate?: number | null
          merchant_metal_rate?: number | null
          merchant_resource?: string | null
          metal?: number
          outcome: string
          player_id: string
          random_roll?: number | null
          resolved_at?: string
          reward_level?: string | null
          reward_multiplier?: number
          reward_tier?: string | null
          scaled_resource_find?: number
          ships?: Json
          speedup_seconds?: number
          weight_total?: number | null
        }
        Update: {
          battle_id?: string | null
          cargo_capacity?: number
          created_at?: string
          crystal?: number
          dark_matter?: number
          delay_seconds?: number
          deuterium?: number
          enemy_ships?: Json
          event_type?: string | null
          fleet_id?: string
          hold_seconds?: number
          id?: string
          item_id?: string | null
          item_quantity?: number
          loss_percentage?: number
          lost_ships?: Json
          max_resource_find?: number
          merchant_crystal_rate?: number | null
          merchant_deuterium_rate?: number | null
          merchant_metal_rate?: number | null
          merchant_resource?: string | null
          metal?: number
          outcome?: string
          player_id?: string
          random_roll?: number | null
          resolved_at?: string
          reward_level?: string | null
          reward_multiplier?: number
          reward_tier?: string | null
          scaled_resource_find?: number
          ships?: Json
          speedup_seconds?: number
          weight_total?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "expedition_results_fleet_id_fkey"
            columns: ["fleet_id"]
            isOneToOne: true
            referencedRelation: "fleet_movements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expedition_results_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "expedition_item_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      expedition_reward_budgets: {
        Row: {
          base_resource_find: number | null
          cargo_capacity: number
          created_at: string
          expedition_points: number
          final_resource_amount: number | null
          fleet_id: string
          id: string
          max_resource_find: number | null
          max_ship_find: number
          resource_cap: number
          resource_type: string | null
          reward_multiplier: number
          reward_tier: string
          scaled_resource_find: number | null
          scaled_ship_find: number
          ship_reward: Json
        }
        Insert: {
          base_resource_find?: number | null
          cargo_capacity: number
          created_at?: string
          expedition_points: number
          final_resource_amount?: number | null
          fleet_id: string
          id?: string
          max_resource_find?: number | null
          max_ship_find?: number
          resource_cap: number
          resource_type?: string | null
          reward_multiplier: number
          reward_tier: string
          scaled_resource_find?: number | null
          scaled_ship_find?: number
          ship_reward?: Json
        }
        Update: {
          base_resource_find?: number | null
          cargo_capacity?: number
          created_at?: string
          expedition_points?: number
          final_resource_amount?: number | null
          fleet_id?: string
          id?: string
          max_resource_find?: number | null
          max_ship_find?: number
          resource_cap?: number
          resource_type?: string | null
          reward_multiplier?: number
          reward_tier?: string
          scaled_resource_find?: number | null
          scaled_ship_find?: number
          ship_reward?: Json
        }
        Relationships: [
          {
            foreignKeyName: "expedition_reward_budgets_fleet_id_fkey"
            columns: ["fleet_id"]
            isOneToOne: true
            referencedRelation: "fleet_movements"
            referencedColumns: ["id"]
          },
        ]
      }
      expedition_settings: {
        Row: {
          bonus_expedition_slots: number
          created_at: string
          reward_multiplier_dark_matter: number
          reward_multiplier_items: number
          reward_multiplier_resources: number
          reward_multiplier_ships: number
          universe_id: string
          updated_at: string
          weight_aliens: number
          weight_black_hole: number
          weight_dark_matter: number
          weight_delay: number
          weight_items: number
          weight_merchant: number
          weight_nothing: number
          weight_pirates: number
          weight_resources: number
          weight_ships: number
          weight_speedup: number
        }
        Insert: {
          bonus_expedition_slots?: number
          created_at?: string
          reward_multiplier_dark_matter?: number
          reward_multiplier_items?: number
          reward_multiplier_resources?: number
          reward_multiplier_ships?: number
          universe_id: string
          updated_at?: string
          weight_aliens?: number
          weight_black_hole?: number
          weight_dark_matter?: number
          weight_delay?: number
          weight_items?: number
          weight_merchant?: number
          weight_nothing?: number
          weight_pirates?: number
          weight_resources?: number
          weight_ships?: number
          weight_speedup?: number
        }
        Update: {
          bonus_expedition_slots?: number
          created_at?: string
          reward_multiplier_dark_matter?: number
          reward_multiplier_items?: number
          reward_multiplier_resources?: number
          reward_multiplier_ships?: number
          universe_id?: string
          updated_at?: string
          weight_aliens?: number
          weight_black_hole?: number
          weight_dark_matter?: number
          weight_delay?: number
          weight_items?: number
          weight_merchant?: number
          weight_nothing?: number
          weight_pirates?: number
          weight_resources?: number
          weight_ships?: number
          weight_speedup?: number
        }
        Relationships: [
          {
            foreignKeyName: "expedition_settings_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: true
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      expedition_ship_tiers: {
        Row: {
          ship_id: string
          tier: number
        }
        Insert: {
          ship_id: string
          tier: number
        }
        Update: {
          ship_id?: string
          tier?: number
        }
        Relationships: [
          {
            foreignKeyName: "expedition_ship_tiers_ship_id_fkey"
            columns: ["ship_id"]
            isOneToOne: true
            referencedRelation: "ship_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      fleet_movement_ships: {
        Row: {
          fleet_id: string
          id: string
          quantity: number
          ship_id: string
        }
        Insert: {
          fleet_id: string
          id?: string
          quantity: number
          ship_id: string
        }
        Update: {
          fleet_id?: string
          id?: string
          quantity?: number
          ship_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fleet_movement_ships_fleet_id_fkey"
            columns: ["fleet_id"]
            isOneToOne: false
            referencedRelation: "fleet_movements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fleet_movement_ships_ship_id_fkey"
            columns: ["ship_id"]
            isOneToOne: false
            referencedRelation: "ship_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      fleet_movements: {
        Row: {
          arrives_at: string
          created_at: string
          crystal: number
          destination_galaxy: number | null
          destination_planet_id: string | null
          destination_position: number | null
          destination_system: number | null
          deuterium: number
          expedition_hold_seconds: number
          fuel_consumed: number
          holding_until: string | null
          id: string
          idempotency_key: string | null
          metal: number
          missile_count: number
          mission_type: string
          origin_planet_id: string
          player_id: string
          returns_at: string | null
          started_at: string
          status: string
          target_priority: number
        }
        Insert: {
          arrives_at: string
          created_at?: string
          crystal?: number
          destination_galaxy?: number | null
          destination_planet_id?: string | null
          destination_position?: number | null
          destination_system?: number | null
          deuterium?: number
          expedition_hold_seconds?: number
          fuel_consumed?: number
          holding_until?: string | null
          id?: string
          idempotency_key?: string | null
          metal?: number
          mission_type: string
          origin_planet_id: string
          player_id: string
          returns_at?: string | null
          started_at?: string
          status?: string
        }
        Update: {
          arrives_at?: string
          created_at?: string
          crystal?: number
          destination_galaxy?: number | null
          destination_planet_id?: string | null
          destination_position?: number | null
          destination_system?: number | null
          deuterium?: number
          expedition_hold_seconds?: number
          fuel_consumed?: number
          holding_until?: string | null
          id?: string
          idempotency_key?: string | null
          metal?: number
          mission_type?: string
          origin_planet_id?: string
          player_id?: string
          returns_at?: string | null
          started_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "fleet_movements_destination_planet_id_fkey"
            columns: ["destination_planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "fleet_movements_destination_planet_id_fkey"
            columns: ["destination_planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fleet_movements_destination_planet_id_fkey"
            columns: ["destination_planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "fleet_movements_origin_planet_id_fkey"
            columns: ["origin_planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "fleet_movements_origin_planet_id_fkey"
            columns: ["origin_planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fleet_movements_origin_planet_id_fkey"
            columns: ["origin_planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "fleet_movements_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      lifeform_building_definitions: {
        Row: {
          base_build_time_seconds: number
          base_crystal: number
          base_deuterium: number
          base_metal: number
          cost_factor: number
          description: string
          effect_key: string | null
          effect_value: number
          id: string
          lifeform_id: string
          max_level: number
          name: string
          slot: number
          time_factor: number
        }
        Insert: {
          base_build_time_seconds?: number
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          cost_factor?: number
          description?: string
          effect_key?: string | null
          effect_value?: number
          id: string
          lifeform_id: string
          max_level?: number
          name: string
          slot: number
          time_factor?: number
        }
        Update: {
          base_build_time_seconds?: number
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          cost_factor?: number
          description?: string
          effect_key?: string | null
          effect_value?: number
          id?: string
          lifeform_id?: string
          max_level?: number
          name?: string
          slot?: number
          time_factor?: number
        }
        Relationships: [
          {
            foreignKeyName: "lifeform_building_definitions_lifeform_id_fkey"
            columns: ["lifeform_id"]
            isOneToOne: false
            referencedRelation: "lifeform_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      lifeform_building_queue: {
        Row: {
          building_id: string
          created_at: string
          finishes_at: string
          id: string
          planet_id: string
          started_at: string
          status: string
          target_level: number
        }
        Insert: {
          building_id: string
          created_at?: string
          finishes_at?: string
          id?: string
          planet_id: string
          started_at?: string
          status?: string
          target_level: number
        }
        Update: {
          building_id?: string
          created_at?: string
          finishes_at?: string
          id?: string
          planet_id?: string
          started_at?: string
          status?: string
          target_level?: number
        }
        Relationships: [
          {
            foreignKeyName: "lifeform_building_queue_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "lifeform_building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lifeform_building_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "lifeform_building_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lifeform_building_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      lifeform_definitions: {
        Row: {
          created_at: string
          description: string
          discovered_by_default: boolean
          id: string
          name: string
        }
        Insert: {
          created_at?: string
          description?: string
          discovered_by_default?: boolean
          id: string
          name: string
        }
        Update: {
          created_at?: string
          description?: string
          discovered_by_default?: boolean
          id?: string
          name?: string
        }
        Relationships: []
      }
      lifeform_research_definitions: {
        Row: {
          base_crystal: number
          base_deuterium: number
          base_metal: number
          base_research_time_seconds: number
          cost_factor: number
          description: string
          effect_key: string | null
          effect_value: number
          id: string
          lifeform_id: string
          max_level: number
          name: string
          slot: number
          tier: number
          time_factor: number
        }
        Insert: {
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          base_research_time_seconds?: number
          cost_factor?: number
          description?: string
          effect_key?: string | null
          effect_value?: number
          id: string
          lifeform_id: string
          max_level?: number
          name: string
          slot: number
          tier: number
          time_factor?: number
        }
        Update: {
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          base_research_time_seconds?: number
          cost_factor?: number
          description?: string
          effect_key?: string | null
          effect_value?: number
          id?: string
          lifeform_id?: string
          max_level?: number
          name?: string
          slot?: number
          tier?: number
          time_factor?: number
        }
        Relationships: [
          {
            foreignKeyName: "lifeform_research_definitions_lifeform_id_fkey"
            columns: ["lifeform_id"]
            isOneToOne: false
            referencedRelation: "lifeform_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      lifeform_research_queue: {
        Row: {
          created_at: string
          finishes_at: string
          id: string
          planet_id: string
          research_id: string
          started_at: string
          status: string
          target_level: number
        }
        Insert: {
          created_at?: string
          finishes_at?: string
          id?: string
          planet_id: string
          research_id: string
          started_at?: string
          status?: string
          target_level: number
        }
        Update: {
          created_at?: string
          finishes_at?: string
          id?: string
          planet_id?: string
          research_id?: string
          started_at?: string
          status?: string
          target_level?: number
        }
        Relationships: [
          {
            foreignKeyName: "lifeform_research_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "lifeform_research_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "lifeform_research_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "lifeform_research_queue_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "lifeform_research_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      planet_buildings: {
        Row: {
          building_id: string
          level: number
          planet_id: string
        }
        Insert: {
          building_id: string
          level?: number
          planet_id: string
        }
        Update: {
          building_id?: string
          level?: number
          planet_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_buildings_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "planet_buildings_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_buildings_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_buildings_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_buildings_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      planet_defenses: {
        Row: {
          created_at: string
          defense_id: string
          id: string
          planet_id: string
          quantity: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          defense_id: string
          id?: string
          planet_id: string
          quantity?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          defense_id?: string
          id?: string
          planet_id?: string
          quantity?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_defenses_defense_id_fkey"
            columns: ["defense_id"]
            isOneToOne: false
            referencedRelation: "defense_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_defenses_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_defenses_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_defenses_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      planet_lifeform_buildings: {
        Row: {
          building_id: string
          level: number
          planet_id: string
          updated_at: string
        }
        Insert: {
          building_id: string
          level?: number
          planet_id: string
          updated_at?: string
        }
        Update: {
          building_id?: string
          level?: number
          planet_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_lifeform_buildings_building_id_fkey"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "lifeform_building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_lifeform_buildings_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_lifeform_buildings_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_lifeform_buildings_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      planet_lifeform_research: {
        Row: {
          level: number
          planet_id: string
          research_id: string
          slot: number
          updated_at: string
        }
        Insert: {
          level?: number
          planet_id: string
          research_id: string
          slot: number
          updated_at?: string
        }
        Update: {
          level?: number
          planet_id?: string
          research_id?: string
          slot?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_lifeform_research_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_lifeform_research_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_lifeform_research_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_lifeform_research_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "lifeform_research_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      planet_lifeforms: {
        Row: {
          active: boolean
          discovered_at: string
          experience: number
          food: number
          last_population_tick_at: string
          lifeform_id: string
          lifeform_level: number
          planet_id: string
          population_t1: number
          population_t2: number
          population_t3: number
          updated_at: string
        }
        Insert: {
          active?: boolean
          discovered_at?: string
          experience?: number
          food?: number
          last_population_tick_at?: string
          lifeform_id: string
          lifeform_level?: number
          planet_id: string
          population_t1?: number
          population_t2?: number
          population_t3?: number
          updated_at?: string
        }
        Update: {
          active?: boolean
          discovered_at?: string
          experience?: number
          food?: number
          last_population_tick_at?: string
          lifeform_id?: string
          lifeform_level?: number
          planet_id?: string
          population_t1?: number
          population_t2?: number
          population_t3?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_lifeforms_lifeform_id_fkey"
            columns: ["lifeform_id"]
            isOneToOne: false
            referencedRelation: "lifeform_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_lifeforms_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: true
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_lifeforms_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: true
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_lifeforms_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: true
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      planet_resources: {
        Row: {
          crystal: number
          deuterium: number
          energy: number
          last_calculated_at: string
          metal: number
          planet_id: string
          updated_at: string
        }
        Insert: {
          crystal?: number
          deuterium?: number
          energy?: number
          last_calculated_at?: string
          metal?: number
          planet_id: string
          updated_at?: string
        }
        Update: {
          crystal?: number
          deuterium?: number
          energy?: number
          last_calculated_at?: string
          metal?: number
          planet_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_resources_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: true
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_resources_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: true
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_resources_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: true
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
        ]
      }
      planet_ships: {
        Row: {
          planet_id: string
          quantity: number
          ship_id: string
        }
        Insert: {
          planet_id: string
          quantity?: number
          ship_id: string
        }
        Update: {
          planet_id?: string
          quantity?: number
          ship_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "planet_ships_planet_fk"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_ships_planet_fk"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planet_ships_planet_fk"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "planet_ships_ship_fk"
            columns: ["ship_id"]
            isOneToOne: false
            referencedRelation: "ship_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      planets: {
        Row: {
          created_at: string
          fields_total: number
          fields_used: number
          galaxy: number
          id: string
          is_destroyed: boolean
          is_homeworld: boolean
          jump_gate_cooldown_until: string | null
          kind: string
          moon_diameter_km: number | null
          name: string
          parent_planet_id: string | null
          player_id: string | null
          position: number
          system: number
          temperature_max: number | null
          temperature_min: number | null
          universe_id: string
        }
        Insert: {
          created_at?: string
          fields_total?: number
          fields_used?: number
          galaxy: number
          id?: string
          is_destroyed?: boolean
          is_homeworld?: boolean
          jump_gate_cooldown_until?: string | null
          kind?: string
          moon_diameter_km?: number | null
          name?: string
          parent_planet_id?: string | null
          player_id?: string | null
          position: number
          system: number
          temperature_max?: number | null
          temperature_min?: number | null
          universe_id: string
        }
        Update: {
          created_at?: string
          fields_total?: number
          fields_used?: number
          galaxy?: number
          id?: string
          is_destroyed?: boolean
          is_homeworld?: boolean
          jump_gate_cooldown_until?: string | null
          kind?: string
          moon_diameter_km?: number | null
          name?: string
          parent_planet_id?: string | null
          player_id?: string | null
          position?: number
          system?: number
          temperature_max?: number | null
          temperature_min?: number | null
          universe_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "planets_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planets_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: false
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      player_achievements: {
        Row: {
          achievement_id: string
          metadata: Json
          player_id: string
          unlocked_at: string
        }
        Insert: {
          achievement_id: string
          metadata?: Json
          player_id: string
          unlocked_at?: string
        }
        Update: {
          achievement_id?: string
          metadata?: Json
          player_id?: string
          unlocked_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_achievements_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_expedition_items: {
        Row: {
          acquired_at: string
          active: boolean
          expires_at: string | null
          id: string
          item_id: string
          metadata: Json
          player_id: string
          quantity: number
        }
        Insert: {
          acquired_at?: string
          active?: boolean
          expires_at?: string | null
          id?: string
          item_id: string
          metadata?: Json
          player_id: string
          quantity?: number
        }
        Update: {
          acquired_at?: string
          active?: boolean
          expires_at?: string | null
          id?: string
          item_id?: string
          metadata?: Json
          player_id?: string
          quantity?: number
        }
        Relationships: [
          {
            foreignKeyName: "player_expedition_items_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "expedition_item_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "player_expedition_items_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_expedition_merchants: {
        Row: {
          active: boolean
          created_at: string
          crystal_rate: number
          deuterium_rate: number
          metal_rate: number
          player_id: string
          resource: string
          source: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          crystal_rate: number
          deuterium_rate: number
          metal_rate: number
          player_id: string
          resource: string
          source?: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          crystal_rate?: number
          deuterium_rate?: number
          metal_rate?: number
          player_id?: string
          resource?: string
          source?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_expedition_merchants_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: true
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_expedition_modifiers: {
        Row: {
          class_id: string
          created_at: string
          dark_matter_multiplier: number
          player_id: string
          resource_multiplier: number
          ship_multiplier: number
          updated_at: string
        }
        Insert: {
          class_id?: string
          created_at?: string
          dark_matter_multiplier?: number
          player_id: string
          resource_multiplier?: number
          ship_multiplier?: number
          updated_at?: string
        }
        Update: {
          class_id?: string
          created_at?: string
          dark_matter_multiplier?: number
          player_id?: string
          resource_multiplier?: number
          ship_multiplier?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_expedition_modifiers_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: true
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_lifeform_discoveries: {
        Row: {
          discovered: boolean
          discovered_at: string
          experience: number
          level: number
          lifeform_id: string
          player_id: string
          updated_at: string
        }
        Insert: {
          discovered?: boolean
          discovered_at?: string
          experience?: number
          level?: number
          lifeform_id: string
          player_id: string
          updated_at?: string
        }
        Update: {
          discovered?: boolean
          discovered_at?: string
          experience?: number
          level?: number
          lifeform_id?: string
          player_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_lifeform_discoveries_lifeform_id_fkey"
            columns: ["lifeform_id"]
            isOneToOne: false
            referencedRelation: "lifeform_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "player_lifeform_discoveries_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_messages: {
        Row: {
          body: string
          created_at: string
          id: string
          read_at: string | null
          recipient_player_id: string
          sender_player_id: string | null
          subject: string
        }
        Insert: {
          body?: string
          created_at?: string
          id?: string
          read_at?: string | null
          recipient_player_id: string
          sender_player_id?: string | null
          subject?: string
        }
        Update: {
          body?: string
          created_at?: string
          id?: string
          read_at?: string | null
          recipient_player_id?: string
          sender_player_id?: string | null
          subject?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_messages_recipient_player_id_fkey"
            columns: ["recipient_player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "player_messages_sender_player_id_fkey"
            columns: ["sender_player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_notes: {
        Row: {
          content: string
          player_id: string
          updated_at: string
        }
        Insert: {
          content?: string
          player_id: string
          updated_at?: string
        }
        Update: {
          content?: string
          player_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_notes_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: true
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      player_research: {
        Row: {
          level: number
          player_id: string
          research_id: string
        }
        Insert: {
          level?: number
          player_id: string
          research_id: string
        }
        Update: {
          level?: number
          player_id?: string
          research_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "player_research_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "player_research_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["research_id"]
          },
          {
            foreignKeyName: "player_research_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      players: {
        Row: {
          created_at: string
          dark_matter: number
          id: string
          is_guest: boolean
          last_activity_at: string
          player_type: string
          points: number
          rank: number | null
          universe_id: string
          user_id: string | null
          username: string
        }
        Insert: {
          created_at?: string
          dark_matter?: number
          id?: string
          is_guest?: boolean
          last_activity_at?: string
          player_type?: string
          points?: number
          rank?: number | null
          universe_id: string
          user_id?: string | null
          username: string
        }
        Update: {
          created_at?: string
          dark_matter?: number
          id?: string
          is_guest?: boolean
          last_activity_at?: string
          player_type?: string
          points?: number
          rank?: number | null
          universe_id?: string
          user_id?: string | null
          username?: string
        }
        Relationships: [
          {
            foreignKeyName: "players_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: false
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      research_definitions: {
        Row: {
          base_crystal: number
          base_deuterium: number
          base_metal: number
          base_research_time_seconds: number
          cost_factor: number
          created_at: string
          description: string | null
          id: string
          max_level: number | null
          name: string
          time_factor: number | null
        }
        Insert: {
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          base_research_time_seconds?: number
          cost_factor?: number
          created_at?: string
          description?: string | null
          id: string
          max_level?: number | null
          name: string
          time_factor?: number | null
        }
        Update: {
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          base_research_time_seconds?: number
          cost_factor?: number
          created_at?: string
          description?: string | null
          id?: string
          max_level?: number | null
          name?: string
          time_factor?: number | null
        }
        Relationships: []
      }
      research_prerequisites: {
        Row: {
          prerequisite_research_id: string
          required_level: number
          research_id: string
        }
        Insert: {
          prerequisite_research_id: string
          required_level: number
          research_id: string
        }
        Update: {
          prerequisite_research_id?: string
          required_level?: number
          research_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "research_prerequisites_required_research_fkey"
            columns: ["prerequisite_research_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["research_id"]
          },
          {
            foreignKeyName: "research_prerequisites_required_research_fkey"
            columns: ["prerequisite_research_id"]
            isOneToOne: false
            referencedRelation: "research_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "research_prerequisites_research_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["research_id"]
          },
          {
            foreignKeyName: "research_prerequisites_research_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      research_queue: {
        Row: {
          created_at: string
          finishes_at: string
          id: string
          planet_id: string | null
          player_id: string
          research_id: string
          started_at: string
          status: string
          target_level: number
        }
        Insert: {
          created_at?: string
          finishes_at: string
          id?: string
          planet_id?: string | null
          player_id: string
          research_id: string
          started_at: string
          status?: string
          target_level: number
        }
        Update: {
          created_at?: string
          finishes_at?: string
          id?: string
          planet_id?: string | null
          player_id?: string
          research_id?: string
          started_at?: string
          status?: string
          target_level?: number
        }
        Relationships: [
          {
            foreignKeyName: "research_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "research_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "research_queue_planet_id_fkey"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "research_queue_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "research_queue_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["research_id"]
          },
          {
            foreignKeyName: "research_queue_research_id_fkey"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      ship_definitions: {
        Row: {
          attack: number
          base_build_time_seconds: number
          base_crystal: number
          base_deuterium: number
          base_metal: number
          cargo_capacity: number
          created_at: string
          description: string | null
          fuel_consumption: number
          hull: number
          id: string
          name: string
          shield: number
          ship_type: string
          speed: number
          valid_kinds: string[]
        }
        Insert: {
          attack?: number
          base_build_time_seconds?: number
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          cargo_capacity?: number
          created_at?: string
          description?: string | null
          fuel_consumption?: number
          hull?: number
          id: string
          name: string
          shield?: number
          ship_type: string
          speed?: number
          valid_kinds?: string[]
        }
        Update: {
          attack?: number
          base_build_time_seconds?: number
          base_crystal?: number
          base_deuterium?: number
          base_metal?: number
          cargo_capacity?: number
          created_at?: string
          description?: string | null
          fuel_consumption?: number
          hull?: number
          id?: string
          name?: string
          shield?: number
          ship_type?: string
          speed?: number
          valid_kinds?: string[]
        }
        Relationships: []
      }
      ship_prerequisites: {
        Row: {
          building_id: string | null
          created_at: string
          id: string
          prerequisite_type: string
          required_level: number
          research_id: string | null
          ship_id: string
        }
        Insert: {
          building_id?: string | null
          created_at?: string
          id?: string
          prerequisite_type: string
          required_level?: number
          research_id?: string | null
          ship_id: string
        }
        Update: {
          building_id?: string | null
          created_at?: string
          id?: string
          prerequisite_type?: string
          required_level?: number
          research_id?: string | null
          ship_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ship_prerequisites_building_fk"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["building_id"]
          },
          {
            foreignKeyName: "ship_prerequisites_building_fk"
            columns: ["building_id"]
            isOneToOne: false
            referencedRelation: "building_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ship_prerequisites_research_fk"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["research_id"]
          },
          {
            foreignKeyName: "ship_prerequisites_research_fk"
            columns: ["research_id"]
            isOneToOne: false
            referencedRelation: "research_definitions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ship_prerequisites_ship_fk"
            columns: ["ship_id"]
            isOneToOne: false
            referencedRelation: "ship_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      shipyard_queue: {
        Row: {
          created_at: string
          finishes_at: string
          id: string
          planet_id: string
          quantity: number
          ship_id: string
          started_at: string
          status: string
        }
        Insert: {
          created_at?: string
          finishes_at: string
          id?: string
          planet_id: string
          quantity: number
          ship_id: string
          started_at?: string
          status?: string
        }
        Update: {
          created_at?: string
          finishes_at?: string
          id?: string
          planet_id?: string
          quantity?: number
          ship_id?: string
          started_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipyard_queue_planet_fk"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "building_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "shipyard_queue_planet_fk"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "planets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipyard_queue_planet_fk"
            columns: ["planet_id"]
            isOneToOne: false
            referencedRelation: "research_action_candidates"
            referencedColumns: ["planet_id"]
          },
          {
            foreignKeyName: "shipyard_queue_ship_fk"
            columns: ["ship_id"]
            isOneToOne: false
            referencedRelation: "ship_definitions"
            referencedColumns: ["id"]
          },
        ]
      }
      universe_clock: {
        Row: {
          is_processing: boolean
          last_tick_at: string
          next_tick_at: string
          tick_interval_seconds: number
          universe_id: string
          updated_at: string
        }
        Insert: {
          is_processing?: boolean
          last_tick_at?: string
          next_tick_at?: string
          tick_interval_seconds?: number
          universe_id: string
          updated_at?: string
        }
        Update: {
          is_processing?: boolean
          last_tick_at?: string
          next_tick_at?: string
          tick_interval_seconds?: number
          universe_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "universe_clock_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: true
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      universe_expansion_state: {
        Row: {
          galaxy_roll_interval_seconds: number
          galaxy_roll_probability: number
          initial_special_galaxy_systems: number
          next_galaxy_roll_at: string
          special_galaxy_base_interval_seconds: number
          special_galaxy_interval_growth_factor: number
          universe_id: string
          updated_at: string
        }
        Insert: {
          galaxy_roll_interval_seconds?: number
          galaxy_roll_probability?: number
          initial_special_galaxy_systems?: number
          next_galaxy_roll_at: string
          special_galaxy_base_interval_seconds?: number
          special_galaxy_interval_growth_factor?: number
          universe_id: string
          updated_at?: string
        }
        Update: {
          galaxy_roll_interval_seconds?: number
          galaxy_roll_probability?: number
          initial_special_galaxy_systems?: number
          next_galaxy_roll_at?: string
          special_galaxy_base_interval_seconds?: number
          special_galaxy_interval_growth_factor?: number
          universe_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "universe_expansion_state_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: true
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      universe_galaxies: {
        Row: {
          created_at: string
          galaxy: number
          is_special: boolean
          next_system_expansion_at: string
          system_count: number
          system_interval_growth_factor: number
          system_interval_seconds: number
          universe_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          galaxy: number
          is_special?: boolean
          next_system_expansion_at: string
          system_count?: number
          system_interval_growth_factor?: number
          system_interval_seconds: number
          universe_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          galaxy?: number
          is_special?: boolean
          next_system_expansion_at?: string
          system_count?: number
          system_interval_growth_factor?: number
          system_interval_seconds?: number
          universe_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "universe_galaxies_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: false
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      universe_population_state: {
        Row: {
          ai_density_target: number
          ai_density_tolerance: number
          ai_generation_batch: number
          ai_planets_count: number
          next_reconciliation_at: string
          reconciliation_interval_seconds: number
          universe_id: string
          unlocked_positions: number
          unlocked_systems: number
          updated_at: string
        }
        Insert: {
          ai_density_target?: number
          ai_density_tolerance?: number
          ai_generation_batch?: number
          ai_planets_count?: number
          next_reconciliation_at?: string
          reconciliation_interval_seconds?: number
          universe_id: string
          unlocked_positions?: number
          unlocked_systems?: number
          updated_at?: string
        }
        Update: {
          ai_density_target?: number
          ai_density_tolerance?: number
          ai_generation_batch?: number
          ai_planets_count?: number
          next_reconciliation_at?: string
          reconciliation_interval_seconds?: number
          universe_id?: string
          unlocked_positions?: number
          unlocked_systems?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "universe_population_state_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: true
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      universe_process_health: {
        Row: {
          consecutive_failures: number
          last_error: string | null
          last_failure_at: string | null
          last_success_at: string | null
          last_systems_expanded: number
          last_ticks_executed: number
          universe_id: string
          updated_at: string
        }
        Insert: {
          consecutive_failures?: number
          last_error?: string | null
          last_failure_at?: string | null
          last_success_at?: string | null
          last_systems_expanded?: number
          last_ticks_executed?: number
          universe_id: string
          updated_at?: string
        }
        Update: {
          consecutive_failures?: number
          last_error?: string | null
          last_failure_at?: string | null
          last_success_at?: string | null
          last_systems_expanded?: number
          last_ticks_executed?: number
          universe_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "universe_process_health_universe_id_fkey"
            columns: ["universe_id"]
            isOneToOne: true
            referencedRelation: "universes"
            referencedColumns: ["id"]
          },
        ]
      }
      universes: {
        Row: {
          ai_planet_density_target: number
          ai_planet_density_tolerance: number
          building_speed: number
          created_at: string
          defense_debris_percentage: number
          description: string | null
          economy_speed: number
          expedition_speed: number
          fleet_debris_percentage: number
          fleet_speed: number
          galaxy_roll_interval_seconds: number
          galaxy_roll_probability: number
          id: string
          initial_galaxies: number
          initial_systems_per_galaxy: number
          is_active: boolean
          lifeform_speed: number
          name: string
          production_speed: number
          research_speed: number
          resource_multiplier: number
          special_galaxy_base_seconds: number
          special_galaxy_growth_factor: number
          special_galaxy_initial_systems: number
          storage_multiplier: number
          system_expansion_base_seconds: number
          system_expansion_curve_exponent: number
        }
        Insert: {
          ai_planet_density_target?: number
          ai_planet_density_tolerance?: number
          building_speed?: number
          created_at?: string
          defense_debris_percentage?: number
          description?: string | null
          economy_speed?: number
          expedition_speed?: number
          fleet_debris_percentage?: number
          fleet_speed?: number
          galaxy_roll_interval_seconds?: number
          galaxy_roll_probability?: number
          id?: string
          initial_galaxies?: number
          initial_systems_per_galaxy?: number
          is_active?: boolean
          lifeform_speed?: number
          name: string
          production_speed?: number
          research_speed?: number
          resource_multiplier?: number
          special_galaxy_base_seconds?: number
          special_galaxy_growth_factor?: number
          special_galaxy_initial_systems?: number
          storage_multiplier?: number
          system_expansion_base_seconds?: number
          system_expansion_curve_exponent?: number
        }
        Update: {
          ai_planet_density_target?: number
          ai_planet_density_tolerance?: number
          building_speed?: number
          created_at?: string
          defense_debris_percentage?: number
          description?: string | null
          economy_speed?: number
          expedition_speed?: number
          fleet_debris_percentage?: number
          fleet_speed?: number
          galaxy_roll_interval_seconds?: number
          galaxy_roll_probability?: number
          id?: string
          initial_galaxies?: number
          initial_systems_per_galaxy?: number
          is_active?: boolean
          lifeform_speed?: number
          name?: string
          production_speed?: number
          research_speed?: number
          resource_multiplier?: number
          special_galaxy_base_seconds?: number
          special_galaxy_growth_factor?: number
          special_galaxy_initial_systems?: number
          storage_multiplier?: number
          system_expansion_base_seconds?: number
          system_expansion_curve_exponent?: number
        }
        Relationships: []
      }
    }
    Views: {
      action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          available_crystal: number | null
          available_deuterium: number | null
          available_metal: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          planet_id: string | null
          planet_name: string | null
          prerequisites_met: boolean | null
          resources_available: boolean | null
          target_level: number | null
        }
        Relationships: []
      }
      action_economic_evaluation: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_energy_balance_per_hour: number | null
          current_energy_consumption_per_hour: number | null
          current_energy_production_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          energy_delta_per_hour: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          projected_energy_balance_per_hour: number | null
          target_level: number | null
        }
        Relationships: []
      }
      action_energy_evaluation: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_energy_balance_per_hour: number | null
          current_energy_consumption_per_hour: number | null
          current_energy_production_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          energy_delta_per_hour: number | null
          energy_effect: string | null
          energy_feasible: boolean | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          projected_energy_balance_per_hour: number | null
          target_level: number | null
        }
        Relationships: []
      }
      building_action_candidates: {
        Row: {
          active_building_jobs: number | null
          available_crystal: number | null
          available_deuterium: number | null
          available_metal: number | null
          build_time_seconds: number | null
          building_id: string | null
          building_name: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          galaxy: number | null
          planet_id: string | null
          planet_name: string | null
          position: number | null
          resources_available: boolean | null
          system: number | null
          target_level: number | null
        }
        Relationships: []
      }
      economic_action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          energy_delta_per_hour: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          target_level: number | null
        }
        Relationships: []
      }
      empire_action_ranking: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          empire_rank: number | null
          energy_feasible: boolean | null
          executable_now: boolean | null
          execution_status: string | null
          optimization_score: number | null
          payback_minutes: number | null
          planet_id: string | null
          planet_name: string | null
          planet_rank: number | null
          prerequisites_met: boolean | null
          resources_available: boolean | null
          target_level: number | null
        }
        Relationships: []
      }
      empire_economic_monitor: {
        Row: {
          planet_count: number | null
          player_id: string | null
          total_crystal: number | null
          total_crystal_per_hour: number | null
          total_deuterium: number | null
          total_deuterium_per_hour: number | null
          total_energy: number | null
          total_energy_per_hour: number | null
          total_metal: number | null
          total_metal_per_hour: number | null
        }
        Relationships: [
          {
            foreignKeyName: "planets_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      empire_energy_monitor: {
        Row: {
          player_id: string | null
          total_energy_balance_per_hour: number | null
          total_energy_consumption_per_hour: number | null
          total_energy_production_per_hour: number | null
        }
        Relationships: [
          {
            foreignKeyName: "planets_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      empire_next_action: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          execution_status: string | null
          optimization_score: number | null
          payback_minutes: number | null
          planet_id: string | null
          planet_name: string | null
          target_level: number | null
        }
        Relationships: []
      }
      executable_action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          available_crystal: number | null
          available_deuterium: number | null
          available_metal: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          planet_id: string | null
          planet_name: string | null
          prerequisites_met: boolean | null
          resources_available: boolean | null
          target_level: number | null
        }
        Relationships: []
      }
      executable_optimization_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_energy_balance_per_hour: number | null
          current_energy_consumption_per_hour: number | null
          current_energy_production_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          economic_score: number | null
          economic_score_normalized: number | null
          energy_delta_per_hour: number | null
          energy_effect: string | null
          energy_feasible: boolean | null
          energy_generation_score: number | null
          energy_score_normalized: number | null
          executable_now: boolean | null
          execution_status: string | null
          feasibility_score: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          optimization_score: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          prerequisites_met: boolean | null
          projected_energy_balance_per_hour: number | null
          resources_available: boolean | null
          target_level: number | null
          unified_score: number | null
        }
        Relationships: []
      }
      next_action: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          energy_feasible: boolean | null
          executable_now: boolean | null
          execution_status: string | null
          optimization_score: number | null
          payback_minutes: number | null
          planet_id: string | null
          planet_name: string | null
          prerequisites_met: boolean | null
          resources_available: boolean | null
          target_level: number | null
        }
        Relationships: []
      }
      next_action_explained: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          energy_feasible: boolean | null
          executable_now: boolean | null
          execution_status: string | null
          optimization_score: number | null
          payback_minutes: number | null
          planet_id: string | null
          planet_name: string | null
          prerequisites_met: boolean | null
          recommendation_reason: string | null
          resources_available: boolean | null
          target_level: number | null
        }
        Relationships: []
      }
      normalized_action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_energy_balance_per_hour: number | null
          current_energy_consumption_per_hour: number | null
          current_energy_production_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          economic_score: number | null
          economic_score_normalized: number | null
          energy_delta_per_hour: number | null
          energy_effect: string | null
          energy_feasible: boolean | null
          energy_generation_score: number | null
          energy_score_normalized: number | null
          feasibility_score: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          projected_energy_balance_per_hour: number | null
          target_level: number | null
          unified_score: number | null
        }
        Relationships: []
      }
      optimization_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_energy_balance_per_hour: number | null
          current_energy_consumption_per_hour: number | null
          current_energy_production_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          economic_score: number | null
          economic_score_normalized: number | null
          energy_delta_per_hour: number | null
          energy_effect: string | null
          energy_feasible: boolean | null
          energy_generation_score: number | null
          energy_score_normalized: number | null
          feasibility_score: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          optimization_score: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          projected_energy_balance_per_hour: number | null
          target_level: number | null
          unified_score: number | null
        }
        Relationships: []
      }
      production_roi_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          energy_delta_per_hour: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          payback_hours: number | null
          planet_id: string | null
          planet_name: string | null
          target_level: number | null
        }
        Relationships: []
      }
      research_action_candidates: {
        Row: {
          active_research_jobs: number | null
          available_crystal: number | null
          available_deuterium: number | null
          available_metal: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          galaxy: number | null
          planet_id: string | null
          planet_name: string | null
          player_id: string | null
          position: number | null
          research_id: string | null
          research_name: string | null
          research_time_seconds: number | null
          resources_available: boolean | null
          system: number | null
          target_level: number | null
        }
        Relationships: [
          {
            foreignKeyName: "planets_player_id_fkey"
            columns: ["player_id"]
            isOneToOne: false
            referencedRelation: "players"
            referencedColumns: ["id"]
          },
        ]
      }
      scored_action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          active_jobs: number | null
          available_crystal: number | null
          available_deuterium: number | null
          available_metal: number | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          metal_equivalent_cost: number | null
          planet_id: string | null
          planet_name: string | null
          prerequisites_met: boolean | null
          resource_intensity_per_second: number | null
          resources_available: boolean | null
          target_level: number | null
        }
        Relationships: []
      }
      simulated_followup_actions: {
        Row: {
          first_action_id: string | null
          first_current_level: number | null
          first_duration_seconds: number | null
          first_target_level: number | null
          planet_id: string | null
          resulting_crystal: number | null
          resulting_deuterium: number | null
          resulting_metal: number | null
          second_action_affordable: boolean | null
          second_action_id: string | null
          second_action_name: string | null
          second_action_score: number | null
          second_cost_crystal: number | null
          second_cost_deuterium: number | null
          second_cost_metal: number | null
          second_current_level: number | null
          second_target_level: number | null
        }
        Relationships: []
      }
      temporal_action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          affordable: boolean | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          current_level: number | null
          duration_seconds: number | null
          minutes_forward: number | null
          optimization_score: number | null
          payback_minutes: number | null
          planet_id: string | null
          planet_name: string | null
          projected_crystal: number | null
          projected_deuterium: number | null
          projected_metal: number | null
          target_level: number | null
        }
        Relationships: []
      }
      unified_action_candidates: {
        Row: {
          action_id: string | null
          action_name: string | null
          action_type: string | null
          cost_crystal: number | null
          cost_deuterium: number | null
          cost_metal: number | null
          crystal_delta_per_hour: number | null
          current_energy_balance_per_hour: number | null
          current_energy_consumption_per_hour: number | null
          current_energy_production_per_hour: number | null
          current_level: number | null
          deuterium_delta_per_hour: number | null
          duration_seconds: number | null
          economic_score: number | null
          energy_delta_per_hour: number | null
          energy_effect: string | null
          energy_feasible: boolean | null
          energy_generation_score: number | null
          feasibility_score: number | null
          investment_value: number | null
          metal_delta_per_hour: number | null
          payback_hours: number | null
          payback_minutes: number | null
          payback_score: number | null
          planet_id: string | null
          planet_name: string | null
          projected_energy_balance_per_hour: number | null
          target_level: number | null
          unified_score: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      cancel_building: {
        Args: { p_queue_id: string }
        Returns: {
          queue_id: string
          planet_id: string
          building_id: string
          target_level: number
          refund_metal: number
          refund_crystal: number
          refund_deuterium: number
          status: string
        }[]
      }
      cancel_research: {
        Args: { p_queue_id: string }
        Returns: {
          queue_id: string
          player_id: string
          planet_id: string
          research_id: string
          target_level: number
          refund_metal: number
          refund_crystal: number
          refund_deuterium: number
          status: string
        }[]
      }
      can_start_demolition: {
        Args: { p_player_id: string; p_planet_id: string; p_building_id: string }
        Returns: {
          allowed: boolean
          reason: string
          current_level: number
          target_level: number
          ion_technology_level: number
          cost_metal: number
          cost_crystal: number
          cost_deuterium: number
          duration_seconds: number
          available_metal: number
          available_crystal: number
          available_deuterium: number
          dependents_met: boolean
          research_idle: boolean
          unit_queue_idle: boolean
          queue_available: boolean
          is_downgrade: boolean
        }[]
      }
      check_colony_cap: {
        Args: { p_player_id: string }
        Returns: {
          allowed: boolean
          reason: string
          max_slots: number
          current_planets: number
          astrophysics_level: number
        }[]
      }
      get_player_expedition_item_status: {
        Args: never
        Returns: {
          kind: string
          item_id: string
          item_name: string | null
          category: string | null
          effect_key: string | null
          effect_value: number | null
          quantity: number
          expires_at: string | null
          remaining_seconds: number | null
        }[]
      }
      get_player_expedition_merchant: {
        Args: never
        Returns: {
          has_merchant: boolean
          offered_resource: string | null
          metal_rate: number | null
          crystal_rate: number | null
          deuterium_rate: number | null
          source: string | null
          created_at: string | null
          updated_at: string | null
        }[]
      }
      get_player_expedition_reports: {
        Args: { p_limit?: number }
        Returns: {
          fleet_id: string
          created_at: string
          resolved_at: string | null
          outcome: string | null
          event_type: string | null
          metal: number | null
          crystal: number | null
          deuterium: number | null
          dark_matter: number | null
          ships: Json
          item_id: string | null
          item_name: string | null
          item_quantity: number | null
          merchant_resource: string | null
          merchant_metal_rate: number | null
          merchant_crystal_rate: number | null
          merchant_deuterium_rate: number | null
          battle_id: string | null
          enemy_ships: Json
          delay_seconds: number | null
          speedup_seconds: number | null
          lost_ships: Json
          loss_percentage: number | null
          reward_tier: string | null
          reward_multiplier: number | null
          cargo_capacity: number | null
          max_resource_find: number | null
          scaled_resource_find: number | null
        }[]
      }
      get_player_expedition_slot_status: {
        Args: never
        Returns: {
          base_slots: number
          settings_bonus: number
          item_bonus: number
          total_slots: number
          used_slots: number
          available_slots: number
        }[]
      }
      get_player_support_authorizations: {
        Args: never
        Returns: {
          out_authorization_id: string
          out_direction: string
          out_destination_planet_id: string
          out_destination_name: string
          out_destination_kind: string
          out_galaxy: number
          out_system: number
          out_position: number
          out_owner_player_id: string
          out_owner_username: string
          out_guest_player_id: string
          out_guest_username: string
          out_authorized_at: string
          out_expires_at: string | null
          out_is_usable: boolean
        }[]
      }
      get_universe_debris: {
        Args: { p_universe_id: string; p_galaxy: number; p_system: number }
        Returns: {
          out_position: number
          out_metal: number
          out_crystal: number
          out_updated_at: string
        }[]
      }
      get_universe_evolution_monitor_public: {
        Args: { p_universe_id: string }
        Returns: {
          universe_id: string | null
          universe_name: string | null
          is_active: boolean | null
          status: string | null
          clock_last_tick_at: string | null
          clock_next_tick_at: string | null
          clock_interval_seconds: number | null
          clock_is_processing: boolean | null
          clock_lag_seconds: number | null
          clock_ticks_due: number | null
          galaxy_count: number | null
          normal_galaxy_count: number | null
          special_galaxy_count: number | null
          system_count: number | null
          unlocked_positions: number | null
          expansion_pending_galaxies: number | null
          expansion_oldest_lag_seconds: number | null
          next_galaxy_roll_at: string | null
          galaxy_rolls_due: number | null
          ai_planets_count: number | null
          ai_density: number | null
          ai_density_target: number | null
          ai_density_tolerance: number | null
          ai_density_lower_bound: number | null
          ai_density_upper_bound: number | null
          ai_deficit: number | null
          ai_generation_batch: number | null
          ai_estimated_batches: number | null
          next_ai_reconciliation_at: string | null
        }[]
      }
      get_universe_ranking_by_category: {
        Args: { p_universe_id: string; p_category: string; p_limit?: number }
        Returns: {
          out_rank: number
          out_player_id: string
          out_username: string
          out_player_type: string
          out_points: number
          out_is_current_player: boolean
        }[]
      }
      provision_player: {
        Args: {
          p_username: string
          p_country_code?: string
          p_planet_name?: string | null
          p_avatar_id?: string | null
        }
        Returns: {
          player_id: string
          planet_id: string | null
          username: string
          galaxy: number | null
          system: number | null
          planet_position: number | null
        }[]
      }
      start_demolition: {
        Args: { p_player_id: string; p_planet_id: string; p_building_id: string }
        Returns: string
      }
      get_player_espionage_reports: {
        Args: { p_limit?: number }
        Returns: {
          out_report_id: string
          out_player_id: string
          out_fleet_id: string
          out_target_planet_id: string
          out_target_name: string | null
          out_galaxy: number
          out_system: number
          out_position: number
          out_espionage_level: number
          out_target_espionage_level: number
          out_metal: number
          out_crystal: number
          out_deuterium: number
          out_energy: number
          out_fleet: Json
          out_defenses: Json
          out_buildings: Json
          out_research: Json
          out_counter_espionage_chance: number
          out_counter_espionage_triggered: boolean
          out_probes_sent: number
          out_probes_lost: number
          out_created_at: string
          out_ships_revealed: boolean
          out_defenses_revealed: boolean
          out_buildings_revealed: boolean
          out_research_revealed: boolean
        }[]
      }
      get_player_fleet_slots: {
        Args: never
        Returns: {
          out_player_id: string
          out_computer_technology_level: number
          out_max_slots: number
          out_slots_in_use: number
          out_slots_available: number
        }[]
      }
      get_player_messages: {
        Args: { p_limit?: number; p_unread_only?: boolean }
        Returns: {
          out_message_id: string
          out_sender_player_id: string | null
          out_sender_username: string | null
          out_subject: string
          out_body: string | null
          out_read_at: string | null
          out_created_at: string
          out_is_read: boolean
        }[]
      }
      get_player_moons: {
        Args: never
        Returns: {
          out_moon_id: string
          out_parent_planet_id: string
          out_parent_name: string | null
          out_name: string
          out_galaxy: number
          out_system: number
          out_position: number
          out_diameter_km: number
          out_fields_total: number
          out_fields_used: number
          out_cooldown_until: string | null
          out_metal: number
          out_crystal: number
          out_deuterium: number
          out_buildings: Json
        }[]
      }
      get_player_research_lab_status: {
        Args: never
        Returns: {
          research_lab_upgrading: boolean
          research_in_progress: boolean
          upgrading_planet_id: string | null
          upgrading_target_level: number | null
          upgrading_finishes_at: string | null
        }[]
      }
      get_universe_ranking: {
        Args: { p_limit?: number; p_universe_id: string }
        Returns: {
          out_rank: number
          out_player_id: string
          out_username: string
          out_player_type: string
          out_points: number
          out_is_current_player: boolean
        }[]
      }
      mark_message_read: {
        Args: { p_message_id: string }
        Returns: {
          out_message_id: string
          out_read_at: string
          out_already_read: boolean
        }[]
      }
      recall_fleet: {
        Args: { p_player_id: string; p_fleet_id: string }
        Returns: {
          out_fleet_id: string
          out_status: string
          out_mission_type: string
          out_origin_planet_id: string
          out_returns_at: string
          out_seconds_remaining: number
          out_cargo_metal: number
          out_cargo_crystal: number
          out_cargo_deuterium: number
          out_ships: Json
        }[]
      }
      add_debris_field: {
        Args: {
          p_crystal: number
          p_galaxy: number
          p_metal: number
          p_position: number
          p_system: number
          p_universe_id: string
        }
        Returns: {
          out_crystal: number
          out_debris_id: string
          out_galaxy: number
          out_metal: number
          out_position: number
          out_system: number
          out_universe_id: string
        }[]
      }
      apply_attack_loot: {
        Args: { p_battle_id: string }
        Returns: {
          cargo_capacity: number
          loot_crystal: number
          loot_deuterium: number
          loot_metal: number
        }[]
      }
      apply_combat_hull_damage: {
        Args: {
          p_battle_id: string
          p_hull_damage: number
          p_round_number: number
          p_side: string
          p_unit_id: string
          p_unit_number: number
          p_unit_type: string
        }
        Returns: {
          alive: boolean
          exploded: boolean
          explosion_probability: number
          hull_after: number
          hull_before: number
          hull_percent: number
        }[]
      }
      apply_combat_round_damage: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          units_destroyed: number
          units_updated: number
        }[]
      }
      calculate_action_payback: {
        Args: {
          p_cost_crystal: number
          p_cost_deuterium: number
          p_cost_metal: number
          p_crystal_value?: number
          p_delta_crystal_per_hour: number
          p_delta_deuterium_per_hour: number
          p_delta_metal_per_hour: number
          p_deuterium_value?: number
          p_metal_value?: number
        }
        Returns: number
      }
      calculate_building_cost: {
        Args: { p_building_id: string; p_target_level: number }
        Returns: {
          building_id: string
          crystal: number
          deuterium: number
          metal: number
          target_level: number
        }[]
      }
      calculate_building_energy_consumption: {
        Args: { p_building_id: string; p_level: number }
        Returns: number
      }
      calculate_building_energy_delta: {
        Args: { p_building_id: string; p_planet_id: string }
        Returns: {
          building_id: string
          current_energy_per_hour: number
          current_level: number
          energy_delta_per_hour: number
          target_energy_per_hour: number
          target_level: number
        }[]
      }
      calculate_building_production_delta: {
        Args: { p_building_id: string; p_planet_id: string }
        Returns: {
          building_id: string
          crystal_delta_per_hour: number
          current_level: number
          deuterium_delta_per_hour: number
          energy_delta_per_hour: number
          metal_delta_per_hour: number
          target_level: number
        }[]
      }
      calculate_building_time: {
        Args: {
          p_building_id: string
          p_target_level: number
          p_universe_id: string
        }
        Returns: number
      }
      calculate_combat_damage: {
        Args: {
          p_attack: number
          p_hull_current: number
          p_shield_current: number
        }
        Returns: {
          hull_after: number
          hull_damage: number
          shield_damage: number
          total_damage: number
        }[]
      }
      calculate_combat_defense_debris: {
        Args: { p_battle_id: string }
        Returns: {
          crystal_lost: number
          debris_crystal: number
          debris_metal: number
          destroyed_quantity: number
          metal_lost: number
          side: string
          unit_id: string
        }[]
      }
      calculate_combat_defense_losses: {
        Args: { p_battle_id: string }
        Returns: {
          crystal_lost: number
          destroyed_quantity: number
          deuterium_lost: number
          initial_quantity: number
          metal_lost: number
          side: string
          surviving_quantity: number
          unit_id: string
        }[]
      }
      calculate_combat_round_pending_damage: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          damage_rows: number
          shots_processed: number
        }[]
      }
      calculate_combat_ship_debris: {
        Args: { p_battle_id: string }
        Returns: {
          crystal_lost: number
          debris_crystal: number
          debris_metal: number
          destroyed_quantity: number
          metal_lost: number
          side: string
          unit_id: string
        }[]
      }
      calculate_combat_ship_losses: {
        Args: { p_battle_id: string }
        Returns: {
          crystal_lost: number
          destroyed_quantity: number
          deuterium_lost: number
          initial_quantity: number
          metal_lost: number
          side: string
          surviving_quantity: number
          unit_id: string
        }[]
      }
      calculate_combat_total_debris: {
        Args: { p_battle_id: string }
        Returns: {
          crystal_lost: number
          debris_crystal: number
          debris_metal: number
          metal_lost: number
        }[]
      }
      calculate_defense_build_time: {
        Args: { p_defense_id: string; p_planet_id: string }
        Returns: number
      }
      calculate_defense_cost: {
        Args: { p_defense_id: string; p_quantity?: number }
        Returns: {
          crystal: number
          defense_id: string
          deuterium: number
          metal: number
          quantity: number
        }[]
      }
      calculate_expedition_base_resource_find: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_class_resource_multiplier: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_dark_matter_amount: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_delay_seconds: {
        Args: { p_fleet_id: string; p_multiplier: number }
        Returns: number
      }
      calculate_expedition_distance: {
        Args: { p_origin_planet_id: string }
        Returns: number
      }
      calculate_expedition_effective_points: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_final_resource_amount: {
        Args: { p_fleet_id: string }
        Returns: {
          cargo_capacity: number
          final_amount: number
          max_resource_find: number
          resource_type: string
          reward_multiplier: number
          reward_tier: string
          scaled_resource_find: number
        }[]
      }
      calculate_expedition_max_ship_find: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_max_ship_tier: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_pathfinder_multiplier: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_points: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_points_for_ship: {
        Args: { p_ship_id: string }
        Returns: number
      }
      calculate_expedition_resource_amount_for_type: {
        Args: {
          p_cargo_capacity: number
          p_max_resource_find: number
          p_resource_type: string
          p_reward_multiplier: number
        }
        Returns: number
      }
      calculate_expedition_resource_budget: {
        Args: { p_fleet_id: string }
        Returns: {
          base_resource_find: number
          cargo_capacity: number
          expedition_points: number
          final_resource_budget: number
          fleet_id: string
          reward_multiplier: number
          reward_tier: string
          tier_resource_find: number
        }[]
      }
      calculate_expedition_resource_cap: {
        Args: { p_universe_id: string }
        Returns: number
      }
      calculate_expedition_resource_multiplier:
        | { Args: { p_fleet_id: string }; Returns: number }
        | { Args: { p_at: string; p_fleet_id: string }; Returns: number }
      calculate_expedition_resource_reward: {
        Args: { p_fleet_id: string }
        Returns: {
          base_resource_find: number
          cargo_capacity: number
          expedition_points: number
          final_amount: number
          fleet_id: string
          resource_type: string
          reward_multiplier: number
          reward_tier: string
        }[]
      }
      calculate_expedition_ship_cost: {
        Args: { p_ship_id: string }
        Returns: number
      }
      calculate_expedition_ship_quantity: {
        Args: { p_ship_budget: number; p_ship_id: string }
        Returns: number
      }
      calculate_expedition_ship_reward_budget: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_expedition_ship_reward_multiplier:
        | { Args: { p_fleet_id: string }; Returns: number }
        | { Args: { p_at: string; p_fleet_id: string }; Returns: number }
      calculate_expedition_speedup_seconds: {
        Args: { p_fleet_id: string; p_percentage: number }
        Returns: number
      }
      calculate_expedition_total_hold_seconds: {
        Args: { p_fleet_id: string; p_multiplier: number }
        Returns: number
      }
      calculate_fleet_cargo_capacity: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_fleet_distance: {
        Args: { p_destination_planet_id: string; p_origin_planet_id: string }
        Returns: number
      }
      calculate_lifeform_building_cost: {
        Args: { p_building_id: string; p_target_level: number }
        Returns: {
          crystal: number
          deuterium: number
          metal: number
        }[]
      }
      calculate_lifeform_building_time: {
        Args: {
          p_building_id: string
          p_planet_id: string
          p_target_level: number
        }
        Returns: number
      }
      calculate_lifeform_research_cost: {
        Args: { p_research_id: string; p_target_level: number }
        Returns: {
          crystal: number
          deuterium: number
          metal: number
        }[]
      }
      calculate_lifeform_research_time: {
        Args: {
          p_planet_id: string
          p_research_id: string
          p_target_level: number
        }
        Returns: number
      }
      calculate_planet_energy_balance: {
        Args: { p_planet_id: string }
        Returns: {
          energy_balance_per_hour: number
          energy_consumption_per_hour: number
          energy_production_per_hour: number
        }[]
      }
      calculate_planet_production: {
        Args: { p_planet_id: string }
        Returns: {
          crystal_per_hour: number
          deuterium_per_hour: number
          energy_per_hour: number
          metal_per_hour: number
        }[]
      }
      calculate_planet_production_snapshot: {
        Args: {
          p_economy_rate: number
          p_planet_id: string
          p_production_rate: number
        }
        Returns: {
          crystal_per_hour: number
          deuterium_per_hour: number
          energy_per_hour: number
          metal_per_hour: number
        }[]
      }
      calculate_planet_storage: {
        Args: { p_planet_id: string }
        Returns: {
          crystal_capacity: number
          deuterium_capacity: number
          metal_capacity: number
        }[]
      }
      calculate_recycler_capacity: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      calculate_research_cost: {
        Args: { p_research_id: string; p_target_level: number }
        Returns: {
          crystal: number
          deuterium: number
          metal: number
          research_id: string
          target_level: number
        }[]
      }
      calculate_research_time:
        | {
            Args: {
              p_player_id: string
              p_research_id: string
              p_target_level: number
            }
            Returns: {
              base_time_seconds: number
              final_time_seconds: number
              research_id: string
              research_speed: number
              target_level: number
            }[]
          }
        | {
            Args: {
              p_research_id: string
              p_target_level: number
              p_universe_id: string
            }
            Returns: number
          }
      calculate_sequence_crossover: {
        Args: {
          p_planet_id: string
          p_sequence_a: string[]
          p_sequence_b: string[]
        }
        Returns: {
          crossover_hours: number
          crossover_minutes: number
          sequence_a: string[]
          sequence_b: string[]
        }[]
      }
      calculate_shield_bounce: {
        Args: { p_attack: number; p_shield_max: number }
        Returns: {
          bounced: boolean
          threshold: number
        }[]
      }
      calculate_ship_build_time: {
        Args: { p_planet_id: string; p_ship_id: string }
        Returns: number
      }
      calculate_ship_cost: {
        Args: { p_quantity?: number; p_ship_id: string }
        Returns: {
          crystal: number
          deuterium: number
          metal: number
          quantity: number
          ship_id: string
        }[]
      }
      calculate_universe_evolution_population_seconds: {
        Args: { p_end_at: string; p_start_at: string; p_universe_id: string }
        Returns: number
      }
      calculate_universe_evolution_production_seconds: {
        Args: { p_end_at: string; p_start_at: string; p_universe_id: string }
        Returns: number
      }
      calculate_universe_evolution_rate: {
        Args: { p_universe_id: string }
        Returns: number
      }
      calculate_universe_evolution_rate_at: {
        Args: { p_at: string; p_universe_id: string }
        Returns: number
      }
      calculate_universe_rates: {
        Args: { p_universe_id: string }
        Returns: {
          building: number
          economy: number
          expedition: number
          fleet: number
          lifeform: number
          production: number
          research: number
        }[]
      }
      calculate_virtual_production: {
        Args: {
          p_crystal_level: number
          p_deuterium_level: number
          p_economy_rate: number
          p_metal_level: number
          p_planet_id: string
          p_production_rate: number
          p_solar_level: number
        }
        Returns: {
          crystal_per_hour: number
          deuterium_per_hour: number
          energy_per_hour: number
          metal_per_hour: number
        }[]
      }
      can_build_defense: {
        Args: {
          p_defense_id: string
          p_planet_id: string
          p_player_id: string
          p_quantity?: number
        }
        Returns: {
          allowed: boolean
          build_time_seconds: number
          crystal_cost: number
          defense_id: string
          deuterium_cost: number
          metal_cost: number
          quantity: number
          reason: string
        }[]
      }
      can_build_ship: {
        Args: {
          p_planet_id: string
          p_player_id: string
          p_quantity?: number
          p_ship_id: string
        }
        Returns: {
          allowed: boolean
          build_time_seconds: number
          crystal_cost: number
          deuterium_cost: number
          metal_cost: number
          quantity: number
          reason: string
          ship_id: string
        }[]
      }
      can_recycle_debris: {
        Args: {
          p_fleet_id: string
          p_galaxy: number
          p_position: number
          p_system: number
        }
        Returns: boolean
      }
      can_research: {
        Args: {
          p_player_id: string
          p_research_id: string
          p_target_level: number
        }
        Returns: boolean
      }
      can_start_building: {
        Args: {
          p_building_id: string
          p_planet_id: string
          p_player_id: string
        }
        Returns: {
          allowed: boolean
          available_crystal: number
          available_deuterium: number
          available_metal: number
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_level: number
          fields_available: boolean
          prerequisites_met: boolean
          queue_available: boolean
          reason: string
          target_level: number
        }[]
      }
      can_start_research: {
        Args: {
          p_player_id: string
          p_planet_id: string
          p_research_id: string
        }
        Returns: {
          active_job: Json | null
          allowed: boolean
          available_crystal: number
          available_deuterium: number
          available_metal: number
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_level: number
          finishes_at_estimate: string | null
          item_bonus_percent: number
          prerequisites: Json
          prerequisites_met: boolean
          queue_available: boolean
          reason: string
          reason_code: string
          research_seconds: number
          target_level: number
        }[]
      }
      check_defense_requirements: {
        Args: { p_defense_id: string; p_planet_id: string }
        Returns: {
          allowed: boolean
          defense_id: string
          reason: string
        }[]
      }
      check_research_requirements: {
        Args: { p_player_id: string; p_research_id: string }
        Returns: {
          current_level: number
          prerequisite_research_id: string
          required_level: number
          satisfied: boolean
        }[]
      }
      check_ship_requirements: {
        Args: { p_planet_id: string; p_ship_id: string }
        Returns: {
          allowed: boolean
          reason: string
          ship_id: string
        }[]
      }
      collect_debris: {
        Args: {
          p_fleet_id: string
          p_galaxy: number
          p_position: number
          p_system: number
        }
        Returns: {
          out_capacity: number
          out_crystal_collected: number
          out_crystal_remaining: number
          out_debris_id: string
          out_fleet_id: string
          out_metal_collected: number
          out_metal_remaining: number
        }[]
      }
      combat_hull_from_integrity: {
        Args: { p_structural_integrity: number }
        Returns: number
      }
      complete_building: { Args: { p_queue_id: string }; Returns: number }
      complete_research: { Args: { p_queue_id: string }; Returns: boolean }
      create_combat_debris: {
        Args: { p_battle_id: string }
        Returns: {
          out_already_generated: boolean
          out_battle_id: string
          out_debris_crystal: number
          out_debris_id: string
          out_debris_metal: number
          out_galaxy: number
          out_position: number
          out_system: number
          out_total_crystal: number
          out_total_metal: number
        }[]
      }
      create_combat_next_round: {
        Args: { p_battle_id: string; p_previous_round: number }
        Returns: {
          attacker_units: number
          defender_units: number
          next_round: number
          units_created: number
        }[]
      }
      create_combat_round_snapshot: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          attacker_units: number
          defender_units: number
          units_created: number
        }[]
      }
      create_expedition_reward_budget: {
        Args: { p_fleet_id: string }
        Returns: string
      }
      determine_expedition_max_resource_find: {
        Args: { p_fleet_id: string }
        Returns: number
      }
      evaluate_action_at_time: {
        Args: {
          p_action_id: string
          p_action_type: string
          p_minutes_forward: number
          p_planet_id: string
        }
        Returns: {
          action_id: string
          action_type: string
          affordable: boolean
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          duration_seconds: number
          minutes_forward: number
          optimization_score: number
          payback_minutes: number
          planet_id: string
          projected_crystal: number
          projected_deuterium: number
          projected_metal: number
        }[]
      }
      evaluate_building_chain: {
        Args: { p_building_sequence: string[]; p_planet_id: string }
        Returns: {
          action_count: number
          delta_crystal_per_hour: number
          delta_deuterium_per_hour: number
          delta_economic_per_hour: number
          delta_metal_per_hour: number
          final_crystal_per_hour: number
          final_deuterium_per_hour: number
          final_economic_per_hour: number
          final_metal_per_hour: number
          initial_crystal_per_hour: number
          initial_deuterium_per_hour: number
          initial_economic_per_hour: number
          initial_metal_per_hour: number
          payback_hours: number
          total_cost_crystal: number
          total_cost_deuterium: number
          total_cost_metal: number
          total_cost_value: number
          total_duration_seconds: number
        }[]
      }
      evaluate_building_chain_horizon: {
        Args: {
          p_building_sequence: string[]
          p_horizon_minutes: number
          p_planet_id: string
        }
        Returns: {
          action_count: number
          delta_economic_per_hour: number
          final_economic_per_hour: number
          gross_economic_gain: number
          horizon_minutes: number
          initial_economic_per_hour: number
          net_economic_gain: number
          roi_percent: number
          total_cost_value: number
          total_duration_seconds: number
        }[]
      }
      evaluate_building_chain_snapshot: {
        Args: {
          p_building_rate: number
          p_building_sequence: string[]
          p_economy_rate: number
          p_planet_id: string
          p_production_rate: number
        }
        Returns: {
          action_count: number
          delta_economic_per_hour: number
          final_crystal_per_hour: number
          final_deuterium_per_hour: number
          final_economic_per_hour: number
          final_metal_per_hour: number
          initial_crystal_per_hour: number
          initial_deuterium_per_hour: number
          initial_economic_per_hour: number
          initial_metal_per_hour: number
          payback_hours: number
          total_cost_crystal: number
          total_cost_deuterium: number
          total_cost_metal: number
          total_cost_value: number
          total_duration_seconds: number
        }[]
      }
      execute_expedition_merchant_trade: {
        Args: {
          p_planet_id: string
          p_player_id: string
          p_sell_amount: number
          p_sell_resource: string
        }
        Returns: {
          bought: number
          bought_resource: string
          remaining_merchant: boolean
          sold: number
        }[]
      }
      expand_all_rapidfire_v2: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          initial_shots: number
          rapidfire_shots_added: number
          total_shots: number
        }[]
      }
      expand_rapidfire_chain_v2: {
        Args: {
          p_battle_id: string
          p_round_number: number
          p_source_shot_number: number
        }
        Returns: {
          last_shot_number: number
          shots_added: number
        }[]
      }
      expedition_event_random: {
        Args: { p_fleet_id: string; p_index?: number; p_stream: string }
        Returns: number
      }
      expedition_fleet_has_pathfinder: {
        Args: { p_fleet_id: string }
        Returns: boolean
      }
      finish_combat_round_v1: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          attacker_alive: number
          battle_result: string
          defender_alive: number
          next_round: number
          round_number: number
        }[]
      }
      generate_building_sequences: {
        Args: { p_depth: number }
        Returns: {
          sequence: string[]
        }[]
      }
      generate_combat_round_v2: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          attacker_units: number
          defender_units: number
          shots_created: number
        }[]
      }
      execute_jump_gate: {
        Args: {
          p_player_id: string
          p_ships: Json
          p_source_moon_id: string
          p_target_moon_id: string
        }
        Returns: {
          out_cooldown_seconds: number
          out_cooldown_until: string
          out_ships: Json
          out_source_moon_id: string
          out_target_moon_id: string
        }[]
      }
      get_active_expedition_count: {
        Args: { p_player_id: string }
        Returns: number
      }
      get_active_expedition_item_effect:
        | {
            Args: {
              p_effect_key: string
              p_planet_id: string
              p_player_id: string
            }
            Returns: number
          }
        | {
            Args: {
              p_at: string
              p_effect_key: string
              p_planet_id: string
              p_player_id: string
            }
            Returns: number
          }
      get_active_lifeform_research_effect: {
        Args: { p_effect_key: string; p_player_id: string }
        Returns: number
      }
      get_combat_defense_attack: {
        Args: { p_defense_id: string; p_player_id: string }
        Returns: number
      }
      get_combat_defense_hull: {
        Args: { p_defense_id: string; p_player_id: string }
        Returns: number
      }
      get_combat_defense_shield: {
        Args: { p_defense_id: string; p_player_id: string }
        Returns: number
      }
      get_combat_round_snapshot: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          alive_start: boolean
          attack: number
          hull_max: number
          hull_start: number
          shield_max: number
          shield_start: number
          side: string
          unit_id: string
          unit_number: number
          unit_type: string
        }[]
      }
      get_combat_ship_attack: {
        Args: { p_player_id: string; p_ship_id: string }
        Returns: number
      }
      get_combat_ship_hull: {
        Args: { p_player_id: string; p_ship_id: string }
        Returns: number
      }
      get_combat_ship_shield: {
        Args: { p_player_id: string; p_ship_id: string }
        Returns: number
      }
      get_combat_unit_snapshot: {
        Args: { p_battle_id: string }
        Returns: {
          attack: number
          hull: number
          quantity: number
          shield: number
          side: string
          total_attack: number
          total_hull: number
          total_shield: number
          unit_id: string
          unit_type: string
        }[]
      }
      get_current_planet_resources: {
        Args: { p_planet_id: string }
        Returns: {
          crystal: number
          deuterium: number
          elapsed_seconds: number
          energy: number
          metal: number
          planet_id: string
          projected_crystal: number
          projected_deuterium: number
          projected_metal: number
        }[]
      }
      get_expedition_ship_candidates: {
        Args: { p_fleet_id: string }
        Returns: {
          ship_id: string
          tier: number
        }[]
      }
      get_lifeform_research_population_requirement: {
        Args: { p_slot: number }
        Returns: number
      }
      get_planet_crawler_status: {
        Args: { p_planet_id: string }
        Returns: {
          crawler_count: number
          crawler_cap: number
          crawler_effective: number
          crawler_bonus_percent: number
          crawler_energy_per_hour: number
          crawler_percentage: number
          crawler_production_multiplier: number
        }[]
      }
      set_planet_crawler_percentage: {
        Args: {
          p_player_id: string
          p_planet_id: string
          p_percentage: number
        }
        Returns: {
          crawler_percentage: number
          crawler_production_multiplier: number
          crawler_energy_per_hour: number
        }[]
      }
      get_planet_wreck_field: {
        Args: { p_planet_id: string }
        Returns: {
          wreck_field_id: string
          planet_id: string
          status: string
          space_dock_level: number
          blocked_reason: string | null
          expires_at: string
          repair_started_at: string | null
          repair_finishes_at: string | null
          ship_id: string | null
          ship_name: string | null
          quantity: number | null
          repaired_quantity: number | null
          pending_quantity: number | null
        }[]
      }
      start_planet_wreck_field_repairs: {
        Args: { p_planet_id: string }
        Returns: {
          out_wreck_field_id: string | null
          out_status: string
          out_result: string
          out_finishes_at: string | null
          out_ships_total: number | null
        }[]
      }
      get_planet_building_preview: {
        Args: { p_planet_id: string }
        Returns: {
          building_id: string
          current_level: number
          target_level: number
          duration_seconds: number
          energy_delta_per_hour: number | null
        }[]
      }
      get_planet_economic_rates: {
        Args: { p_planet_id: string }
        Returns: {
          building_rate: number
          economy_rate: number
          expedition_rate: number
          fleet_rate: number
          lifeform_rate: number
          production_rate: number
          research_rate: number
          universe_id: string
        }[]
      }
      get_planet_economic_rates_snapshot: {
        Args: { p_planet_id: string }
        Returns: {
          building_rate: number
          economy_rate: number
          expedition_rate: number
          fleet_rate: number
          lifeform_rate: number
          production_rate: number
          research_rate: number
          snapshot_at: string
          universe_id: string
        }[]
      }
      get_planet_economy_overview: {
        Args: { p_planet_id: string }
        Returns: {
          metal_per_hour: number
          crystal_per_hour: number
          deuterium_per_hour: number
          energy_per_hour: number
          energy_production_per_hour: number
          energy_consumption_per_hour: number
          energy_balance_per_hour: number
          metal_capacity: number
          crystal_capacity: number
          deuterium_capacity: number
        }[]
      }
      get_planet_lifeform_building_effect: {
        Args: { p_effect_key: string; p_planet_id: string }
        Returns: number
      }
      get_planet_rate_snapshot: {
        Args: { p_planet_id: string }
        Returns: {
          building_rate: number
          economy_rate: number
          expedition_rate: number
          fleet_rate: number
          lifeform_rate: number
          production_rate: number
          research_rate: number
          universe_id: string
        }[]
      }
      get_recyclable_debris_status: {
        Args: Record<PropertyKey, never>
        Returns: {
          out_available: boolean
          out_field_count: number
        }[]
      }
      get_my_attack_protection: {
        Args: Record<PropertyKey, never>
        Returns: {
          out_protected: boolean
          out_protected_until: string | null
          out_reason: string | null
        }[]
      }
      get_player_expedition_slots: {
        Args: { p_player_id: string }
        Returns: number
      }
      get_player_transport_movements: {
        Args: { p_limit?: number }
        Returns: {
          out_created_at: string
          out_destination_galaxy: number | null
          out_destination_position: number | null
          out_destination_system: number | null
          out_movement_id: string
          out_status: string
        }[]
      }
      get_player_lifeform_effect: {
        Args: { p_effect_key: string; p_player_id: string }
        Returns: number
      }
      get_player_battle_reports: {
        Args: { p_limit?: number }
        Returns: {
          attacker_player_id: string
          attacker_ships_after: number
          attacker_ships_before: number
          battle_id: string
          caller_role: string
          created_at: string
          debris_crystal: number
          debris_metal: number
          defender_defenses_after: number
          defender_defenses_before: number
          defender_planet_id: string | null
          defender_player_id: string | null
          defender_ships_after: number
          defender_ships_before: number
          defenses_repaired: number
          finished_at: string | null
          losses: Json
          loot_applied_at: string | null
          loot_crystal: number
          loot_deuterium: number
          loot_metal: number
          outcome: string
          participants: Json
          rounds: Json
          rounds_played: number
        }[]
      }
      get_player_research_level: {
        Args: { p_player_id: string; p_research_id: string }
        Returns: number
      }
      get_research_requirements: {
        Args: { p_player_id: string; p_research_id: string }
        Returns: {
          current_level: number
          missing_levels: number
          prerequisite_name: string
          prerequisite_research_id: string
          required_level: number
          research_id: string
          research_name: string
          satisfied: boolean
        }[]
      }
      get_universe_top1_points: {
        Args: { p_universe_id: string }
        Returns: number
      }
      grant_planet_support_authorization: {
        Args: {
          p_expires_at?: string | null
          p_guest_player_id: string
          p_planet_id: string
          p_player_id: string
        }
        Returns: {
          authorization_id: string
          destination_planet_id: string
          owner_player_id: string
          guest_player_id: string
          authorized_at: string
          expires_at: string | null
        }[]
      }
      initialize_combat_unit_state: {
        Args: { p_battle_id: string }
        Returns: number
      }
      initialize_individual_combat_units: {
        Args: { p_battle_id: string }
        Returns: number
      }
      initialize_player_research: {
        Args: { p_player_id: string }
        Returns: number
      }
      inspect_expedition_capacity: {
        Args: { p_fleet_id: string }
        Returns: {
          cargo_capacity: number
          expedition_points: number
          fleet_id: string
          universe_resource_cap: number
        }[]
      }
      inspect_expedition_reward_context: {
        Args: { p_fleet_id: string }
        Returns: {
          cargo_capacity: number
          expedition_points: number
          fleet_id: string
          player_id: string
          resource_cap: number
          reward_multiplier: number
          reward_tier: string
          top1_points: number
          universe_id: string
        }[]
      }
      lifeform_experience_multiplier: {
        Args: { p_level: number }
        Returns: number
      }
      load_expedition_resource_reward: {
        Args: { p_fleet_id: string }
        Returns: {
          amount: number
          crystal: number
          deuterium: number
          fleet_id: string
          metal: number
          resource_type: string
        }[]
      }
      load_fleet_cargo: {
        Args: {
          p_crystal?: number
          p_deuterium?: number
          p_fleet_id: string
          p_metal?: number
        }
        Returns: {
          cargo_capacity: number
          crystal: number
          deuterium: number
          fleet_id: string
          metal: number
          total_cargo: number
        }[]
      }
      prepare_expedition_resource_reward: {
        Args: { p_fleet_id: string }
        Returns: {
          base_resource_find: number
          cargo_capacity: number
          expedition_points: number
          final_resource_amount: number
          fleet_id: string
          max_resource_find: number
          resource_type: string
          reward_multiplier: number
          reward_tier: string
          scaled_resource_find: number
        }[]
      }
      prepare_expedition_ship_reward: {
        Args: { p_fleet_id: string }
        Returns: {
          expedition_points: number
          fleet_id: string
          max_ship_find: number
          reward_multiplier: number
          reward_tier: string
          scaled_ship_find: number
          ship_reward: Json
        }[]
      }
      prepare_expedition_ship_reward_multitype: {
        Args: { p_fleet_id: string }
        Returns: Json
      }
      process_building_queue: {
        Args: never
        Returns: {
          building_id: string
          completed_level: number
          planet_id: string
          queue_id: string
        }[]
      }
      process_building_queue_for_planet: {
        Args: { p_planet_id: string }
        Returns: {
          building_id: string
          completed_level: number
          planet_id: string
          queue_id: string
        }[]
      }
      process_building_queue_for_universe: {
        Args: { p_universe_id: string }
        Returns: {
          building_id: string
          completed_level: number
          planet_id: string
          queue_id: string
        }[]
      }
      process_combat_round_v2: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          attacker_alive: number
          battle_id: string
          battle_result: string
          damage_rows: number
          defender_alive: number
          next_round: number
          round_number: number
          shots_created: number
          units_destroyed: number
          units_updated: number
        }[]
      }
      process_defense_queue: {
        Args: { p_planet_id: string }
        Returns: {
          defense_id: string
          quantity: number
          queue_id: string
          status: string
        }[]
      }
      process_defense_queue_until: {
        Args: { p_planet_id: string; p_until: string }
        Returns: {
          defense_id: string
          quantity: number
          queue_id: string
          status: string
        }[]
      }
      process_fleet_movements: {
        Args: never
        Returns: {
          fleet_id: string
          new_status: string
          previous_status: string
          processed_at: string
        }[]
      }
      process_lifeform_tick: { Args: { p_planet_id: string }; Returns: Json }
      process_planet_tick: {
        Args: { p_planet_id: string }
        Returns: {
          buildings_completed: number
          crystal: number
          deuterium: number
          energy: number
          metal: number
          planet_id: string
          researches_completed: number
        }[]
      }
      process_planet_tick_local: {
        Args: { p_planet_id: string }
        Returns: {
          buildings_completed: number
          crystal: number
          deuterium: number
          energy: number
          metal: number
          planet_id: string
          researches_completed: number
        }[]
      }
      process_research_queue: {
        Args: never
        Returns: {
          completed_level: number
          player_id: string
          queue_id: string
          research_id: string
        }[]
      }
      process_research_queue_for_player: {
        Args: { p_player_id: string }
        Returns: {
          completed_level: number
          player_id: string
          queue_id: string
          research_id: string
        }[]
      }
      process_research_queue_for_universe: {
        Args: { p_universe_id: string }
        Returns: {
          completed_level: number
          player_id: string
          queue_id: string
          research_id: string
        }[]
      }
      process_shipyard_queue: {
        Args: { p_planet_id: string }
        Returns: {
          quantity: number
          queue_id: string
          ship_id: string
          status: string
        }[]
      }
      process_shipyard_queue_until: {
        Args: { p_planet_id: string; p_until: string }
        Returns: {
          quantity: number
          queue_id: string
          ship_id: string
          status: string
        }[]
      }
      process_universe_clock: {
        Args: { p_universe_id: string }
        Returns: {
          next_tick_at: string
          tick_processed: boolean
          ticks_executed: number
        }[]
      }
      process_universe_galaxy_roll: {
        Args: { p_universe_id: string }
        Returns: {
          galaxies_created: number
          last_galaxy: number
          rolls_processed: number
        }[]
      }
      process_universe_heartbeat: {
        Args: never
        Returns: {
          systems_expanded: number
          total_ticks_executed: number
          universes_processed: number
        }[]
      }
      process_universe_system_expansion: {
        Args: { p_universe_id: string }
        Returns: {
          last_galaxy: number
          last_system_count: number
          systems_expanded: number
        }[]
      }
      process_universe_tick: {
        Args: { p_universe_id: string }
        Returns: {
          buildings_completed: number
          crystal: number
          deuterium: number
          energy: number
          metal: number
          planet_id: string
          researches_completed: number
        }[]
      }
      project_building_production: {
        Args: { p_building_id: string; p_planet_id: string }
        Returns: {
          building_id: string
          crystal_delta_per_hour: number
          current_crystal_per_hour: number
          current_deuterium_per_hour: number
          current_energy_per_hour: number
          current_level: number
          current_metal_per_hour: number
          deuterium_delta_per_hour: number
          energy_delta_per_hour: number
          metal_delta_per_hour: number
          planet_id: string
          target_crystal_per_hour: number
          target_deuterium_per_hour: number
          target_energy_per_hour: number
          target_level: number
          target_metal_per_hour: number
        }[]
      }
      project_planet_resources: {
        Args: { p_minutes: number; p_planet_id: string }
        Returns: {
          minutes_forward: number
          planet_id: string
          projected_crystal: number
          projected_deuterium: number
          projected_energy: number
          projected_metal: number
        }[]
      }
      rank_building_sequences: {
        Args: { p_depth: number; p_planet_id: string }
        Returns: {
          action_count: number
          delta_economic_per_hour: number
          payback_hours: number
          payback_minutes: number
          sequence: string[]
          total_cost_value: number
          total_duration_seconds: number
        }[]
      }
      rank_building_sequences_horizons: {
        Args: { p_depth: number; p_planet_id: string }
        Returns: {
          cost_value: number
          duration_seconds: number
          final_economic_per_hour: number
          gross_gain: number
          horizon_minutes: number
          net_gain: number
          rank: number
          roi_percent: number
          sequence: string[]
        }[]
      }
      rank_building_sequences_snapshot: {
        Args: { p_depth: number; p_planet_id: string }
        Returns: {
          action_count: number
          cost_value: number
          delta_economic_per_hour: number
          duration_seconds: number
          final_economic_per_hour: number
          initial_economic_per_hour: number
          payback_minutes: number
          rank: number
          sequence: string[]
        }[]
      }
      reconcile_universe_ai_population: {
        Args: { p_universe_id: string }
        Returns: {
          ai_after: number
          ai_before: number
          planets_created: number
          positions_unlocked: number
          target_ai: number
        }[]
      }
      repair_defenses_after_combat: {
        Args: { p_battle_id: string }
        Returns: {
          defense_id: string
          destroyed_quantity: number
          repaired_quantity: number
        }[]
      }
      resolve_attack_arrival: { Args: { p_fleet_id: string }; Returns: string }
      resolve_colonize_arrival: {
        Args: { p_fleet_id: string }
        Returns: {
          fleet_id: string
          galaxy: number
          new_planet_id: string
          position: number
          status: string
          system: number
        }[]
      }
      resolve_combat: { Args: { p_fleet_id: string }; Returns: string }
      resolve_deploy_arrival: {
        Args: { p_fleet_id: string }
        Returns: {
          destination_planet_id: string
          fleet_id: string
          status: string
          transferred_ships: number
        }[]
      }
      resolve_espionage_arrival: {
        Args: { p_fleet_id: string }
        Returns: {
          fleet_id: string
          report_id: string
          returns_at: string
          status: string
          target_planet_id: string
        }[]
      }
      resolve_expedition_aliens: {
        Args: { p_fleet_id: string }
        Returns: {
          battle_id: string
          enemy_ships: Json
          result: string
          survivors: Json
        }[]
      }
      resolve_expedition_arrival: {
        Args: { p_fleet_id: string }
        Returns: string
      }
      resolve_expedition_black_hole: {
        Args: { p_fleet_id: string }
        Returns: {
          loss_percentage: number
          lost_ships: Json
          surviving_ships: Json
        }[]
      }
      resolve_expedition_item: { Args: { p_fleet_id: string }; Returns: Json }
      resolve_expedition_merchant: {
        Args: { p_fleet_id: string }
        Returns: {
          crystal_rate: number
          deuterium_rate: number
          merchant_resource: string
          metal_rate: number
        }[]
      }
      resolve_expedition_pirates: {
        Args: { p_fleet_id: string }
        Returns: {
          battle_id: string
          battle_result: string
          enemy_ships: Json
          surviving_ships: Json
        }[]
      }
      resolve_expedition_return: {
        Args: { p_fleet_id: string }
        Returns: {
          delivered_crystal: number
          delivered_deuterium: number
          delivered_metal: number
          fleet_id: string
          origin_planet_id: string
          status: string
        }[]
      }
      resolve_pending_target_damage: {
        Args: {
          p_battle_id: string
          p_round_number: number
          p_target_side: string
          p_target_unit_id: string
          p_target_unit_number: number
          p_target_unit_type: string
        }
        Returns: {
          hull_final: number
          hull_start: number
          shield_final: number
          shield_start: number
          shots_resolved: number
          target_side: string
          target_unit_id: string
          target_unit_number: number
          target_unit_type: string
          total_damage: number
          total_hull_damage: number
          total_shield_damage: number
        }[]
      }
      resolve_transport_arrival: {
        Args: { p_fleet_id: string }
        Returns: {
          delivered_crystal: number
          delivered_deuterium: number
          delivered_metal: number
          destination_planet_id: string
          fleet_id: string
          returns_at: string
          status: string
        }[]
      }
      revoke_planet_support_authorization: {
        Args: { p_player_id: string; p_planet_id: string; p_guest_player_id: string }
        Returns: boolean
      }
      run_expedition_combat: {
        Args: { p_battle_id: string }
        Returns: {
          attacker_alive: number
          battle_result: string
          defender_alive: number
          rounds_played: number
        }[]
      }
      run_fleet_worker: {
        Args: never
        Returns: {
          processed_fleets: number
        }[]
      }
      scan_with_phalanx: {
        Args: {
          p_galaxy: number
          p_moon_id: string
          p_player_id: string
          p_system: number
        }
        Returns: {
          out_arrives_at: string
          out_destination_galaxy: number
          out_destination_position: number
          out_destination_system: number
          out_fleet_id: string
          out_mission_type: string
          out_owner_name: string | null
          out_player_id: string
          out_returns_at: string | null
          out_ships: Json
          out_status: string
        }[]
      }
      select_expedition_delay_multiplier:
        | { Args: never; Returns: number }
        | { Args: { p_fleet_id: string }; Returns: number }
      select_expedition_item: { Args: never; Returns: string }
      select_expedition_merchant_offer:
        | {
            Args: never
            Returns: {
              crystal_rate: number
              deuterium_rate: number
              metal_rate: number
              resource: string
            }[]
          }
        | {
            Args: { p_fleet_id: string }
            Returns: {
              crystal_rate: number
              deuterium_rate: number
              metal_rate: number
              resource: string
            }[]
          }
      select_expedition_outcome: {
        Args: { p_roll?: number; p_universe_id: string }
        Returns: string
      }
      select_expedition_resource_type:
        | { Args: never; Returns: string }
        | { Args: { p_fleet_id: string }; Returns: string }
      select_expedition_reward_tier: {
        Args: { p_roll?: number }
        Returns: string
      }
      select_expedition_reward_variant:
        | {
            Args: never
            Returns: {
              reward_multiplier: number
              reward_tier: string
            }[]
          }
        | {
            Args: { p_fleet_id: string }
            Returns: {
              reward_multiplier: number
              reward_tier: string
            }[]
          }
      select_expedition_speedup_percentage:
        | { Args: never; Returns: number }
        | { Args: { p_fleet_id: string }; Returns: number }
      simulate_building_chain: {
        Args: { p_building_sequence: string[]; p_planet_id: string }
        Returns: {
          accumulated_seconds: number
          affordable: boolean
          building_id: string
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_level: number
          duration_seconds: number
          resulting_crystal: number
          resulting_crystal_per_hour: number
          resulting_deuterium: number
          resulting_deuterium_per_hour: number
          resulting_energy_per_hour: number
          resulting_metal: number
          resulting_metal_per_hour: number
          step: number
          target_level: number
        }[]
      }
      simulate_building_chain_2: {
        Args: {
          p_first_building_id: string
          p_planet_id: string
          p_second_building_id: string
        }
        Returns: {
          first_building_id: string
          first_duration_seconds: number
          first_target_level: number
          planet_id: string
          resources_after_first_crystal: number
          resources_after_first_deuterium: number
          resources_after_first_metal: number
          second_affordable: boolean
          second_building_id: string
          second_cost_crystal: number
          second_cost_deuterium: number
          second_cost_metal: number
          second_crystal_delta_per_hour: number
          second_current_level: number
          second_deuterium_delta_per_hour: number
          second_duration_seconds: number
          second_energy_delta_per_hour: number
          second_metal_delta_per_hour: number
          second_payback_hours: number
          second_target_level: number
        }[]
      }
      simulate_building_chain_3: {
        Args: {
          p_building_1: string
          p_building_2: string
          p_building_3: string
          p_planet_id: string
        }
        Returns: {
          affordable: boolean
          building_id: string
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_level: number
          duration_seconds: number
          resulting_crystal: number
          resulting_crystal_per_hour: number
          resulting_deuterium: number
          resulting_deuterium_per_hour: number
          resulting_energy_per_hour: number
          resulting_metal: number
          resulting_metal_per_hour: number
          step: number
          target_level: number
        }[]
      }
      simulate_building_chain_snapshot: {
        Args: {
          p_building_rate: number
          p_building_sequence: string[]
          p_economy_rate: number
          p_planet_id: string
          p_production_rate: number
        }
        Returns: {
          accumulated_seconds: number
          building_id: string
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_level: number
          duration_seconds: number
          resulting_crystal: number
          resulting_crystal_per_hour: number
          resulting_deuterium: number
          resulting_deuterium_per_hour: number
          resulting_energy_per_hour: number
          resulting_metal: number
          resulting_metal_per_hour: number
          step: number
          target_level: number
        }[]
      }
      simulate_building_completion: {
        Args: { p_building_id: string; p_planet_id: string }
        Returns: {
          building_id: string
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_crystal_per_hour: number
          current_deuterium_per_hour: number
          current_energy_per_hour: number
          current_level: number
          current_metal_per_hour: number
          duration_seconds: number
          planet_id: string
          resources_at_completion_crystal: number
          resources_at_completion_deuterium: number
          resources_at_completion_metal: number
          resulting_crystal: number
          resulting_crystal_per_hour: number
          resulting_deuterium: number
          resulting_deuterium_per_hour: number
          resulting_energy_per_hour: number
          resulting_metal: number
          resulting_metal_per_hour: number
          starting_crystal: number
          starting_deuterium: number
          starting_metal: number
          target_level: number
        }[]
      }
      simulate_building_step: {
        Args: {
          p_building_id: string
          p_crystal: number
          p_crystal_per_hour: number
          p_deuterium: number
          p_deuterium_per_hour: number
          p_energy_per_hour: number
          p_metal: number
          p_metal_per_hour: number
          p_planet_id: string
          p_virtual_level: number
        }
        Returns: {
          affordable: boolean
          building_id: string
          completion_crystal: number
          completion_deuterium: number
          completion_metal: number
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_crystal_per_hour: number
          current_deuterium_per_hour: number
          current_energy_per_hour: number
          current_level: number
          current_metal_per_hour: number
          duration_seconds: number
          resulting_crystal: number
          resulting_crystal_per_hour: number
          resulting_deuterium: number
          resulting_deuterium_per_hour: number
          resulting_energy_per_hour: number
          resulting_metal: number
          resulting_metal_per_hour: number
          starting_crystal: number
          starting_deuterium: number
          starting_metal: number
          target_level: number
        }[]
      }
      simulate_building_step_snapshot: {
        Args: {
          p_building_id: string
          p_building_rate: number
          p_crystal: number
          p_crystal_per_hour: number
          p_deuterium: number
          p_deuterium_per_hour: number
          p_economy_rate: number
          p_energy_per_hour: number
          p_metal: number
          p_metal_per_hour: number
          p_planet_id: string
          p_production_rate: number
          p_virtual_level: number
        }
        Returns: {
          affordable: boolean
          building_id: string
          cost_crystal: number
          cost_deuterium: number
          cost_metal: number
          current_level: number
          duration_seconds: number
          resulting_crystal: number
          resulting_crystal_per_hour: number
          resulting_deuterium: number
          resulting_deuterium_per_hour: number
          resulting_energy_per_hour: number
          resulting_metal: number
          resulting_metal_per_hour: number
          starting_crystal: number
          starting_deuterium: number
          starting_metal: number
          target_level: number
        }[]
      }
      simulate_defender_losses: {
        Args: { p_planet_id: string; p_total_damage: number }
        Returns: {
          damage_allocated: number
          damage_remaining: number
          quantity_after: number
          quantity_before: number
          quantity_lost: number
          total_hull_before: number
          unit_id: string
          unit_type: string
        }[]
      }
      snapshot_combat_round: {
        Args: { p_battle_id: string; p_round_number: number }
        Returns: {
          attacker_units: number
          defender_units: number
          units_snapshotted: number
        }[]
      }
      start_building: {
        Args: {
          p_building_id: string
          p_planet_id: string
          p_player_id: string
        }
        Returns: string
      }
      start_colonize_fleet: {
        Args: {
          p_galaxy: number
          p_origin_planet_id: string
          p_player_id: string
          p_position: number
          p_system: number
        }
        Returns: {
          arrives_at: string
          destination_planet_id: string
          fleet_id: string
          mission_type: string
          origin_planet_id: string
          quantity: number
          ship_id: string
          started_at: string
        }[]
      }
      start_defense: {
        Args: {
          p_defense_id: string
          p_planet_id: string
          p_player_id: string
          p_quantity?: number
        }
        Returns: {
          crystal_cost: number
          defense_id: string
          deuterium_cost: number
          finishes_at: string
          metal_cost: number
          quantity: number
          queue_id: string
          started_at: string
        }[]
      }
      start_fleet: {
        Args: {
          p_destination_planet_id: string
          p_mission_type?: string
          p_origin_planet_id: string
          p_player_id: string
          p_quantity: number
          p_ship_id: string
        }
        Returns: {
          arrives_at: string
          destination_planet_id: string
          fleet_id: string
          mission_type: string
          origin_planet_id: string
          quantity: number
          ship_id: string
          started_at: string
        }[]
      }
      start_fleet_mixed: {
        Args: {
          p_destination_planet_id: string | null
          p_mission_type?: string
          p_origin_planet_id: string
          p_player_id: string
          p_ships: Json
        }
        Returns: {
          arrives_at: string
          destination_planet_id: string | null
          fleet_id: string
          mission_type: string
          origin_planet_id: string
          quantity: number
          ship_id: string
          started_at: string
        }[]
      }
      start_lifeform_building: {
        Args: { p_building_id: string; p_planet_id: string }
        Returns: Json
      }
      start_lifeform_research: {
        Args: { p_planet_id: string; p_research_id: string }
        Returns: Json
      }
      start_missile_attack: {
        Args: {
          p_destination_planet_id: string
          p_origin_planet_id: string
          p_player_id: string
          p_quantity: number
          p_target_priority?: number
        }
        Returns: string[]
      }
      start_moon_destruction: {
        Args: {
          p_destination_planet_id: string
          p_origin_planet_id: string
          p_player_id: string
          p_ships: Json
        }
        Returns: string
      }
      start_research: {
        Args: {
          p_planet_id: string
          p_player_id: string
          p_research_id: string
        }
        Returns: string
      }
      start_ship: {
        Args: {
          p_planet_id: string
          p_player_id: string
          p_quantity?: number
          p_ship_id: string
        }
        Returns: {
          crystal_cost: number
          deuterium_cost: number
          finishes_at: string
          metal_cost: number
          quantity: number
          queue_id: string
          ship_id: string
          started_at: string
        }[]
      }
      start_support_fleet: {
        Args: {
          p_destination_planet_id: string
          p_holding_until: string
          p_idempotency_key: string
          p_origin_planet_id: string
          p_player_id: string
          p_ships: Json
          p_support_mission: string
        }
        Returns: {
          fleet_id: string
          ship_id: string
          quantity: number
          origin_planet_id: string
          destination_planet_id: string
          mission_type: string
          status: string
          started_at: string
          arrives_at: string
          holding_until: string
          fuel_consumed: number
          idempotent_replay: boolean
        }[]
      }
      sync_combat_battle_final_counts: {
        Args: { p_battle_id: string }
        Returns: undefined
      }
      sync_current_planet_resources: {
        Args: { p_planet_id: string; p_player_id: string; p_until?: string }
        Returns: {
          crystal: number
          crystal_produced: number
          deuterium: number
          deuterium_produced: number
          elapsed_seconds: number
          energy: number
          metal: number
          metal_produced: number
          planet_id: string
        }[]
      }
      trade_with_expedition_merchant: {
        Args: { p_planet_id: string; p_sell_resource: string; p_sell_amount: number }
        Returns: {
          sold: number
          bought: number
          bought_resource: string
          remaining_merchant: boolean
        }[]
      }
      ui_building_definitions: {
        Args: never
        Returns: {
          base_build_time_seconds: number
          base_crystal: number
          base_deuterium: number
          base_metal: number
          cost_factor: number
          created_at: string
          description: string | null
          id: string
          max_level: number | null
          name: string
          time_factor: number | null
        }[]
        SetofOptions: {
          from: "*"
          to: "building_definitions"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      ui_defense_definitions: {
        Args: never
        Returns: {
          attack: number
          base_build_time: number
          created_at: string
          crystal_cost: number
          description: string | null
          deuterium_cost: number
          hull: number
          id: string
          metal_cost: number
          name: string
          shield: number
        }[]
        SetofOptions: {
          from: "*"
          to: "defense_definitions"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      ui_defense_queue: {
        Args: { p_planet_id: string; p_player_id: string }
        Returns: {
          created_at: string
          defense_id: string
          finishes_at: string
          id: string
          planet_id: string
          quantity: number
          started_at: string
          status: string
        }[]
        SetofOptions: {
          from: "*"
          to: "defense_queue"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      ui_research_definitions: {
        Args: never
        Returns: {
          base_crystal: number
          base_deuterium: number
          base_metal: number
          base_research_time_seconds: number
          cost_factor: number
          created_at: string
          description: string | null
          id: string
          max_level: number | null
          name: string
          time_factor: number | null
        }[]
        SetofOptions: {
          from: "*"
          to: "research_definitions"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      ui_ship_definitions: {
        Args: never
        Returns: {
          attack: number
          base_build_time_seconds: number
          base_crystal: number
          base_deuterium: number
          base_metal: number
          cargo_capacity: number
          created_at: string
          description: string | null
          fuel_consumption: number
          hull: number
          id: string
          name: string
          shield: number
          ship_type: string
          speed: number
        }[]
        SetofOptions: {
          from: "*"
          to: "ship_definitions"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      ui_universe_galaxies: {
        Args: never
        Returns: {
          created_at: string
          galaxy: number
          is_special: boolean
          next_system_expansion_at: string
          system_count: number
          system_interval_growth_factor: number
          system_interval_seconds: number
          universe_id: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "universe_galaxies"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      update_planet_resources: {
        Args: { p_planet_id: string }
        Returns: {
          crystal: number
          crystal_produced: number
          deuterium: number
          deuterium_produced: number
          elapsed_seconds: number
          energy: number
          metal: number
          metal_produced: number
          planet_id: string
        }[]
      }
      update_planet_resources_until: {
        Args: { p_planet_id: string; p_until: string }
        Returns: {
          crystal: number
          crystal_produced: number
          deuterium: number
          deuterium_produced: number
          elapsed_seconds: number
          energy: number
          metal: number
          metal_produced: number
          planet_id: string
        }[]
      }
      update_planet_resources_until_raw: {
        Args: { p_planet_id: string; p_until: string }
        Returns: {
          crystal: number
          crystal_produced: number
          deuterium: number
          deuterium_produced: number
          elapsed_seconds: number
          energy: number
          metal: number
          metal_produced: number
          planet_id: string
        }[]
      }
      use_expedition_item: {
        Args: { p_item_id: string; p_planet_id: string; p_player_id: string }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
