CREATE DOMAIN uint256 AS numeric(78,0)
  CHECK (VALUE BETWEEN 0 AND 115792089237316195423570985008687907853269984665640564039457584007913129639935);
CREATE DOMAIN uint112 AS numeric(34,0)
  CHECK (VALUE BETWEEN 0 AND 5192296858534827628530496329220095);

-- The numeric division operator rounds to nearest (2e18 over 3 ends in ...667); div() truncates (...666).
CREATE FUNCTION div_bas(a numeric, b numeric) RETURNS numeric
  LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT div(a, b) $$;
CREATE FUNCTION div_haut(a numeric, b numeric) RETURNS numeric
  LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT div(a + b - 1, b) $$;

-- sqrt() rounds too: floor(sqrt(n*n - 1)) returns n for large n, so fix the guess by hand.
CREATE FUNCTION racine_entiere(x numeric) RETURNS numeric
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r numeric := floor(sqrt(x));
BEGIN
  WHILE r * r > x LOOP r := r - 1; END LOOP;
  WHILE (r + 1) * (r + 1) <= x LOOP r := r + 1; END LOOP;
  RETURN r;
END $$;

-- UQ112x112 scale. "2^112" with integer literals would be float8.
CREATE FUNCTION q112() RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT 2::numeric ^ 112 $$;

-- Simulated time: it only moves when avancer_bloc is called. Never now().
CREATE TABLE chaine (
  singleton  boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  bloc       bigint NOT NULL,
  horodatage bigint NOT NULL
);
INSERT INTO chaine VALUES (true, 0, 1000000);

CREATE FUNCTION avancer_bloc(n int, secondes int DEFAULT 12) RETURNS void
  LANGUAGE sql AS $$
  UPDATE chaine SET bloc = bloc + n, horodatage = horodatage + n * secondes
$$;

CREATE TABLE jeton (
  symbole   text PRIMARY KEY,
  decimales smallint NOT NULL DEFAULT 18
);

-- Pools and lending vaults are accounts too ('pool:1', 'pret:WETH'): the sum per token is a global invariant.
CREATE TABLE solde (
  compte  text NOT NULL,
  jeton   text NOT NULL REFERENCES jeton,
  montant uint256 NOT NULL DEFAULT 0,
  PRIMARY KEY (compte, jeton)
);

CREATE FUNCTION solde_de(un_compte text, un_jeton text) RETURNS numeric
  LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT montant FROM solde WHERE compte = un_compte AND jeton = un_jeton), 0)
$$;

CREATE FUNCTION frapper(un_compte text, un_jeton text, combien uint256) RETURNS void
  LANGUAGE sql AS $$
  INSERT INTO solde VALUES (un_compte, un_jeton, combien)
  ON CONFLICT (compte, jeton) DO UPDATE SET montant = solde.montant + EXCLUDED.montant
$$;

CREATE FUNCTION deplacer(de text, vers text, un_jeton text, combien numeric) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  IF combien = 0 THEN RETURN; END IF;
  UPDATE solde SET montant = montant - combien
   WHERE compte = de AND jeton = un_jeton AND montant >= combien;
  IF NOT FOUND THEN RAISE EXCEPTION 'SOLDE_INSUFFISANT'; END IF;
  PERFORM frapper(vers, un_jeton, combien);
END $$;

-- Like ERC-20 transfer: the sender is whoever opened the session.
CREATE FUNCTION transferer(vers text, un_jeton text, combien uint256) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  IF vers LIKE 'pret:%' THEN RAISE EXCEPTION 'TRANSFERT_VERS_COFFRE'; END IF;
  PERFORM deplacer(session_user::text, vers, un_jeton, combien);
END $$;

CREATE FUNCTION caisse(id_pool int) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$ SELECT 'pool:' || id_pool $$;

CREATE FUNCTION masse() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(jsonb_object_agg(jeton, total), '{}')
  FROM (SELECT jeton, sum(montant) AS total FROM solde GROUP BY jeton) t
$$;

CREATE FUNCTION assert_egal(reel anycompatible, attendu anycompatible, message text) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  IF reel IS DISTINCT FROM attendu THEN
    RAISE EXCEPTION 'ECHEC % : attendu %, obtenu %', message, attendu, reel;
  END IF;
  RAISE NOTICE 'ok %', message;
END $$;

CREATE FUNCTION assert_vrai(condition boolean, message text) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS NOT TRUE THEN RAISE EXCEPTION 'ECHEC %', message; END IF;
  RAISE NOTICE 'ok %', message;
END $$;

-- motif: a SQLSTATE or a substring of the error message.
CREATE FUNCTION assert_leve(requete text, motif text, message text) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE requete;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = motif OR position(motif IN SQLERRM) > 0 THEN
      RAISE NOTICE 'ok %', message;
      RETURN;
    END IF;
    RAISE EXCEPTION 'ECHEC % : erreur % (%), attendu %', message, SQLSTATE, SQLERRM, motif;
  END;
  RAISE EXCEPTION 'ECHEC % : aucune erreur, attendu %', message, motif;
END $$;

-- The statement must succeed: its effects stay, any error is reported as a failed assertion.
CREATE FUNCTION assert_passe(requete text, message text) RETURNS void
  LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE requete;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ECHEC % : erreur % (%)', message, SQLSTATE, SQLERRM;
  END;
  RAISE NOTICE 'ok %', message;
END $$;

-- Test helper for dblink sessions: spins until backend `pid` waits on a lock, fails if its query ends first.
CREATE FUNCTION attendre_blocage(connexion text, pid int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE tours bigint := 0;
BEGIN
  WHILE cardinality(pg_blocking_pids(pid)) = 0 LOOP
    IF dblink_is_busy(connexion) = 0 THEN RAISE EXCEPTION 'ECHEC % a termine sans attendre de verrou', connexion; END IF;
    tours := tours + 1;
    IF tours > 50000000 THEN RAISE EXCEPTION 'ECHEC % ni bloque ni termine', connexion; END IF;
  END LOOP;
END $$;
