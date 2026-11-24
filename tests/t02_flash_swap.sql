INSERT INTO jeton (symbole) VALUES ('T0'), ('T1');
SELECT frapper(c, j, 100e18) FROM unnest(ARRAY['alice', 'mallory']) c, unnest(ARRAY['T0', 'T1']) j;
SELECT creer_pool('T0', 'T1');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 5e18, 5e18);
SET SESSION AUTHORIZATION mallory;

SELECT assert_leve('SELECT flash_swap(1, 0, 0)', 'INSUFFICIENT_OUTPUT_AMOUNT', 'flash swap sans aucune sortie : refuse');

-- Not repaid at all.
SELECT empreinte() AS avant \gset
BEGIN;
SELECT flash_swap(1, 1e18, 0);
\set ON_ERROR_STOP off
COMMIT;
\set ON_ERROR_STOP on
SELECT assert_egal(:'LAST_ERROR_SQLSTATE', 'P0001', 'flash non rembourse : COMMIT refuse');
SELECT assert_egal(:'LAST_ERROR_MESSAGE', 'INSUFFICIENT_INPUT_AMOUNT', 'flash non rembourse : motif');
SELECT assert_egal(empreinte(), :'avant', 'flash non rembourse : base identique');

-- Repaid: borrow 1 T0, send back ceil(1e18 * 1000 / 997). The COMMIT is accepted and K grows.
SELECT reserve0 * reserve1 AS k_avant FROM pool WHERE id = 1 \gset
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT transferer(caisse(1), 'T0', 1003009027081243732);
COMMIT;
SELECT assert_egal((SELECT count(*) FROM flash_swap), 1::bigint, 'flash rembourse : COMMIT accepte, le pret est enregistre');
SELECT assert_vrai(reserve0 * reserve1 >= :'k_avant'::numeric, 'flash rembourse : K apres >= K avant') FROM pool WHERE id = 1;
SELECT assert_egal(reserve0, 5003009027081243732::numeric, 'flash rembourse : reserve0 = 5e18 + frais, au wei') FROM pool WHERE id = 1;
SELECT assert_egal(reserve0, solde_de(caisse(1), 'T0'), 'flash rembourse : reserves = soldes de la caisse') FROM pool WHERE id = 1;

-- One wei short: refused by the K check.
SELECT empreinte() AS avant \gset
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT transferer(caisse(1), 'T0', 1003009027081243731);
\set ON_ERROR_STOP off
COMMIT;
\set ON_ERROR_STOP on
SELECT assert_egal(:'LAST_ERROR_MESSAGE', 'UniswapV2: K', 'flash rembourse un wei trop peu : K refuse');
SELECT assert_egal(empreinte(), :'avant', 'flash rembourse un wei trop peu : base identique');

-- Re-entering the pool during the loan breaks the lock.
BEGIN;
SELECT flash_swap(1, 1e18, 0);
SELECT transferer(caisse(1), 'T0', 1003009027081243732);
SELECT echanger(1, 'T1', 1e16);
\set ON_ERROR_STOP off
COMMIT;
\set ON_ERROR_STOP on
SELECT assert_egal(:'LAST_ERROR_MESSAGE', 'UniswapV2: LOCKED', 'flash : reentree dans le pool refusee');
SELECT assert_egal(empreinte(), :'avant', 'flash reentrant : base identique');
