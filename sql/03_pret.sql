-- Rates and ratios use a 1e18 scale (1e18 = 100 %).
CREATE TABLE pret_pool (
  jeton                text PRIMARY KEY REFERENCES jeton,
  total_emprunte       uint256 NOT NULL DEFAULT 0,
  parts_depot_total    uint256 NOT NULL DEFAULT 0,
  parts_dette_total    uint256 NOT NULL DEFAULT 0,
  horodatage_interets  bigint NOT NULL,
  taux_base            uint256 NOT NULL,
  ecart_optimal        uint256 NOT NULL,
  ecart_exces          uint256 NOT NULL,
  utilisation_optimale uint256 NOT NULL CHECK (utilisation_optimale BETWEEN 1 AND 999999999999999999),
  taux_garantie        uint256 NOT NULL,
  prime_liquidation    uint256 NOT NULL,
  close_factor         uint256 NOT NULL
);

CREATE TABLE pret_position (
  compte      text NOT NULL,
  jeton       text NOT NULL REFERENCES pret_pool,
  parts_depot uint256 NOT NULL DEFAULT 0,
  parts_dette uint256 NOT NULL DEFAULT 0,
  PRIMARY KEY (compte, jeton)
);

-- Defaults: the book's rate model (lesson 85). The 80 % kink is the value the book reads on the dashboard of the Aave v2 ETH pool.
CREATE FUNCTION creer_pret_pool(un_jeton text, taux_garantie numeric DEFAULT 0.8e18,
    prime_liquidation numeric DEFAULT 1.1e18, close_factor numeric DEFAULT 0.5e18) RETURNS void
  LANGUAGE sql AS $$
  INSERT INTO pret_pool (jeton, horodatage_interets, taux_base, ecart_optimal, ecart_exces,
                         utilisation_optimale, taux_garantie, prime_liquidation, close_factor)
  SELECT un_jeton, horodatage, 0.01e18, 0.08e18, 0.51e18, 0.8e18,
         taux_garantie, prime_liquidation, close_factor FROM chaine
$$;

-- Borrow rate at a given utilisation: a gentle line up to the kink, a steep one after it.
CREATE FUNCTION taux_emprunt(utilisation numeric, p pret_pool) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT p.taux_base + CASE WHEN utilisation <= p.utilisation_optimale
    THEN div_bas(p.ecart_optimal * utilisation, p.utilisation_optimale)
    ELSE p.ecart_optimal + div_bas(p.ecart_exces * (utilisation - p.utilisation_optimale),
                                   1e18 - p.utilisation_optimale)
  END
$$;

CREATE VIEW v_taux AS
SELECT jeton, utilisation, taux AS taux_emprunt, div_bas(utilisation * taux, 1e18) AS taux_preteur
FROM (SELECT p.jeton, u.utilisation, taux_emprunt(u.utilisation, p) AS taux
      FROM pret_pool p
      CROSS JOIN LATERAL (SELECT CASE WHEN p.total_emprunte = 0 THEN 0
             ELSE div_bas(p.total_emprunte * 1e18,
                          p.total_emprunte + solde_de('pret:' || p.jeton, p.jeton)) END AS utilisation) u) t;

-- Interest not yet booked. Simple over the elapsed period (31 536 000 s a year), compounded at each booking, as in Compound.
CREATE VIEW v_pret_a_jour AS
SELECT p.jeton, p.parts_depot_total, p.parts_dette_total, d.interets,
       p.total_emprunte + d.interets AS dette_totale,
       solde_de('pret:' || p.jeton, p.jeton) + p.total_emprunte + d.interets AS depot_total
FROM pret_pool p
JOIN v_taux t USING (jeton)
CROSS JOIN chaine c
CROSS JOIN LATERAL (SELECT div_haut(p.total_emprunte * t.taux_emprunt * (c.horodatage - p.horodatage_interets),
                                    1e18 * 31536000) AS interets) d;

-- The health check reads the account's rows in every vault, which the vault row locks do not cover.
-- One row per account, written on every call: READ COMMITTED waits and re-reads, REPEATABLE READ and
-- SERIALIZABLE get 40001 (an advisory lock would not refresh the snapshot). Always taken before any vault lock.
CREATE TABLE compte (nom text PRIMARY KEY, version bigint NOT NULL);

