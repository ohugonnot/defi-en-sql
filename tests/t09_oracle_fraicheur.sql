INSERT INTO jeton (symbole) VALUES ('WETH'), ('BAR');
SELECT frapper('alice', j, 1e30) FROM unnest(ARRAY['WETH', 'BAR']) j;
SELECT creer_pool('BAR', 'WETH');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 10e18, 1e18);
RESET SESSION AUTHORIZATION;

SELECT assert_leve('SELECT prix_moyen(''BAR'')', 'OBSERVATIONS_INSUFFISANTES', 'prix moyen sans aucune observation : refuse');

-- The oldest observation must be at least window minus two blocks old (720 - 24 = 696 s, 58 blocks).
SELECT observer(1);
SELECT avancer_bloc(57);
SELECT assert_leve('SELECT prix_moyen(''BAR'')', 'OBSERVATIONS_INSUFFISANTES', 'observation vieille de 684 s : refuse');
SELECT avancer_bloc(1);
SELECT assert_vrai(0.1e18 - prix_moyen('BAR') BETWEEN 0 AND 1, 'observation vieille de 696 s : acceptee, prix constant a 1 wei pres');

-- Past the window the observation no longer counts.
SELECT avancer_bloc(4);
SELECT assert_leve('SELECT prix_moyen(''BAR'')', 'OBSERVATIONS_INSUFFISANTES', 'observation vieille de 744 s, hors fenetre : refuse');
