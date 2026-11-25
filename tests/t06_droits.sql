INSERT INTO jeton (symbole) VALUES ('T0'), ('T1');
SELECT frapper(c, j, 100e18) FROM unnest(ARRAY['alice', 'mallory']) c, unnest(ARRAY['T0', 'T1']) j;
SELECT creer_pool('T0', 'T1');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 5e18, 10e18);

SELECT assert_leve('UPDATE pool SET reserve0 = 0', '42501', 'alice : UPDATE direct sur pool refuse');
SELECT assert_leve('UPDATE solde SET montant = 1e30 WHERE compte = ''alice''', '42501', 'alice : UPDATE direct sur solde refuse');
SELECT assert_leve('INSERT INTO solde VALUES (''alice'', ''T0'', 1)', '42501', 'alice : INSERT direct sur solde refuse');
SELECT assert_leve('DELETE FROM pret_pool', '42501', 'alice : DELETE direct refuse');
SELECT assert_leve('SELECT deplacer(''pool:1'', ''alice'', ''T0'', 1)', '42501', 'alice : deplacer() non executable');
SELECT assert_leve('SELECT frapper(''alice'', ''T0'', 1)', '42501', 'alice : frapper() non executable');
SELECT assert_leve('SELECT maj_pool(p, 1, 1) FROM pool p', '42501', 'alice : maj_pool() non executable');
SELECT assert_leve('SELECT avancer_bloc(1)', '42501', 'alice : avancer_bloc() non executable');
SELECT assert_leve('ALTER TABLE flash_swap DISABLE TRIGGER flash_swap_rembourse', '42501', 'alice : ne peut pas desactiver le trigger');
SELECT assert_vrai((SELECT count(*) FROM pool) = 1, 'alice : lecture de pool autorisee');

SELECT solde_de('alice', 'T1') AS avant \gset
SELECT assert_vrai(echanger(1, 'T0', 1e18) > 0, 'alice : echanger() accepte');
SELECT assert_vrai(solde_de('alice', 'T1') > :'avant'::numeric, 'echanger() paie le session_user, pas le proprietaire de la fonction');
SELECT assert_egal(solde_de('postgres', 'T1'), 0::numeric, 'le proprietaire de la fonction ne recoit rien');

-- The whole list of what alice can execute: anything new must be added on purpose.
SELECT assert_egal((SELECT string_agg(proname, ' ' ORDER BY proname COLLATE "C") FROM pg_proc
                     WHERE pronamespace = 'public'::regnamespace AND prokind = 'f'
                       AND has_function_privilege('alice', oid, 'EXECUTE')),
                   'accumuler ajouter_liquidite assert_egal assert_leve assert_passe assert_vrai caisse cumule_a_jour deposer div_bas div_haut echanger '
                   'emprunter est_sain flash_swap liquider masse montant_sortie observer pool_weth prix prix_garantie prix_instantane prix_moyen q112 '
                   'racine_entiere rembourser retirer retirer_liquidite solde_de swap taux_emprunt transferer',
                   'liste exacte des fonctions executables par alice');
SELECT assert_vrai((SELECT bool_and(prosecdef) FROM pg_proc
                     WHERE proname IN ('transferer', 'swap', 'echanger', 'ajouter_liquidite', 'retirer_liquidite', 'flash_swap',
                                       'verifier_flash_swap', 'accumuler', 'deposer', 'retirer', 'emprunter', 'rembourser',
                                       'liquider', 'observer')), 'les points d''entree sont SECURITY DEFINER');
SELECT assert_vrai(NOT EXISTS (SELECT 1 FROM pg_proc
                     WHERE prosecdef AND pronamespace = 'public'::regnamespace
                       AND proname IN ('transferer', 'swap', 'echanger', 'ajouter_liquidite', 'retirer_liquidite', 'flash_swap',
                                       'verifier_flash_swap', 'accumuler', 'deposer', 'retirer', 'emprunter', 'rembourser',
                                       'liquider', 'observer')
                       AND (proconfig IS NULL OR NOT proconfig @> ARRAY['search_path=public, pg_temp'])),
                   'les points d''entree ont un search_path fige (pas de detournement par un schema de l''appelant)');

-- No write, trigger, reference or maintenance privilege on any relation, per table or per column, nor any use of a
-- sequence, for every role that is not a superuser or a built-in pg_ role; and nobody may create objects in the schema.
SELECT assert_vrai(count(*) > 0 AND NOT bool_or(
         CASE WHEN c.relkind = 'S' THEN has_sequence_privilege(r.oid, c.oid, 'USAGE, UPDATE')
              ELSE has_table_privilege(r.oid, c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
                   OR has_any_column_privilege(r.oid, c.oid, 'INSERT, UPDATE, REFERENCES') END),
                   'aucun role ordinaire : privilege d''ecriture, de trigger, de reference ou de maintenance sur une relation du schema')
  FROM pg_class c, pg_roles r
 WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
   AND NOT r.rolsuper AND r.rolname !~ '^pg_';
SELECT assert_vrai(count(*) > 0 AND NOT bool_or(has_schema_privilege(oid, 'public', 'CREATE')), 'aucun role ordinaire ne cree d''objet dans le schema')
  FROM pg_roles WHERE NOT rolsuper AND rolname !~ '^pg_';

-- The internal functions move balances or reserves without any check: no ordinary role may execute them.
SELECT assert_vrai(count(*) > 0 AND NOT bool_or(has_function_privilege(r.oid, f.oid, 'EXECUTE')),
                   'aucun role ordinaire n''execute une fonction interne')
  FROM pg_proc f, pg_roles r
 WHERE f.pronamespace = 'public'::regnamespace AND f.prokind = 'f'
   AND f.proname IN ('deplacer', 'frapper', 'maj_pool', 'avancer_bloc', 'creer_pool', 'creer_pret_pool', 'pool_verrouille',
                     'valider_swap', 'verifier_flash_swap', 'verrouiller_compte', 'verrouiller_prets', 'attendre_blocage')
   AND NOT r.rolsuper AND r.rolname !~ '^pg_';

-- A superuser is above all this: direct writes, and even the deferred trigger can be switched off.
RESET SESSION AUTHORIZATION;
WITH u AS (UPDATE pool SET frais_pour_mille = 3 WHERE id = 1 RETURNING 1)
SELECT assert_egal((SELECT count(*) FROM u), 1::bigint, 'superuser : UPDATE direct accepte');
ALTER TABLE flash_swap DISABLE TRIGGER flash_swap_rembourse;
SET SESSION AUTHORIZATION mallory;
BEGIN;
SELECT flash_swap(1, 0, 3e18);
COMMIT;
RESET SESSION AUTHORIZATION;
SELECT assert_egal(solde_de('mallory', 'T1'), 103e18, 'trigger desactive par un superuser : un flash swap jamais rembourse passe');
