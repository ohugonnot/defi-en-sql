INSERT INTO jeton (symbole) VALUES ('WETH'), ('COL'), ('U0'), ('U80'), ('U100'), ('UHAUT'), ('UBAS');
SELECT frapper(c, j, 1e30) FROM unnest(ARRAY['alice', 'bob']) c, unnest(ARRAY['WETH', 'COL']) j;
SELECT creer_pret_pool(j) FROM unnest(ARRAY['WETH', 'COL', 'U0', 'U80', 'U100', 'UHAUT', 'UBAS']) j;
-- COL is priced 1 WETH by a balanced DEX pool, read at the instantaneous price.
SELECT creer_pool('COL', 'WETH');
UPDATE config SET oracle = 'instantane';
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 1e24, 1e24);

-- Rate curve: 1 % at 0, 9 % at the kink, 60 % at 100 %, continuous at the kink.
RESET SESSION AUTHORIZATION;
UPDATE pret_pool SET total_emprunte = 80e18 WHERE jeton = 'U80';
UPDATE pret_pool SET total_emprunte = 100e18 WHERE jeton = 'U100';
UPDATE pret_pool SET total_emprunte = 800000000000000000000000000000 + 1000000000000000000 WHERE jeton = 'UHAUT';
UPDATE pret_pool SET total_emprunte = 800000000000000000000000000000 - 1000000000000000000 WHERE jeton = 'UBAS';
SELECT frapper('pret:U80', 'U80', 20e18), frapper('pret:U0', 'U0', 100e18),
       frapper('pret:UHAUT', 'UHAUT', 200000000000000000000000000000 - 1000000000000000000),
       frapper('pret:UBAS', 'UBAS', 200000000000000000000000000000 + 1000000000000000000);
SELECT assert_egal(taux_emprunt, 0.01e18, 'taux a 0 % d''utilisation : 1 %') FROM v_taux WHERE jeton = 'U0';
SELECT assert_egal(taux_emprunt, 0.09e18, 'taux au coude (80 %) : 9 %') FROM v_taux WHERE jeton = 'U80';
SELECT assert_egal(taux_emprunt, 0.60e18, 'taux a 100 % d''utilisation : 60 %') FROM v_taux WHERE jeton = 'U100';
SELECT assert_egal(taux_preteur, 0.072e18, 'taux preteur au coude = 80 % x 9 % = 7,2 %') FROM v_taux WHERE jeton = 'U80';
SELECT assert_vrai(h.taux_emprunt >= 0.09e18 AND b.taux_emprunt <= 0.09e18 AND h.taux_emprunt - b.taux_emprunt <= 6000000,
                   'taux continu au coude : 1e-12 de part et d''autre = moins de 6e6 wei d''ecart')
  FROM v_taux h, v_taux b WHERE h.jeton = 'UHAUT' AND b.jeton = 'UBAS';

-- A lender, a borrower with COL collateral at 80 % utilisation of the WETH vault.
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 1000e18);
SET SESSION AUTHORIZATION alice;
SELECT deposer('COL', 1250e18);
SELECT emprunter('WETH', 800e18);
SELECT assert_egal(utilisation, 0.8e18, 'utilisation 80 %') FROM v_taux WHERE jeton = 'WETH';

-- The cap is 1250 COL x 0.8 = 1000 WETH: borrowing 200 more lands exactly on it, one wei more is refused.
BEGIN;
SELECT assert_passe('SELECT emprunter(''WETH'', 200000000000000000000)', 'emprunter exactement le plafond passe');
-- 1 wei of COL, not of WETH: the WETH vault is empty by now and would refuse for lack of cash before the health check.
SELECT assert_leve('SELECT emprunter(''COL'', 1)', 'ACCOUNT_UNHEALTHY', 'au plafond : un wei de dette en plus est refuse');
ROLLBACK;

