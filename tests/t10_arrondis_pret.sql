INSERT INTO jeton (symbole) VALUES ('WETH'), ('COL');
SELECT frapper(c, j, 1e30) FROM unnest(ARRAY['alice', 'bob', 'mallory', 'liquidateur']) c, unnest(ARRAY['WETH', 'COL']) j;
SELECT creer_pret_pool('WETH'), creer_pret_pool('COL');
-- COL costs 1/3 WETH (333333333333333333 after rounding down), read at the instantaneous price.
SELECT creer_pool('COL', 'WETH');
UPDATE config SET oracle = 'instantane';
SET SESSION AUTHORIZATION bob;
SELECT ajouter_liquidite(1, 3e24, 1e24);
SET SESSION AUTHORIZATION mallory;
SELECT deposer('WETH', 1000e18);
SET SESSION AUTHORIZATION alice;
SELECT deposer('COL', 1000e18);
SELECT emprunter('WETH', 100e18);
RESET SESSION AUTHORIZATION;

-- 1000 s of interest on the WETH vault, and a COL vault whose deposit index is above 1: no ratio below is a whole number.
SELECT avancer_bloc(1, 1000);
SET SESSION AUTHORIZATION mallory;
SELECT emprunter('COL', 70e18);
SET SESSION AUTHORIZATION bob;
SELECT deposer('COL', 200e18);
RESET SESSION AUTHORIZATION;

-- Borrow: debt shares round up, and the interest is booked before the new loan is added.
SELECT dette_totale AS d_avant, parts_dette_total AS p_avant FROM v_pret_a_jour WHERE jeton = 'WETH' \gset
SET SESSION AUTHORIZATION bob;
SELECT emprunter('WETH', 33333333333333333333) AS parts_bob \gset
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(mod(33333333333333333333 * :'p_avant'::numeric, :'d_avant'::numeric) <> 0, 'emprunt : le ratio parts / dette n''est pas entier');
SELECT assert_egal(:'parts_bob'::numeric, div(33333333333333333333 * :'p_avant'::numeric, :'d_avant'::numeric) + 1,
                   'emprunt : parts de dette arrondies vers le haut');
SELECT assert_egal(total_emprunte, :'d_avant'::numeric + 33333333333333333333, 'emprunt : interets reserves avant le nouveau pret')
  FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(horodatage_interets, (SELECT horodatage FROM chaine), 'emprunt : horodatage des interets remis a jour')
  FROM pret_pool WHERE jeton = 'WETH';

-- Debt read back from the shares: rounded up.
SELECT avancer_bloc(1, 5000);
SELECT parts_dette AS parts_dette_bob FROM pret_position WHERE compte = 'bob' AND jeton = 'WETH' \gset
SELECT dette_totale AS d_apres, parts_dette_total AS p_apres FROM v_pret_a_jour WHERE jeton = 'WETH' \gset
SELECT assert_vrai(mod(:'parts_dette_bob'::numeric * :'d_apres'::numeric, :'p_apres'::numeric) <> 0, 'dette lue : le ratio n''est pas entier');
SELECT assert_egal(dette, div(:'parts_dette_bob'::numeric * :'d_apres'::numeric, :'p_apres'::numeric) + 1, 'dette de bob lue arrondie vers le haut')
  FROM v_position WHERE compte = 'bob' AND jeton = 'WETH';

-- Repay: the amount owed rounds up.
SET SESSION AUTHORIZATION bob;
SELECT rembourser('WETH', 12345678901234567890) AS montant_rembourse \gset
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(mod(12345678901234567890 * :'d_apres'::numeric, :'p_apres'::numeric) <> 0, 'remboursement : le ratio n''est pas entier');
SELECT assert_egal(:'montant_rembourse'::numeric, div(12345678901234567890 * :'d_apres'::numeric, :'p_apres'::numeric) + 1,
                   'remboursement : montant du arrondi vers le haut');

-- Withdraw: the amount paid rounds down, on a deposit index above 1.
SELECT depot_total AS depot_apres, parts_depot_total AS parts_depot_apres FROM v_pret_a_jour WHERE jeton = 'WETH' \gset
SELECT assert_vrai(mod(123456789012345678901 * :'depot_apres'::numeric, :'parts_depot_apres'::numeric) <> 0, 'retrait : le ratio n''est pas entier');
SET SESSION AUTHORIZATION mallory;
SELECT retirer('WETH', 123456789012345678901) AS montant_retire \gset
RESET SESSION AUTHORIZATION;
SELECT assert_egal(:'montant_retire'::numeric, div(123456789012345678901 * :'depot_apres'::numeric, :'parts_depot_apres'::numeric),
                   'retrait : montant paye arrondi vers le bas');

