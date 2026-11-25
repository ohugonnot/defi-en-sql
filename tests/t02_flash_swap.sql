INSERT INTO jeton (symbole) VALUES ('T0'), ('T1');
SELECT frapper(c, j, 100e18) FROM unnest(ARRAY['alice', 'mallory']) c, unnest(ARRAY['T0', 'T1']) j;
SELECT creer_pool('T0', 'T1');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 5e18, 5e18);
SET SESSION AUTHORIZATION mallory;

SELECT assert_leve('SELECT flash_swap(1, 0, 0)', 'INSUFFICIENT_OUTPUT_AMOUNT', 'flash swap sans aucune sortie : refuse');

-- Not repaid at all.
BEGIN;
SELECT flash_swap(1, 1e18, 0);
\set ON_ERROR_STOP off
COMMIT;
\set ON_ERROR_STOP on
SELECT assert_egal(:'LAST_ERROR_SQLSTATE', 'P0001', 'flash non rembourse : COMMIT refuse');
SELECT assert_egal(:'LAST_ERROR_MESSAGE', 'INSUFFICIENT_INPUT_AMOUNT', 'flash non rembourse : motif');

-- Repaid: borrow 1 T0, send back ceil(1e18 * 1000 / 997). The COMMIT is accepted and K grows.
SELECT reserve0 * reserve1 AS k_avant FROM pool WHERE id = 1 \gset
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT transferer(caisse(1), 'T0', 1003009027081243732);
COMMIT;
SELECT assert_vrai(NOT flash_en_cours, 'flash rembourse : le drapeau de pret est retombe apres le COMMIT') FROM pool WHERE id = 1;
SELECT assert_egal((SELECT count(*) FROM flash_swap), 1::bigint, 'flash rembourse : COMMIT accepte, le pret est enregistre');
SELECT assert_vrai(reserve0 * reserve1 >= :'k_avant'::numeric, 'flash rembourse : K apres >= K avant') FROM pool WHERE id = 1;
SELECT assert_egal(reserve0, 5003009027081243732::numeric, 'flash rembourse : reserve0 = 5e18 + frais, au wei') FROM pool WHERE id = 1;
SELECT assert_egal(reserve0, solde_de(caisse(1), 'T0'), 'flash rembourse : reserves = soldes de la caisse') FROM pool WHERE id = 1;

-- One wei short: refused by the K check.
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT transferer(caisse(1), 'T0', 1003009027081243731);
\set ON_ERROR_STOP off
COMMIT;
\set ON_ERROR_STOP on
SELECT assert_egal(:'LAST_ERROR_MESSAGE', 'UniswapV2: K', 'flash rembourse un wei trop peu : K refuse');

-- Re-entering the pool during the loan is refused at once, whatever the reserves look like at COMMIT.
SELECT reserve0 AS r0_avant FROM pool WHERE id = 1 \gset
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT assert_leve('SELECT echanger(1, ''T1'', 1e16)', 'UniswapV2: LOCKED', 'flash : echanger pendant le pret refuse');
SELECT assert_leve('SELECT swap(1, 1, 0)', 'UniswapV2: LOCKED', 'flash : swap pendant le pret refuse');
SELECT assert_leve('SELECT ajouter_liquidite(1, 1e18, 1e18)', 'UniswapV2: LOCKED', 'flash : ajouter_liquidite pendant le pret refuse');
SELECT assert_leve('SELECT retirer_liquidite(1, 1e18)', 'UniswapV2: LOCKED', 'flash : retirer_liquidite pendant le pret refuse');
SELECT assert_leve('SELECT flash_swap(1, 1e18, 0)', 'UniswapV2: LOCKED', 'flash : second flash swap sur le meme pool refuse');
SELECT transferer(caisse(1), 'T0', 1003009027081243732);
COMMIT;
SELECT assert_egal(reserve0, :'r0_avant'::numeric + 3009027081243732, 'flash reentrant : reserve0 ne porte que les frais du pret') FROM pool WHERE id = 1;

-- The loan flag is cleared by the COMMIT check: the pool trades again afterwards.
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT transferer(caisse(1), 'T0', 1003009027081243732);
COMMIT;
SELECT assert_vrai(NOT flash_en_cours, 'flash rembourse : le drapeau de pret est retombe') FROM pool WHERE id = 1;
SELECT assert_vrai(echanger(1, 'T1', 1e16) > 0, 'flash rembourse : le pool echange a nouveau');

-- SET CONSTRAINTS ALL IMMEDIATE runs the check inside flash_swap, as soon as the row is inserted. The flag must be
-- raised before that insert, or the check clears it and the loan then raises it again: the pool would stay shut for good.
BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT transferer(caisse(1), 'T0', 2);
SELECT flash_swap(1, 1, 0);
COMMIT;
SELECT assert_vrai(NOT flash_en_cours, 'flash prepaye en mode IMMEDIATE : le drapeau est retombe') FROM pool WHERE id = 1;
SET SESSION AUTHORIZATION alice;
SELECT assert_vrai(echanger(1, 'T1', 1e16) > 0, 'flash prepaye en mode IMMEDIATE : un autre compte echange');
SELECT parts AS parts_alice FROM part_lp WHERE pool_id = 1 AND compte = 'alice' \gset
SELECT retirer_liquidite(1, 1e17);
SELECT assert_egal(parts, :'parts_alice'::numeric - 1e17, 'flash prepaye en mode IMMEDIATE : un LP retire sa liquidite')
  FROM part_lp WHERE pool_id = 1 AND compte = 'alice';
RESET SESSION AUTHORIZATION;