-- One year at 9 %: 800 x 9 % = 72 WETH of interest, booked by a single UPDATE.
RESET SESSION AUTHORIZATION;
SELECT avancer_bloc(1, 31536000);
SELECT md5(string_agg(p::text, ',' ORDER BY compte, jeton)) AS positions_avant FROM pret_position p \gset
SET SESSION AUTHORIZATION bob;
SELECT assert_egal(div_bas(depot_total * 1e18, parts_depot_total), 1.072e18,
                   'valeur d''une part apres un an a 80 % d''utilisation : 1,072') FROM v_pret_a_jour WHERE jeton = 'WETH';
SELECT pg_stat_force_next_flush();
BEGIN;
SELECT accumuler('WETH');
SELECT assert_egal(n_tup_upd, 1::bigint, 'interets : un seul UPDATE sur pret_pool') FROM pg_stat_xact_user_tables WHERE relname = 'pret_pool';
SELECT assert_egal(n_tup_upd, 0::bigint, 'interets : 0 ligne de pret_position modifiee') FROM pg_stat_xact_user_tables WHERE relname = 'pret_position';
COMMIT;
SELECT assert_egal(md5(string_agg(p::text, ',' ORDER BY compte, jeton)), :'positions_avant', 'interets : contenu de pret_position identique')
  FROM pret_position p;
SELECT assert_egal(total_emprunte, 872e18, 'dette totale apres un an : 800 + 72') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(dette, 872e18, 'dette d''alice : 872') FROM v_position WHERE compte = 'alice' AND jeton = 'WETH';
SELECT solde_de('bob', 'WETH') AS bob_avant \gset
SELECT retirer('WETH', 100e18);
SELECT assert_egal(solde_de('bob', 'WETH') - :'bob_avant'::numeric, 107.2e18, 'retrait de 100 parts : 107,2 WETH, plus que le depot');

-- Compounding: the next booking charges the new rate on the new debt.
RESET SESSION AUTHORIZATION;
SELECT avancer_bloc(1, 3600);
SELECT div(872e18 * 1e18, 872e18 + solde_de('pret:WETH', 'WETH')) AS u \gset
SELECT 0.09e18 + div(0.51e18 * (:'u'::numeric - 0.8e18), 0.2e18) AS taux \gset
SELECT div(872e18 * :'taux'::numeric * 3600, 1e18 * 31536000)
       + CASE WHEN mod(872e18 * :'taux'::numeric * 3600, 1e18 * 31536000) <> 0 THEN 1 ELSE 0 END AS interets_attendus \gset
SET SESSION AUTHORIZATION bob;
SELECT accumuler('WETH');
SELECT assert_egal(total_emprunte, 872e18 + :'interets_attendus'::numeric, 'composition : 872 + interet de la periode, au wei')
  FROM pret_pool WHERE jeton = 'WETH';

-- Round trip: deposit then withdraw at once never returns more than was deposited.
SELECT setseed(0.42);
DO $$
DECLARE i int; montant numeric; parts numeric; rendu numeric; faits int := 0; pertes_strictes int := 0; gains int := 0;
BEGIN
  FOR i IN 1..10000 LOOP
    montant := 1 + floor(random() * 1000000)::numeric * floor(random() * 1000000)::numeric;
    BEGIN
      parts := deposer('WETH', montant);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'PARTS_NULLES' THEN RAISE; END IF;
      CONTINUE;
    END;
    rendu := retirer('WETH', parts);
    faits := faits + 1;
    IF rendu > montant THEN gains := gains + 1; END IF;
    IF rendu < montant THEN pertes_strictes := pertes_strictes + 1; END IF;
    IF i % 100 = 0 THEN COMMIT; END IF;
  END LOOP;
  PERFORM assert_vrai(faits > 9000, format('%s allers-retours executes sur 10000', faits));
  PERFORM assert_egal(gains, 0, 'aller-retour : jamais plus que le depot');
  PERFORM assert_vrai(pertes_strictes > 0, format('%s allers-retours perdent strictement quelques wei (l''arrondi joue)', pertes_strictes));
END $$;

