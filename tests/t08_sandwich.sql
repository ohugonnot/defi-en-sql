INSERT INTO jeton (symbole) VALUES ('T0'), ('T1');
SELECT frapper(c, j, 10000e18) FROM unnest(ARRAY['alice', 'mallory', 'bob']) c, unnest(ARRAY['T0', 'T1']) j;
SELECT creer_pool('T0', 'T1') FROM generate_series(1, 4);
SET SESSION AUTHORIZATION bob;
SELECT ajouter_liquidite(n, 1000e18, 1000e18) FROM generate_series(1, 4) n;
RESET SESSION AUTHORIZATION;

SELECT montant_sortie(100e18, 1000e18, 1000e18) AS sortie_sans_attaque \gset
SELECT solde_de('mallory', 'T0') AS t0_initial_attaquant \gset

-- Victim without a minimum: front-run, victim, back-run.
SET SESSION AUTHORIZATION mallory;
SELECT echanger(1, 'T0', 200e18) AS t1_achete \gset
SET SESSION AUTHORIZATION alice;
SELECT solde_de('alice', 'T1') AS t1_victime_avant \gset
SELECT echanger(1, 'T0', 100e18);
SELECT solde_de('alice', 'T1') - :'t1_victime_avant'::numeric AS recu_victime \gset
SET SESSION AUTHORIZATION mallory;
SELECT echanger(1, 'T1', :t1_achete);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(:'recu_victime'::numeric < :'sortie_sans_attaque'::numeric, 'sandwich : la victime sans minimum recoit moins');
SELECT assert_vrai(solde_de('mallory', 'T0') > :'t0_initial_attaquant'::numeric, 'sandwich : l''attaquant sort avec plus de T0 qu''au depart');
SELECT assert_egal(:'sortie_sans_attaque'::numeric, 90661089388014913158::numeric, 'sandwich : sortie de reference, sans attaque');
SELECT assert_egal(:'recu_victime'::numeric, 63956986828671189740::numeric, 'sandwich : sortie de la victime, environ 29,5 % de moins');
SELECT assert_egal(solde_de('mallory', 'T0') - :'t0_initial_attaquant'::numeric, 30321924020611214716::numeric, 'sandwich : gain de l''attaquant en T0');

-- Victim with a 1 % slippage limit, against an oversized front-run: her transaction fails.
SELECT solde_de('mallory', 'T0') AS t0_initial_attaquant \gset
SET SESSION AUTHORIZATION mallory;
SELECT echanger(2, 'T0', 200e18) AS t1_achete \gset
SET SESSION AUTHORIZATION alice;
SELECT empreinte() AS avant \gset
SELECT assert_leve(format('SELECT echanger(2, ''T0'', 100000000000000000000, %s)', div(:'sortie_sans_attaque'::numeric * 99, 100)),
                   'INSUFFICIENT_OUTPUT_AMOUNT', 'sandwich : avec un minimum, la transaction de la victime echoue');
SELECT assert_egal(empreinte(), :'avant', 'sandwich : la victime ne perd rien, etat intact');
SET SESSION AUTHORIZATION mallory;
SELECT echanger(2, 'T1', :t1_achete);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(solde_de('mallory', 'T0') < :'t0_initial_attaquant'::numeric, 'sandwich avorte, attaquant naif : il perd les frais des deux swaps');

-- A calibrated attacker: the largest front-run the 1 % limit still lets through (bisection, to the wei).
RESET SESSION AUTHORIZATION;
CREATE FUNCTION front_run_max(reserve numeric, entree_victime numeric, minimum numeric) RETURNS numeric
  LANGUAGE plpgsql AS $$
DECLARE bas numeric := 0; haut numeric := 500e18; milieu numeric;
BEGIN
  WHILE haut - bas > 1 LOOP
    milieu := div(bas + haut, 2);
    IF montant_sortie(entree_victime, reserve + milieu, reserve - montant_sortie(milieu, reserve, reserve)) >= minimum
      THEN bas := milieu; ELSE haut := milieu; END IF;
  END LOOP;
  RETURN bas;
END $$;
SELECT div(:'sortie_sans_attaque'::numeric * 99, 100) AS minimum \gset
SELECT front_run_max(1000e18, 100e18, :'minimum'::numeric) AS x_max \gset
SELECT solde_de('mallory', 'T0') AS t0_initial_attaquant \gset
SET SESSION AUTHORIZATION mallory;
SELECT echanger(3, 'T0', :x_max) AS t1_achete \gset
SET SESSION AUTHORIZATION alice;
SELECT solde_de('alice', 'T1') AS t1_victime_avant \gset
SELECT echanger(3, 'T0', 100e18, :minimum);
SELECT solde_de('alice', 'T1') - :'t1_victime_avant'::numeric AS recu_victime \gset
SET SESSION AUTHORIZATION mallory;
SELECT echanger(3, 'T1', :t1_achete);
RESET SESSION AUTHORIZATION;
SELECT assert_egal(:'recu_victime'::numeric, :'minimum'::numeric, 'front-run calibre : la victime recoit exactement son minimum, au wei');
SELECT assert_vrai(solde_de('mallory', 'T0') > :'t0_initial_attaquant'::numeric, 'front-run calibre : l''attaquant gagne quand meme');
SELECT solde_de('mallory', 'T0') - :'t0_initial_attaquant'::numeric AS gain_attaquant \gset
SELECT assert_egal(:'gain_attaquant'::numeric, 1060722693965933599::numeric, 'front-run calibre : gain de l''attaquant en T0');

-- One wei more of front-run and the victim fails.
SET SESSION AUTHORIZATION mallory;
SELECT echanger(4, 'T0', :x_max + 1);
SET SESSION AUTHORIZATION alice;
SELECT assert_leve(format('SELECT echanger(4, ''T0'', 100000000000000000000, %s)', :'minimum'::numeric),
                   'INSUFFICIENT_OUTPUT_AMOUNT', 'front-run calibre + 1 wei : la victime echoue');
