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
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''BAR'', 100000000000000000)', 'ACCOUNT_HEALTHY',
                   'compte sain : liquidation refusee');
-- Zero shares are refused before anything else, even on a healthy account.
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''BAR'', 0)', 'PARTS_NULLES', 'liquider zero part : PARTS_NULLES avant le test de sante');
-- A debtor name that carries its own collation must not break the name-order comparison (42P22).
SELECT assert_leve($q$SELECT liquider(nom, 'WETH', 'BAR', 100000000000000000) FROM (SELECT 'alice'::text COLLATE "und-x-icu" AS nom) t$q$,
                   'ACCOUNT_HEALTHY', 'liquider : nom du debiteur avec une collation explicite');

-- A holder dumps 20 BAR: the price falls to about 0.069 and the account becomes unhealthy.
SET SESSION AUTHORIZATION mallory;
SELECT echanger(1, 'BAR', 20e18);
SELECT assert_vrai((SELECT max_empruntable < dette FROM v_compte WHERE compte = 'alice'),
                   'apres la baisse du prix, la dette depasse le plafond');
SELECT assert_vrai((SELECT count(*) = 1 FROM v_compte_malsain WHERE compte = 'alice'), 'alice figure dans v_compte_malsain');

-- Close factor 50 %: 0.35 of the 0.7 shares at most, in one transaction.
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''BAR'', 350000000000000001)', 'CLOSE_FACTOR',
                   'close factor : un wei au-dessus du maximum refuse');

-- A collateral nobody can price (no pool against WETH) is worth 0: 1 wei of it neither hides the account nor blocks its liquidation.
RESET SESSION AUTHORIZATION;
INSERT INTO jeton (symbole) VALUES ('U0');
SELECT frapper('alice', 'U0', 1);
SELECT creer_pret_pool('U0');
SET SESSION AUTHORIZATION alice;
SELECT deposer('U0', 1);
SET SESSION AUTHORIZATION liquidateur;
BEGIN;
SELECT assert_passe('SELECT liquider(''alice'', ''WETH'', ''BAR'', 100000000000000000)', 'collateral sans prix : liquider saisit quand meme du BAR');
ROLLBACK;
SELECT assert_vrai(NOT est_sain('alice'), 'collateral sans prix : alice reste malsaine');
SELECT assert_vrai((SELECT count(*) = 1 FROM v_compte_malsain WHERE compte = 'alice'), 'collateral sans prix : la vue des comptes malsains ne leve pas');

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
SELECT assert_egal(total_emprunte, 600000000000000000::numeric, 'vault WETH : la dette totale baisse de 0,1') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(parts_dette_total, 600000000000000000::numeric, 'vault WETH : les parts de dette totales baissent de 0,1') FROM pret_pool WHERE jeton = 'WETH';

-- The maximum, 50 % of the remaining 0.6 shares, is accepted.
SELECT liquider('alice', 'WETH', 'BAR', 300000000000000000);
SELECT assert_egal(parts_dette, 300000000000000000::numeric, 'close factor : le maximum exact est accepte')
  FROM pret_position WHERE compte = 'alice' AND jeton = 'WETH';

-- A collateral crash: the 50 % close factor would seize more than alice owns.
SET SESSION AUTHORIZATION mallory;
SELECT echanger(1, 'BAR', 70e18);
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''BAR'', 150000000000000000)', 'COLLATERAL_INSUFFISANT',
                   'collateral insuffisant : liquidation refusee');
RESET SESSION AUTHORIZATION;

-- Liquidation moved the vault totals with the positions.
SELECT assert_egal(count(*), 1::bigint, 'liquidateur : une seule position BAR') FROM pret_position WHERE compte = 'liquidateur' AND jeton = 'BAR';
SELECT assert_vrai(count(*) > 0 AND bool_and(p.parts_depot_total = coalesce(s.depot, 0) AND p.parts_dette_total = coalesce(s.dette, 0)),
                   'somme des parts des positions = totaux des vaults')
  FROM pret_pool p LEFT JOIN (SELECT jeton, sum(parts_depot) AS depot, sum(parts_dette) AS dette FROM pret_position GROUP BY jeton) s USING (jeton);

-- A collateral vault nobody ever deposited in: a named error, not a raw division by zero.
INSERT INTO jeton (symbole) VALUES ('VIDE');
SELECT frapper('bob', 'VIDE', 10e18), frapper('bob', 'WETH', 10e18);
SELECT creer_pool('VIDE', 'WETH') AS pool_vide \gset
SELECT creer_pret_pool('VIDE');
SET SESSION AUTHORIZATION bob;
SELECT ajouter_liquidite(:pool_vide, 10e18, 10e18);
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''VIDE'', 100000000000000000)', 'COLLATERAL_INSUFFISANT',
                   'collateral dans un coffre sans depot : COLLATERAL_INSUFFISANT');
-- The debt vault carries someone else's debt, so a missing position is not hidden by an empty vault.
RESET SESSION AUTHORIZATION;
SELECT frapper('bob', 'VIDE', 5e18), frapper('liquidateur', 'VIDE', 1e18);
SET SESSION AUTHORIZATION bob;
SELECT deposer('VIDE', 5e18), emprunter('VIDE', 1e18);
SET SESSION AUTHORIZATION liquidateur;
-- A debt vault where the debtor has no position: CLOSE_FACTOR, not a liquidation that seizes without repaying.
SELECT assert_leve('SELECT liquider(''alice'', ''VIDE'', ''BAR'', 10000000000000000)', 'CLOSE_FACTOR',
                   'dette dans un coffre ou le debiteur n''a pas de position : CLOSE_FACTOR');
RESET SESSION AUTHORIZATION;

-- A collateral priced at 0 (1 wei of WETH against 1e19 units): a named error, not a raw division by zero.
INSERT INTO jeton (symbole) VALUES ('ZERO');
SELECT frapper('bob', 'ZERO', 1e19), frapper('bob', 'WETH', 1);
SELECT creer_pool('ZERO', 'WETH') AS pool_zero \gset
SELECT creer_pret_pool('ZERO');
SET SESSION AUTHORIZATION bob;
SELECT ajouter_liquidite(:pool_zero, 1e19, 1);
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_egal(prix_instantane('ZERO'), 0::numeric, 'fixture : ZERO vaut 0 WETH');
SELECT assert_leve('SELECT liquider(''alice'', ''WETH'', ''ZERO'', 100000000000000000)', 'PAS_DE_PRIX',
                   'collateral a prix nul : PAS_DE_PRIX');
RESET SESSION AUTHORIZATION;
