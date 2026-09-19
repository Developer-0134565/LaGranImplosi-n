CREATE OR REPLACE FUNCTION public.run_expedition_combat(p_battle_id uuid)
RETURNS TABLE(rounds_played integer,attacker_alive bigint,defender_alive bigint,battle_result text)
LANGUAGE plpgsql
AS $function$
DECLARE r integer:=1; aa bigint:=0; dd bigint:=0; result text;
BEGIN
 PERFORM public.create_combat_round_snapshot(p_battle_id,1);
 WHILE r<=6 LOOP
   PERFORM public.process_combat_round_v2(p_battle_id,r);
   SELECT count(*) FILTER(WHERE ciu.side='ATTACKER' AND ciu.alive),count(*) FILTER(WHERE ciu.side='DEFENDER' AND ciu.alive) INTO aa,dd FROM public.combat_individual_units ciu WHERE ciu.battle_id=p_battle_id AND ciu.round_number=r;
   EXIT WHEN aa=0 OR dd=0;
   r:=r+1;
 END LOOP;
 IF aa>0 AND dd=0 THEN result:='ATTACKER_WIN'; ELSIF aa=0 AND dd>0 THEN result:='DEFENDER_WIN'; ELSE result:='DRAW'; END IF;
 RETURN QUERY SELECT r,aa,dd,result;
END;
$function$;