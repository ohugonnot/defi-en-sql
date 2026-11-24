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