-- Account values: collateral cap rounds down, debt rounds up, both after the price (not a whole number) is applied.
SELECT prix_instantane('COL') AS prix_col \gset
SELECT div(depot * :'prix_col'::numeric, 1e18) AS valeur_depot_alice FROM v_position WHERE compte = 'alice' AND jeton = 'COL' \gset
SELECT assert_vrai(mod(:'valeur_depot_alice'::numeric * 0.8e18, 1e18) <> 0, 'plafond : le ratio n''est pas entier');
SELECT assert_egal(max_empruntable, div(:'valeur_depot_alice'::numeric * 0.8e18, 1e18), 'plafond d''alice arrondi vers le bas')
  FROM v_compte WHERE compte = 'alice';
SELECT dette AS dette_col_mallory FROM v_position WHERE compte = 'mallory' AND jeton = 'COL' \gset
SELECT assert_vrai(mod(:'dette_col_mallory'::numeric * :'prix_col'::numeric, 1e18) <> 0, 'dette valorisee : le ratio n''est pas entier');
SELECT assert_egal(dette, div(:'dette_col_mallory'::numeric * :'prix_col'::numeric, 1e18) + 1, 'dette de mallory valorisee en WETH, arrondie vers le haut')
  FROM v_compte WHERE compte = 'mallory';

-- Withdrawing the collateral of a borrower is refused.
SET SESSION AUTHORIZATION alice;
SELECT assert_leve('SELECT retirer(''COL'', 1000000000000000000000)', 'ACCOUNT_UNHEALTHY', 'retrait de tout le collateral avec une dette : refuse');

-- Liquidation on a collateral vault whose index is not 1: shares seized round down, the liquidator never gets a wei too much.
SET SESSION AUTHORIZATION liquidateur;
SELECT echanger(1, 'COL', 3e24);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(NOT est_sain('alice'), 'apres la chute de COL, alice est malsaine');
SELECT dette_totale AS d_dette, parts_dette_total AS p_dette FROM v_pret_a_jour WHERE jeton = 'WETH' \gset
SELECT depot_total AS d_collat, parts_depot_total AS p_collat FROM v_pret_a_jour WHERE jeton = 'COL' \gset
SELECT prix_instantane('COL') AS prix_col \gset
SELECT div(7777777777777777777 * :'d_dette'::numeric, :'p_dette'::numeric) + 1 AS paiement_attendu \gset
SELECT div(:'paiement_attendu'::numeric * 1e18 * 1.1e18, :'prix_col'::numeric * 1e18) AS saisie_attendue \gset
SELECT div(:'saisie_attendue'::numeric * :'p_collat'::numeric, :'d_collat'::numeric) AS parts_attendues \gset
SELECT assert_vrai(mod(:'saisie_attendue'::numeric * :'p_collat'::numeric, :'d_collat'::numeric) <> 0, 'liquidation : le ratio parts / depot n''est pas entier');
SELECT assert_vrai(:'d_collat'::numeric > :'p_collat'::numeric, 'liquidation : l''indice du vault COL est au dessus de 1');
SET SESSION AUTHORIZATION liquidateur;
SELECT liquider('alice', 'WETH', 'COL', 7777777777777777777) AS paiement_reel \gset
RESET SESSION AUTHORIZATION;
SELECT assert_egal(:'paiement_reel'::numeric, :'paiement_attendu'::numeric, 'liquidation : dette remboursee, arrondie vers le haut');
SELECT assert_egal(parts_depot, :'parts_attendues'::numeric, 'liquidation : parts saisies arrondies vers le bas')
  FROM pret_position WHERE compte = 'liquidateur' AND jeton = 'COL';
SELECT assert_vrai(parts_depot * :'d_collat'::numeric <= :'saisie_attendue'::numeric * :'p_collat'::numeric,
                   'liquidation : la valeur des parts recues ne depasse jamais la saisie')
  FROM pret_position WHERE compte = 'liquidateur' AND jeton = 'COL';

-- Close factor on an odd number of debt shares: half of it is not whole, and the maximum rounds down.
SELECT parts_dette AS parts_dette_alice FROM pret_position WHERE compte = 'alice' AND jeton = 'WETH' \gset
SELECT assert_vrai(mod(:'parts_dette_alice'::numeric, 2) = 1, 'close factor : nombre impair de parts de dette');
SELECT div(:'parts_dette_alice'::numeric * close_factor, 1e18) AS parts_max FROM pret_pool WHERE jeton = 'WETH' \gset
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_leve(format('SELECT liquider(''alice'', ''WETH'', ''COL'', %s)', :'parts_max'::numeric + 1), 'CLOSE_FACTOR',
                   'close factor : une part au dessus du maximum arrondi vers le bas, refuse');
SELECT assert_passe(format('SELECT liquider(''alice'', ''WETH'', ''COL'', %s)', :'parts_max'), 'close factor : le maximum arrondi vers le bas est accepte');
RESET SESSION AUTHORIZATION;

SELECT assert_vrai(count(*) > 0 AND bool_and(p.parts_depot_total = coalesce(s.depot, 0) AND p.parts_dette_total = coalesce(s.dette, 0)),
                   'somme des parts des positions = totaux des vaults')
  FROM pret_pool p LEFT JOIN (SELECT jeton, sum(parts_depot) AS depot, sum(parts_dette) AS dette FROM pret_position GROUP BY jeton) s USING (jeton);
