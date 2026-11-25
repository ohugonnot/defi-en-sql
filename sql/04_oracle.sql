CREATE TABLE observation (
  pool_id      int NOT NULL REFERENCES pool,
  bloc         bigint NOT NULL,
  horodatage   bigint NOT NULL,
  prix0_cumule uint256 NOT NULL,
  prix1_cumule uint256 NOT NULL,
  PRIMARY KEY (pool_id, bloc)
);
-- prix_moyen filters and sorts by time, not by block.
CREATE INDEX ON observation (pool_id, horodatage);

-- 'moyen' is the safe default; the attack test flips it to 'instantane'.
CREATE TABLE config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  oracle    text NOT NULL DEFAULT 'moyen' CHECK (oracle IN ('instantane', 'moyen')),
  fenetre   int NOT NULL DEFAULT 720
);
INSERT INTO config DEFAULT VALUES;

-- Anyone can call it, like the maintenance script of the book. One observation per block.
CREATE FUNCTION observer(id_pool int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p pool; cumul record;
BEGIN
  PERFORM 1 FROM chaine FOR SHARE;
  SELECT * INTO p FROM pool WHERE id = id_pool FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POOL_INCONNU'; END IF;
  -- The cumulated price does not run while a reserve is 0, as in Uniswap v2: an empty pool must not start the window.
  IF p.reserve0 = 0 OR p.reserve1 = 0 THEN RETURN; END IF;
  SELECT * INTO cumul FROM cumule_a_jour(p);
  INSERT INTO observation SELECT id_pool, bloc, horodatage, cumul.prix0, cumul.prix1 FROM chaine
  ON CONFLICT DO NOTHING;
END $$;

-- Every priced token needs a pool against WETH, the unit of account.
CREATE FUNCTION pool_weth(un_jeton text) RETURNS pool LANGUAGE sql STABLE AS $$
  SELECT * FROM pool
   WHERE (jeton0 = un_jeton AND jeton1 = 'WETH') OR (jeton1 = un_jeton AND jeton0 = 'WETH')
   ORDER BY id LIMIT 1
$$;

CREATE FUNCTION prix_instantane(un_jeton text) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE p pool;
BEGIN
  IF un_jeton = 'WETH' THEN RETURN 1e18; END IF;
  p := pool_weth(un_jeton);
  IF p.id IS NULL OR p.reserve0 = 0 OR p.reserve1 = 0 THEN RAISE EXCEPTION 'PAS_DE_PRIX'; END IF;
  RETURN CASE WHEN p.jeton0 = un_jeton THEN div_bas(p.reserve1 * 1e18, p.reserve0)
              ELSE div_bas(p.reserve0 * 1e18, p.reserve1) END;
END $$;

-- Mean over the oldest observation inside the window. Refuses when maintenance is late
-- (window minus two 12 s blocks, as in the book).
CREATE FUNCTION prix_moyen(un_jeton text) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  p pool;
  fenetre_secondes int := (SELECT fenetre FROM config);
  maintenant bigint := (SELECT horodatage FROM chaine);
  debut observation;
  fin record;
  ecoule bigint;
BEGIN
  IF un_jeton = 'WETH' THEN RETURN 1e18; END IF;
  p := pool_weth(un_jeton);
  IF p.id IS NULL THEN RAISE EXCEPTION 'PAS_DE_PRIX'; END IF;
  SELECT * INTO debut FROM observation
   WHERE pool_id = p.id AND horodatage >= maintenant - fenetre_secondes ORDER BY horodatage LIMIT 1;
  IF NOT FOUND OR maintenant - debut.horodatage < fenetre_secondes - 24 THEN
    -- No observation old enough to cover the window: the pool is still bootstrapping, not late.
    IF NOT EXISTS (SELECT 1 FROM observation
                    WHERE pool_id = p.id AND horodatage <= maintenant - (fenetre_secondes - 24)) THEN
      RAISE EXCEPTION 'PAS_ENCORE_OBSERVE';
    END IF;
    RAISE EXCEPTION 'OBSERVATIONS_INSUFFISANTES';
  END IF;
  SELECT * INTO fin FROM cumule_a_jour(p);
  ecoule := maintenant - debut.horodatage;
  RETURN CASE WHEN p.jeton0 = un_jeton
              THEN div_bas((fin.prix0 - debut.prix0_cumule) * 1e18, ecoule * q112())
              ELSE div_bas((fin.prix1 - debut.prix1_cumule) * 1e18, ecoule * q112()) END;
END $$;

CREATE FUNCTION prix(un_jeton text) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT CASE (SELECT oracle FROM config)
           WHEN 'moyen' THEN prix_moyen(un_jeton)
           ELSE prix_instantane(un_jeton) END
$$;

-- A collateral we cannot price yet is worth 0: no borrowing power, and it blocks nobody. A gap in an established
-- series stays an error, and debt keeps the strict prix().
CREATE FUNCTION prix_garantie(un_jeton text) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN prix(un_jeton);
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM IN ('PAS_DE_PRIX', 'PAS_ENCORE_OBSERVE') THEN RETURN 0; END IF;
  RAISE;
END $$;
