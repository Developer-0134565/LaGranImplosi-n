CREATE OR REPLACE FUNCTION public.run_expedition_combat(p_battle_id uuid)
RETURNS TABLE(rounds_played integer,attacker_alive bigint,defender_alive bigint,battle_result text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
 r integer:=1; aa bigint:=0; dd bigint:=0; result text; v_round record;
BEGIN
 WHILE r<=6 LOOP
  -- El worker puede entrar en el runner después de que la ronda ya haya
  -- sido cerrada. En ese caso NO repetimos RNG ni daño.
  IF EXISTS(SELECT 1 FROM public.combat_rounds cr WHERE cr.battle_id=p_battle_id AND cr.round_number=r) THEN
   SELECT count(*) FILTER(WHERE cui.side='ATTACKER' AND cui.alive),count(*) FILTER(WHERE cui.side='DEFENDER' AND cui.alive)
   INTO aa,dd FROM public.combat_individual_units cui WHERE cui.battle_id=p_battle_id AND cui.round_number=r;
   EXIT WHEN aa=0 OR dd=0;
   r:=r+1;
   CONTINUE;
  END IF;

  SELECT * INTO v_round FROM public.process_combat_round_v2(p_battle_id,r);
  aa:=COALESCE(v_round.attacker_alive,0); dd:=COALESCE(v_round.defender_alive,0);
  EXIT WHEN aa=0 OR dd=0 OR v_round.battle_result<>'CONTINUE';
  r:=r+1;
 END LOOP;

 IF aa>0 AND dd=0 THEN result:='ATTACKER_WIN'; ELSIF aa=0 AND dd>0 THEN result:='DEFENDER_WIN'; ELSE result:='DRAW'; END IF;
 UPDATE public.combat_battles SET finished_at=COALESCE(finished_at,clock_timestamp()),attacker_win=(result='ATTACKER_WIN'),defender_win=(result='DEFENDER_WIN'),draw=(result='DRAW'),attacker_ships_after=aa,defender_ships_after=dd WHERE id=p_battle_id;
 RETURN QUERY SELECT r,aa,dd,result;
END;
$function$;