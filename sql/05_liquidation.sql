CREATE VIEW v_position AS
SELECT pos.compte, pos.jeton, p.taux_garantie,
       CASE WHEN pos.parts_depot = 0 THEN 0
            ELSE div_bas(pos.parts_depot * a.depot_total, a.parts_depot_total) END AS depot,
       CASE WHEN pos.parts_dette = 0 THEN 0
            ELSE div_haut(pos.parts_dette * a.dette_totale, a.parts_dette_total) END AS dette
FROM pret_position pos
JOIN pret_pool p USING (jeton)
JOIN v_pret_a_jour a USING (jeton);

-- Values are in WETH (1e18 scale). The book calls the ratio collateralRate: it is both
-- the borrow limit (LTV) and the liquidation threshold. The POC follows the book.
CREATE VIEW v_compte AS
SELECT v.compte,
       SUM(div_bas(div_bas(v.depot * x.prix, 1e18) * v.taux_garantie, 1e18)) AS max_empruntable,
       SUM(div_haut(v.dette * x.prix, 1e18)) AS dette
FROM v_position v
CROSS JOIN LATERAL (SELECT prix(v.jeton) AS prix) x
WHERE v.depot > 0 OR v.dette > 0
GROUP BY v.compte;

CREATE VIEW v_compte_malsain AS
SELECT * FROM v_compte WHERE dette > max_empruntable;

CREATE FUNCTION est_sain(un_compte text) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT NOT EXISTS (SELECT 1 FROM v_compte_malsain WHERE compte = un_compte)
$$;

-- The liquidator repays `parts` of the debtor's debt and receives deposit shares of the collateral
-- worth the repaid value times the premium, rounded down: never a wei too much. Returns the amount repaid.
CREATE FUNCTION liquider(debiteur text, jeton_dette text, jeton_collateral text, parts uint256)
  RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
  dette_pool pret_pool; collat_pool pret_pool;
  a_dette v_pret_a_jour; a_collat v_pret_a_jour;
  parts_max numeric; paiement numeric; saisie numeric; parts_saisies numeric;
BEGIN
  PERFORM verrouiller_compte(debiteur);
  PERFORM verrouiller_prets(jeton_dette, jeton_collateral);
  PERFORM accumuler(jeton_dette);
  PERFORM accumuler(jeton_collateral);
  IF est_sain(debiteur) THEN RAISE EXCEPTION 'ACCOUNT_HEALTHY'; END IF;
  SELECT * INTO dette_pool FROM pret_pool WHERE jeton = jeton_dette;
  SELECT * INTO collat_pool FROM pret_pool WHERE jeton = jeton_collateral;
  SELECT * INTO a_dette FROM v_pret_a_jour WHERE jeton = jeton_dette;
  SELECT * INTO a_collat FROM v_pret_a_jour WHERE jeton = jeton_collateral;
  SELECT div_bas(parts_dette * dette_pool.close_factor, 1e18) INTO parts_max
    FROM pret_position WHERE compte = debiteur AND jeton = jeton_dette FOR UPDATE;
  IF parts_max IS NULL OR parts > parts_max THEN RAISE EXCEPTION 'CLOSE_FACTOR'; END IF;
  paiement := div_haut(parts * a_dette.dette_totale, a_dette.parts_dette_total);
  saisie := div_bas(paiement * prix(jeton_dette) * collat_pool.prime_liquidation,
                    prix(jeton_collateral) * 1e18);
  parts_saisies := div_bas(saisie * a_collat.parts_depot_total, a_collat.depot_total);
  UPDATE pret_position SET parts_depot = parts_depot - parts_saisies
   WHERE compte = debiteur AND jeton = jeton_collateral AND parts_depot >= parts_saisies;
  IF NOT FOUND THEN RAISE EXCEPTION 'COLLATERAL_INSUFFISANT'; END IF;
  UPDATE pret_position SET parts_dette = parts_dette - liquider.parts
   WHERE compte = debiteur AND jeton = jeton_dette;
  UPDATE pret_pool SET total_emprunte = total_emprunte - paiement,
                       parts_dette_total = parts_dette_total - liquider.parts WHERE jeton = jeton_dette;
  PERFORM deplacer(session_user::text, 'pret:' || jeton_dette, jeton_dette, paiement);
  INSERT INTO pret_position (compte, jeton, parts_depot) VALUES (session_user, jeton_collateral, parts_saisies)
  ON CONFLICT (compte, jeton) DO UPDATE SET parts_depot = pret_position.parts_depot + EXCLUDED.parts_depot;
  RETURN paiement;
END $$;
