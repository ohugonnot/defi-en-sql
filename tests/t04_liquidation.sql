INSERT INTO jeton (symbole) VALUES ('WETH'), ('BAR');
SELECT frapper('bob', 'WETH', 1000e18), frapper('alice', 'BAR', 10e18), frapper('mallory', 'BAR', 100e18),
       frapper('liquidateur', 'WETH', 10e18), frapper('bob', 'BAR', 1000e18);
SELECT creer_pret_pool('WETH'), creer_pret_pool('BAR');
-- BAR trades at 0.1 WETH in a thin pool, read at the instantaneous price.
SELECT creer_pool('BAR', 'WETH');
UPDATE config SET oracle = 'instantane';
SET SESSION AUTHORIZATION bob;
SELECT ajouter_liquidite(1, 100e18, 10e18);
SELECT deposer('WETH', 100e18);
SET SESSION AUTHORIZATION alice;
SELECT deposer('BAR', 10e18);
SELECT emprunter('WETH', 0.7e18);

SELECT assert_vrai(est_sain('alice'), 'alice : 10 BAR a 0,1 WETH, limite 0,8, dette 0,7 : compte sain');
SELECT assert_vrai(NOT EXISTS (SELECT 1 FROM v_compte_malsain), 'aucun compte malsain');
SET SESSION AUTHORIZATION liquidateur;
SELECT empreinte() AS avant \gset
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''BAR'', 100000000000000000)', 'ACCOUNT_HEALTHY',
                   'compte sain : liquidation refusee');
SELECT assert_egal(empreinte(), :'avant', 'compte sain : etat intact');

-- A holder dumps 20 BAR: the price falls to about 0.069 and the account becomes unhealthy.
SET SESSION AUTHORIZATION mallory;
SELECT echanger(1, 'BAR', 20e18);
SELECT assert_vrai((SELECT max_empruntable < dette FROM v_compte WHERE compte = 'alice'),
                   'apres la baisse du prix, la dette depasse le plafond');
SELECT assert_vrai((SELECT count(*) = 1 FROM v_compte_malsain WHERE compte = 'alice'), 'alice figure dans v_compte_malsain');

-- Close factor 50 %: 0.35 of the 0.7 shares at most, in one transaction.
SET SESSION AUTHORIZATION liquidateur;
SELECT empreinte() AS avant \gset
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''BAR'', 350000000000000001)', 'CLOSE_FACTOR',
                   'close factor : un wei au-dessus du maximum refuse');
SELECT assert_egal(empreinte(), :'avant', 'close factor : etat intact');

-- Liquidation of 0.1 shares. Expected seizure recomputed here with div(), independently of the views.
SELECT prix_instantane('BAR') AS prix_bar \gset
SELECT div(100000000000000000 * 1e18 * 1.1e18, :'prix_bar'::numeric * 1e18) AS saisie_attendue \gset
SELECT solde_de('liquidateur', 'WETH') AS weth_avant \gset
SELECT liquider('alice', 'WETH', 'BAR', 100000000000000000) AS rembourse \gset
SELECT assert_egal(:rembourse::numeric, 100000000000000000::numeric, 'rembourse : 0,1 WETH de dette');
SELECT assert_egal(solde_de('liquidateur', 'WETH'), :'weth_avant'::numeric - :rembourse::numeric, 'le liquidateur a paye le remboursement');
SELECT assert_egal(parts_depot, :'saisie_attendue'::numeric, 'liquidateur recoit des parts BAR = rembourse x prime / prix, au wei')
  FROM pret_position WHERE compte = 'liquidateur' AND jeton = 'BAR';
SELECT assert_vrai(abs(div(:'saisie_attendue'::numeric * :'prix_bar'::numeric, 1e18) - 110000000000000000) <= 1,
                   'valeur recue = remboursement x 1,1 (a 1 wei pres)');
SELECT assert_egal(parts_depot, 10e18 - :'saisie_attendue'::numeric, 'le collateral d''alice baisse de la meme quantite')
  FROM pret_position WHERE compte = 'alice' AND jeton = 'BAR';
SELECT assert_egal(parts_dette, 600000000000000000::numeric, 'la dette d''alice baisse de 0,1')
  FROM pret_position WHERE compte = 'alice' AND jeton = 'WETH';

-- The maximum, 50 % of the remaining 0.6 shares, is accepted.
SELECT liquider('alice', 'WETH', 'BAR', 300000000000000000);
SELECT assert_egal(parts_dette, 300000000000000000::numeric, 'close factor : le maximum exact est accepte')
  FROM pret_position WHERE compte = 'alice' AND jeton = 'WETH';
