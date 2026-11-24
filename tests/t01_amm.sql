INSERT INTO jeton (symbole) VALUES ('T0'), ('T1');
SELECT frapper(c, j, 1e34) FROM unnest(ARRAY['alice', 'bob']) c, unnest(ARRAY['T0', 'T1']) j;

-- Pools 1 to 7: the swapTestCases of UniswapV2Pair.spec.ts. Pools 8 to 11: optimisticTestCases.
SELECT creer_pool('T0', 'T1') FROM generate_series(1, 11);

CREATE TABLE vecteurs (i int, entree numeric, r0 numeric, r1 numeric, attendu numeric);
INSERT INTO vecteurs VALUES
  (1, 1e18,  5e18,    10e18,   1662497915624478906),
  (2, 1e18,  10e18,   5e18,    453305446940074565),
  (3, 2e18,  5e18,    10e18,   2851015155847869602),
  (4, 2e18,  10e18,   5e18,    831248957812239453),
  (5, 1e18,  10e18,   10e18,   906610893880149131),
  (6, 1e18,  100e18,  100e18,  987158034397061298),
  (7, 1e18,  1000e18, 1000e18, 996006981039903216);
CREATE TABLE optimistes (i int, sortie numeric, r0 numeric, r1 numeric, entree numeric);
INSERT INTO optimistes VALUES
  (8,  997000000000000000, 5e18,  10e18, 1e18),
  (9,  997000000000000000, 10e18, 5e18,  1e18),
  (10, 997000000000000000, 5e18,  5e18,  1e18),
  (11, 1e18,               5e18,  5e18,  1003009027081243732);
GRANT SELECT ON vecteurs, optimistes TO alice;

SET SESSION AUTHORIZATION alice;

SELECT assert_egal(racine_entiere(n * n - 1), n - 1, 'racine_entiere(n^2 - 1) = n - 1')
  FROM (SELECT 1000000000000000007::numeric AS n) t;
SELECT assert_egal(floor(sqrt(n * n - 1)), n, 'le sqrt natif arrondit : floor(sqrt(n^2 - 1)) = n')
  FROM (SELECT 1000000000000000007::numeric AS n) t;
SELECT assert_egal(trunc(2e18::numeric / 3), 666666666666666667::numeric, 'le / numeric arrondit au plus proche');
SELECT assert_egal(div_bas(2e18, 3), 666666666666666666::numeric, 'div_bas tronque');

DO $$
DECLARE v record; solde_avant numeric;
BEGIN
  FOR v IN SELECT * FROM vecteurs ORDER BY i LOOP
    PERFORM ajouter_liquidite(v.i, v.r0, v.r1);
    PERFORM assert_egal(montant_sortie(v.entree, v.r0, v.r1), v.attendu,
                        format('vecteur Uniswap %s : montant_sortie au wei pres', v.i));
    PERFORM transferer(caisse(v.i), 'T0', v.entree);
    PERFORM assert_leve(format('SELECT swap(%s, 0, %s)', v.i, v.attendu + 1), 'UniswapV2: K',
                        format('vecteur %s : un wei de plus est refuse', v.i));
    solde_avant := solde_de('alice', 'T1');
    PERFORM swap(v.i, 0, v.attendu);
    PERFORM assert_egal(solde_de('alice', 'T1') - solde_avant, v.attendu, format('vecteur %s : swap paie exactement', v.i));
  END LOOP;
  FOR v IN SELECT * FROM optimistes ORDER BY i LOOP
    PERFORM ajouter_liquidite(v.i, v.r0, v.r1);
    PERFORM transferer(caisse(v.i), 'T0', v.entree);
    PERFORM assert_leve(format('SELECT swap(%s, %s, 0)', v.i, v.sortie + 1), 'UniswapV2: K',
                        format('optimiste %s : un wei de plus est refuse', v.i));
    PERFORM swap(v.i, v.sortie, 0);
  END LOOP;
END $$;
SELECT assert_egal(div_haut(1e18 * 1000, 1000 - 3), 1003009027081243732::numeric,
                   'rembourser 1 jeton emprunte coute 1003009027081243732 avec 0,3 %');

-- 10 000 swaps: K never decreases, reserves follow the vault, nothing is created or destroyed.
RESET SESSION AUTHORIZATION;
SELECT creer_pool('T0', 'T1') AS pool_grand \gset
SELECT creer_pool('T0', 'T1') AS pool_minuscule \gset
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(:pool_grand, 1000e18, 1000e18);
SELECT ajouter_liquidite(:pool_minuscule, 12345, 98765);
SELECT masse() AS masse_avant \gset
SELECT setseed(0.42), set_config('test.pool_grand', :'pool_grand', false);
DO $$
DECLARE
  i int; id_pool int; p pool; sens boolean; entree numeric; sortie numeric;
  k_avant numeric; baisses int := 0; faits int := 0; ecart_vault int := 0;