-- Repay: the debt is rounded up, then nothing is owed.
SET SESSION AUTHORIZATION alice;
SELECT rembourser('WETH', parts_dette) FROM pret_position WHERE compte = 'alice' AND jeton = 'WETH';
SELECT assert_egal(total_emprunte, 0::numeric, 'tout rembourse : plus aucune dette dans le vault') FROM pret_pool WHERE jeton = 'WETH';
SELECT assert_egal(parts_dette_total, 0::numeric, 'tout rembourse : plus aucune part de dette') FROM pret_pool WHERE jeton = 'WETH';

-- No debt, no price needed: a depositor of a token without a price pool can still withdraw it.
RESET SESSION AUTHORIZATION;
SELECT frapper('bob', 'U0', 10e18), frapper('alice', 'U0', 10e18);
SET SESSION AUTHORIZATION bob;
SELECT deposer('U0', 10e18);
-- A deposit nobody can price is worth 0: it blocks nobody, not even the view of unhealthy accounts.
SELECT assert_passe('SELECT count(*) FROM v_compte_malsain', 'depot sans prix : la vue des comptes malsains ne leve pas');
-- The vault holds 100 U0 of its own, so 10 shares are worth 110 and 5 shares 55.
SELECT assert_egal(retirer('U0', 5e18), 55e18, 'sans dette : retrait partiel d''un jeton sans prix accepte');
-- With a debt the unpriced deposit is worth 0 too: still withdrawable, with no borrowing power.
SET SESSION AUTHORIZATION alice;
SELECT emprunter('WETH', 1e18);
SELECT deposer('U0', 10e18);
SELECT assert_passe('SELECT retirer(''U0'', 100000000000000000)', 'avec dette : retrait d''un collateral sans prix accepte, il vaut 0');
-- The debt side stays strict: nobody borrows a token that has no price.
SELECT assert_leve('SELECT emprunter(''U0'', 1)', 'PAS_DE_PRIX', 'dette sans prix : emprunter un jeton non cote refuse');

-- Empty vaults: a named error, not a raw division by zero.
SELECT assert_leve('SELECT retirer(''U100'', 1)', 'PARTS_INSUFFISANTES', 'retrait sur un coffre sans depot : PARTS_INSUFFISANTES');
SELECT assert_leve('SELECT rembourser(''U0'', 1)', 'PARTS_INSUFFISANTES', 'remboursement sur un coffre sans dette : PARTS_INSUFFISANTES');

-- Not enough balance or shares: refused by the guard.
SET SESSION AUTHORIZATION alice;
SELECT assert_leve('SELECT deposer(''WETH'', 10000000000000000000000000000000000000000)', 'SOLDE_INSUFFISANT', 'depot au dessus du solde : SOLDE_INSUFFISANT');
SELECT assert_leve('SELECT retirer(''WETH'', 1000000000000000000)', 'PARTS_INSUFFISANTES', 'retrait sans parts de depot : PARTS_INSUFFISANTES');
SET SESSION AUTHORIZATION bob;
SELECT assert_leve('SELECT rembourser(''WETH'', 1000000000000000000)', 'PARTS_INSUFFISANTES', 'remboursement sans parts de dette : PARTS_INSUFFISANTES');

-- Invariant: the shares held by positions add up to the vault totals.
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(count(*) > 0 AND bool_and(p.parts_depot_total = coalesce(s.depot, 0) AND p.parts_dette_total = coalesce(s.dette, 0)),
                   'somme des parts des positions = totaux des vaults')
  FROM pret_pool p LEFT JOIN (SELECT jeton, sum(parts_depot) AS depot, sum(parts_dette) AS dette FROM pret_position GROUP BY jeton) s USING (jeton);

-- A gift to a vault's cash box would move its share price without the vault row lock.
SET SESSION AUTHORIZATION alice;
SELECT assert_leve('SELECT transferer(''pret:WETH'', ''WETH'', 1)', 'TRANSFERT_VERS_COFFRE', 'transfert vers la caisse du coffre WETH : refuse');
SELECT assert_leve('SELECT transferer(''pret:COL'', ''COL'', 1)', 'TRANSFERT_VERS_COFFRE', 'transfert vers la caisse du coffre COL : refuse');
RESET SESSION AUTHORIZATION;