CREATE FUNCTION verrouiller_compte(un_compte text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO compte (nom, version) VALUES (un_compte, 1)
  ON CONFLICT (nom) DO UPDATE SET version = compte.version + 1
$$;

-- Vault locks in key order, so two calls asking for the same vaults in different orders cannot deadlock.
CREATE FUNCTION verrouiller_prets(VARIADIC jetons text[]) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM pret_pool WHERE jeton = ANY (jetons) ORDER BY jeton FOR UPDATE;
  IF (SELECT count(*) FROM pret_pool WHERE jeton = ANY (jetons)) <> (SELECT count(DISTINCT j) FROM unnest(jetons) j) THEN
    RAISE EXCEPTION 'PRET_POOL_INCONNU';
  END IF;
END $$;

-- One UPDATE on pret_pool books the interest of everyone; positions hold shares and are never touched.
CREATE FUNCTION accumuler(jeton_pret text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM verrouiller_prets(jeton_pret);
  UPDATE pret_pool p SET total_emprunte = a.dette_totale, horodatage_interets = c.horodatage
    FROM v_pret_a_jour a, chaine c
   WHERE p.jeton = jeton_pret AND a.jeton = p.jeton AND c.horodatage > p.horodatage_interets;
END $$;

CREATE FUNCTION deposer(jeton_pret text, montant uint256) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE a v_pret_a_jour; parts numeric;
BEGIN
  PERFORM accumuler(jeton_pret);
  SELECT * INTO a FROM v_pret_a_jour WHERE jeton = jeton_pret;
  parts := CASE WHEN a.parts_depot_total = 0 THEN montant
                ELSE div_bas(montant * a.parts_depot_total, a.depot_total) END;
  IF parts = 0 THEN RAISE EXCEPTION 'PARTS_NULLES'; END IF;
  PERFORM deplacer(session_user::text, 'pret:' || jeton_pret, jeton_pret, montant);
  UPDATE pret_pool SET parts_depot_total = parts_depot_total + parts WHERE jeton = jeton_pret;
  INSERT INTO pret_position (compte, jeton, parts_depot) VALUES (session_user, jeton_pret, parts)
  ON CONFLICT (compte, jeton) DO UPDATE SET parts_depot = pret_position.parts_depot + EXCLUDED.parts_depot;
  RETURN parts;
END $$;

CREATE FUNCTION retirer(jeton_pret text, parts uint256) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE a v_pret_a_jour; montant numeric;
BEGIN
  PERFORM verrouiller_compte(session_user::text);
  PERFORM accumuler(jeton_pret);
  SELECT * INTO a FROM v_pret_a_jour WHERE jeton = jeton_pret;
  montant := div_bas(parts * a.depot_total, a.parts_depot_total);
  UPDATE pret_position SET parts_depot = parts_depot - retirer.parts
   WHERE compte = session_user AND jeton = jeton_pret AND parts_depot >= retirer.parts;
  IF NOT FOUND THEN RAISE EXCEPTION 'PARTS_INSUFFISANTES'; END IF;
  UPDATE pret_pool SET parts_depot_total = parts_depot_total - retirer.parts WHERE jeton = jeton_pret;
  PERFORM deplacer('pret:' || jeton_pret, session_user::text, jeton_pret, montant);
  IF NOT est_sain(session_user::text) THEN RAISE EXCEPTION 'ACCOUNT_UNHEALTHY'; END IF;
  RETURN montant;
END $$;

CREATE FUNCTION emprunter(jeton_pret text, montant uint256) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE a v_pret_a_jour; parts numeric;
BEGIN
  PERFORM verrouiller_compte(session_user::text);
  PERFORM accumuler(jeton_pret);
  SELECT * INTO a FROM v_pret_a_jour WHERE jeton = jeton_pret;
  parts := CASE WHEN a.parts_dette_total = 0 THEN montant
                ELSE div_haut(montant * a.parts_dette_total, a.dette_totale) END;
  UPDATE pret_pool SET total_emprunte = total_emprunte + montant,
                       parts_dette_total = parts_dette_total + parts WHERE jeton = jeton_pret;
  INSERT INTO pret_position (compte, jeton, parts_dette) VALUES (session_user, jeton_pret, parts)
  ON CONFLICT (compte, jeton) DO UPDATE SET parts_dette = pret_position.parts_dette + EXCLUDED.parts_dette;
  PERFORM deplacer('pret:' || jeton_pret, session_user::text, jeton_pret, montant);
  IF NOT est_sain(session_user::text) THEN RAISE EXCEPTION 'ACCOUNT_UNHEALTHY'; END IF;
  RETURN parts;
END $$;

-- Repays by shares, like the book's repayByShare (a name of the book, not of Aave v2). The amount owed is rounded up.
CREATE FUNCTION rembourser(jeton_pret text, parts uint256) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE a v_pret_a_jour; montant numeric;
BEGIN
  PERFORM accumuler(jeton_pret);
  SELECT * INTO a FROM v_pret_a_jour WHERE jeton = jeton_pret;
  montant := div_haut(parts * a.dette_totale, a.parts_dette_total);
  UPDATE pret_position SET parts_dette = parts_dette - rembourser.parts
   WHERE compte = session_user AND jeton = jeton_pret AND parts_dette >= rembourser.parts;
  IF NOT FOUND THEN RAISE EXCEPTION 'PARTS_INSUFFISANTES'; END IF;
  UPDATE pret_pool SET total_emprunte = total_emprunte - montant,
                       parts_dette_total = parts_dette_total - rembourser.parts WHERE jeton = jeton_pret;
  PERFORM deplacer(session_user::text, 'pret:' || jeton_pret, jeton_pret, montant);
  RETURN montant;
END $$;