BEGIN
  FOR i IN 1..10000 LOOP
    id_pool := CASE WHEN i % 2 = 0 THEN current_setting('test.pool_grand')::int ELSE current_setting('test.pool_grand')::int + 1 END;
    SELECT * INTO p FROM pool WHERE id = id_pool;
    sens := random() < 0.5;
    entree := 1 + floor(random() * 5000)::numeric;
    IF id_pool = current_setting('test.pool_grand')::int THEN
      entree := 1 + div(CASE WHEN sens THEN p.reserve0 ELSE p.reserve1 END * floor(random() * 300)::numeric, 1000);
    END IF;
    sortie := CASE WHEN sens THEN montant_sortie(entree, p.reserve0, p.reserve1)
                   ELSE montant_sortie(entree, p.reserve1, p.reserve0) END;
    CONTINUE WHEN sortie = 0 OR sortie >= CASE WHEN sens THEN p.reserve1 ELSE p.reserve0 END;
    k_avant := p.reserve0 * p.reserve1;
    PERFORM echanger(id_pool, CASE WHEN sens THEN 'T0' ELSE 'T1' END, entree);
    SELECT * INTO p FROM pool WHERE id = id_pool;
    faits := faits + 1;
    IF p.reserve0 * p.reserve1 < k_avant THEN baisses := baisses + 1; END IF;
    IF p.reserve0 <> solde_de(caisse(id_pool), 'T0') OR p.reserve1 <> solde_de(caisse(id_pool), 'T1') THEN
      ecart_vault := ecart_vault + 1;
    END IF;
    IF i % 100 = 0 THEN COMMIT; END IF;
  END LOOP;
  PERFORM assert_vrai(faits > 9000, format('%s swaps executes sur 10000 tires', faits));
  PERFORM assert_egal(baisses, 0, 'montant_sortie ne rend jamais une sortie que K refuse : K apres >= K avant sur chaque swap');
  PERFORM assert_egal(ecart_vault, 0, 'reserves = soldes de la caisse apres chaque swap');
END $$;
SELECT assert_egal(masse(), :'masse_avant'::jsonb, 'conservation : la somme des soldes par jeton est inchangee');

-- LP shares.
RESET SESSION AUTHORIZATION;
SELECT creer_pool('T0', 'T1') AS pool_lp \gset
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(:pool_lp, 5e18, 10e18) AS parts_alice \gset
SELECT assert_egal(:parts_alice::numeric, 7071067811865475244::numeric - 1000, 'premier depot : racine(x*y) - 1000');
SELECT assert_egal((SELECT parts FROM part_lp WHERE pool_id = :pool_lp
                     AND compte = '0x000000000000000000000000000000000000dEaD'), 1000::numeric,
                   'les 1000 parts minimales sont sur le compte mort');
SET SESSION AUTHORIZATION bob;
SELECT ajouter_liquidite(:pool_lp, 1e18, 3e18) AS parts_bob \gset
SELECT assert_egal(:parts_bob::numeric, div(1e18 * 7071067811865475244, 5e18), 'depot suivant : min des deux ratios');
SELECT assert_egal((SELECT sum(parts) FROM part_lp WHERE pool_id = :pool_lp),
                   (SELECT parts_total FROM pool WHERE id = :pool_lp), 'somme des part_lp = parts_total');
SELECT solde_de('bob', 'T0') AS bob_t0, solde_de('bob', 'T1') AS bob_t1 \gset
SELECT retirer_liquidite(:pool_lp, :parts_bob);
SELECT assert_egal(solde_de('bob', 'T0') - :'bob_t0'::numeric,
                   div(:parts_bob::numeric * 6e18, (SELECT parts_total FROM pool WHERE id = :pool_lp) + :parts_bob::numeric),
                   'retrait : arrondi vers le bas, sur T0');
SELECT assert_vrai(solde_de('bob', 'T1') - :'bob_t1'::numeric <= 3e18, 'retrait : jamais plus que le depot, sur T1');
SELECT assert_egal((SELECT sum(parts) FROM part_lp WHERE pool_id = :pool_lp),
                   (SELECT parts_total FROM pool WHERE id = :pool_lp), 'somme des part_lp = parts_total apres retrait');

-- Minimum output: refused with the state untouched, accepted at the exact amount.
SELECT empreinte() AS avant, montant_sortie(1e18, reserve0, reserve1) AS sortie_attendue FROM pool WHERE id = :pool_lp \gset
SELECT assert_leve(format('SELECT echanger(%s, ''T0'', 1000000000000000000, %s)', :pool_lp, :sortie_attendue + 1),
                   'INSUFFICIENT_OUTPUT_AMOUNT', 'echange sous min_sortie : exception');
SELECT assert_egal(empreinte(), :'avant', 'echange sous min_sortie : etat intact');
SELECT assert_egal(echanger(:pool_lp, 'T0', 1000000000000000000, :sortie_attendue), :sortie_attendue::numeric,
                   'echange au min_sortie exact : accepte');

-- Asking for the whole reserve: refused for liquidity, before K could refuse it.
SELECT assert_leve(format('SELECT swap(%s, 0, %s)', :pool_lp, (SELECT reserve1 FROM pool WHERE id = :pool_lp)),
                   'INSUFFICIENT_LIQUIDITY', 'swap de toute la reserve : INSUFFICIENT_LIQUIDITY');

-- Reserves are uint112: a deposit above 2^112 - 1 is refused.
RESET SESSION AUTHORIZATION;
SELECT creer_pool('T0', 'T1') AS pool_gros \gset
SET SESSION AUTHORIZATION alice;
SELECT assert_leve(format('SELECT ajouter_liquidite(%s, 6000000000000000000000000000000000, 6000000000000000000000000000000000)', :pool_gros),
                   '23514', 'reserve au-dessus de 2^112 - 1 : refusee');
