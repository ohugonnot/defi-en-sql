-- Demo identities. In the tests, msg.sender is session_user (SET SESSION AUTHORIZATION changes it).
DO $$
DECLARE nom text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'utilisateur') THEN
    CREATE ROLE utilisateur NOLOGIN;
  END IF;
  FOREACH nom IN ARRAY ARRAY['alice', 'bob', 'mallory', 'liquidateur'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = nom) THEN
      EXECUTE format('CREATE ROLE %I LOGIN IN ROLE utilisateur', nom);
    END IF;
  END LOOP;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Pure or read-only helpers, and the test assertions.
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT oid::regprocedure FROM pg_proc
            WHERE pronamespace = 'public'::regnamespace AND prokind = 'f'
              AND proname IN ('div_bas', 'div_haut', 'racine_entiere', 'q112', 'solde_de', 'caisse', 'masse',
                              'montant_sortie', 'cumule_a_jour', 'pool_weth', 'prix', 'prix_garantie', 'prix_instantane',
                              'prix_moyen', 'est_sain', 'taux_emprunt', 'assert_egal', 'assert_vrai', 'assert_leve', 'assert_passe')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', f);
  END LOOP;

  -- Entry points. They run as their owner and read session_user as the caller.
  FOR f IN SELECT oid::regprocedure FROM pg_proc
            WHERE pronamespace = 'public'::regnamespace AND prokind = 'f'
              AND proname IN ('transferer', 'swap', 'echanger', 'ajouter_liquidite', 'retirer_liquidite',
                              'flash_swap', 'verifier_flash_swap', 'accumuler', 'deposer', 'retirer',
                              'emprunter', 'rembourser', 'liquider', 'observer')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = public, pg_temp', f);
    IF f::text NOT LIKE 'verifier_flash_swap%' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO utilisateur', f);
    END IF;
  END LOOP;
END $$;
