INSERT INTO jeton (symbole) VALUES ('WETH'), ('COL');
SELECT frapper(c, j, 1e30) FROM unnest(ARRAY['alice', 'bob']) c, unnest(ARRAY['WETH', 'COL']) j;
SELECT creer_pret_pool(j) FROM unnest(ARRAY['WETH', 'COL']) j;
SELECT creer_pool('COL', 'WETH');
UPDATE config SET oracle = 'instantane';
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 1e24, 1e24);
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 1000e18);
SET SESSION AUTHORIZATION alice;
SELECT deposer('COL', 1250e18);
SELECT emprunter('WETH', 800e18);
RESET SESSION AUTHORIZATION;

-- Every entry point books the interest itself: nobody called accumuler first, so the stored debt is stale until they do.
-- One year at 9 % on 800: debt 872, so 100 of the 800 debt shares owe 109.
SELECT avancer_bloc(1, 31536000);
SELECT assert_egal(total_emprunte, 800e18, 'avant tout appel : la dette stockee est encore celle d''il y a un an') FROM pret_pool WHERE jeton = 'WETH';
SET SESSION AUTHORIZATION alice;
SELECT assert_egal(rembourser('WETH', 100e18), 109e18, 'rembourser apres un an : 100 parts valent 109');
RESET SESSION AUTHORIZATION;
SELECT assert_egal(total_emprunte, 763e18, 'rembourser : dette totale 872 - 109 = 763') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(parts_dette_total, 700e18, 'rembourser : 700 parts de dette restantes') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(horodatage_interets, (SELECT horodatage FROM chaine), 'rembourser : horodatage des interets a jour') FROM pret_pool WHERE jeton = 'WETH';

-- One hour later: the interest is recomputed here, independently of the view (rate at the utilisation of the stored debt).
SELECT avancer_bloc(1, 3600);
SELECT total_emprunte AS dette_avant, solde_de('pret:WETH', 'WETH') AS caisse FROM pret_pool WHERE jeton = 'WETH' \gset
SELECT div(:'dette_avant'::numeric * 1e18, :'dette_avant'::numeric + :'caisse'::numeric) AS u \gset
SELECT 0.01e18 + div(0.08e18 * :'u'::numeric, 0.8e18) AS taux \gset
SELECT :'dette_avant'::numeric * :'taux'::numeric * 3600 AS numerateur \gset
SELECT div(:'numerateur'::numeric + 1e18 * 31536000 - 1, 1e18 * 31536000) AS interets \gset
SELECT assert_vrai(:'interets'::numeric > 0, 'une heure d''interets : un montant strictement positif');
SET SESSION AUTHORIZATION bob;
SELECT retirer('WETH', 1e18);
RESET SESSION AUTHORIZATION;
SELECT assert_egal(total_emprunte, :'dette_avant'::numeric + :'interets'::numeric, 'retirer : interets d''une heure ajoutes a la dette') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(horodatage_interets, (SELECT horodatage FROM chaine), 'retirer : horodatage des interets a jour') FROM pret_pool WHERE jeton = 'WETH';

SELECT avancer_bloc(1, 3600);
SELECT total_emprunte AS dette_avant, solde_de('pret:WETH', 'WETH') AS caisse FROM pret_pool WHERE jeton = 'WETH' \gset
SELECT div(:'dette_avant'::numeric * 1e18, :'dette_avant'::numeric + :'caisse'::numeric) AS u \gset
SELECT 0.01e18 + div(0.08e18 * :'u'::numeric, 0.8e18) AS taux \gset
SELECT :'dette_avant'::numeric * :'taux'::numeric * 3600 AS numerateur \gset
SELECT div(:'numerateur'::numeric + 1e18 * 31536000 - 1, 1e18 * 31536000) AS interets \gset
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 1e18);
RESET SESSION AUTHORIZATION;
SELECT assert_egal(total_emprunte, :'dette_avant'::numeric + :'interets'::numeric, 'deposer : interets d''une heure ajoutes a la dette') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(horodatage_interets, (SELECT horodatage FROM chaine), 'deposer : horodatage des interets a jour') FROM pret_pool WHERE jeton = 'WETH';

-- A short step whose remainder is below half a unit: rounding to nearest would drop it, the ceiling keeps it.
SELECT avancer_bloc(1, 5);
SELECT total_emprunte AS dette_avant, solde_de('pret:WETH', 'WETH') AS caisse FROM pret_pool WHERE jeton = 'WETH' \gset
SELECT div(:'dette_avant'::numeric * 1e18, :'dette_avant'::numeric + :'caisse'::numeric) AS u \gset
SELECT 0.01e18 + div(0.08e18 * :'u'::numeric, 0.8e18) AS taux \gset
SELECT :'dette_avant'::numeric * :'taux'::numeric * 5 AS numerateur \gset
SELECT div(:'numerateur'::numeric + 1e18 * 31536000 - 1, 1e18 * 31536000) AS interets \gset
SELECT assert_vrai(mod(:'numerateur'::numeric, 1e18 * 31536000) BETWEEN 1 AND div(1e18 * 31536000, 2) - 1,
                   'pas de 5 s : le reste de la division est sous la moitie, l''arrondi au plus proche differerait du plafond');
SET SESSION AUTHORIZATION bob;
SELECT accumuler('WETH');
RESET SESSION AUTHORIZATION;
SELECT assert_egal(total_emprunte, :'dette_avant'::numeric + :'interets'::numeric, 'accumuler : interets de 5 s arrondis vers le haut, au wei') FROM pret_pool WHERE jeton = 'WETH';

-- liquider books the interest of both vaults before it prices anything. COL loses half its price, so alice is liquidatable.
SET SESSION AUTHORIZATION bob;
SELECT echanger(1, 'COL', 500000e18);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(NOT est_sain('alice'), 'liquider : alice est malsaine apres la baisse de COL');
SELECT avancer_bloc(1, 3600);
SELECT total_emprunte AS dette_avant, solde_de('pret:WETH', 'WETH') AS caisse FROM pret_pool WHERE jeton = 'WETH' \gset
SELECT div(:'dette_avant'::numeric * 1e18, :'dette_avant'::numeric + :'caisse'::numeric) AS u \gset
SELECT 0.01e18 + div(0.08e18 * :'u'::numeric, 0.8e18) AS taux \gset
SELECT :'dette_avant'::numeric * :'taux'::numeric * 3600 AS numerateur \gset
SELECT div(:'numerateur'::numeric + 1e18 * 31536000 - 1, 1e18 * 31536000) AS interets \gset
SET SESSION AUTHORIZATION bob;
SELECT liquider('alice', 'WETH', 'COL', 100e18) AS paiement \gset
RESET SESSION AUTHORIZATION;
SELECT assert_egal(total_emprunte, :'dette_avant'::numeric + :'interets'::numeric - :'paiement'::numeric,
                   'liquider : interets d''une heure ajoutes a la dette avant le remboursement') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(horodatage_interets, (SELECT horodatage FROM chaine), 'liquider : horodatage des interets du coffre de dette a jour') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(horodatage_interets, (SELECT horodatage FROM chaine), 'liquider : horodatage des interets du coffre de collateral a jour') FROM pret_pool WHERE jeton = 'COL';
