CREATE TABLE pool (
  id                 serial PRIMARY KEY,
  jeton0             text NOT NULL REFERENCES jeton,
  jeton1             text NOT NULL REFERENCES jeton,
  reserve0           uint112 NOT NULL DEFAULT 0,
  reserve1           uint112 NOT NULL DEFAULT 0,
  horodatage_dernier bigint NOT NULL,
  prix0_cumule       uint256 NOT NULL DEFAULT 0,
  prix1_cumule       uint256 NOT NULL DEFAULT 0,
  parts_total        uint256 NOT NULL DEFAULT 0,
  frais_pour_mille   int NOT NULL DEFAULT 3 CHECK (frais_pour_mille BETWEEN 0 AND 999),
  CHECK (jeton0 <> jeton1)
);

CREATE TABLE part_lp (
  pool_id int NOT NULL REFERENCES pool,
  compte  text NOT NULL,
  parts   uint256 NOT NULL,
  PRIMARY KEY (pool_id, compte)
);

CREATE FUNCTION creer_pool(un_jeton0 text, un_jeton1 text, frais int DEFAULT 3) RETURNS int
  LANGUAGE sql AS $$
  INSERT INTO pool (jeton0, jeton1, horodatage_dernier, frais_pour_mille)
  SELECT un_jeton0, un_jeton1, horodatage, frais FROM chaine
  RETURNING id
$$;

CREATE FUNCTION pool_verrouille(id_pool int) RETURNS pool LANGUAGE plpgsql AS $$
DECLARE p pool;
BEGIN
  SELECT * INTO p FROM pool WHERE id = id_pool FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POOL_INCONNU'; END IF;
  RETURN p;
END $$;

-- getAmountOut of Uniswap v2, rounded down so the pool never pays a wei too much.
CREATE FUNCTION montant_sortie(entree numeric, reserve_entree numeric, reserve_sortie numeric,
                               frais_pour_mille int DEFAULT 3) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT div_bas(entree * (1000 - frais_pour_mille) * reserve_sortie,
                 reserve_entree * 1000 + entree * (1000 - frais_pour_mille))
$$;

CREATE FUNCTION cumule_a_jour(p pool, OUT prix0 numeric, OUT prix1 numeric)
  LANGUAGE plpgsql STABLE AS $$
DECLARE ecoule bigint := (SELECT horodatage FROM chaine) - p.horodatage_dernier;
BEGIN
  prix0 := p.prix0_cumule;
  prix1 := p.prix1_cumule;
  IF ecoule > 0 AND p.reserve0 > 0 AND p.reserve1 > 0 THEN
    prix0 := prix0 + div_bas(p.reserve1 * q112(), p.reserve0) * ecoule;
    prix1 := prix1 + div_bas(p.reserve0 * q112(), p.reserve1) * ecoule;
  END IF;
END $$;

-- Like Uniswap _update: the first call of a block prices the elapsed time with the OLD reserves.
CREATE FUNCTION maj_pool(p pool, nouveau0 numeric, nouveau1 numeric) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE cumul record;
BEGIN
  SELECT * INTO cumul FROM cumule_a_jour(p);
  UPDATE pool SET reserve0 = nouveau0, reserve1 = nouveau1,
                  prix0_cumule = cumul.prix0, prix1_cumule = cumul.prix1,
                  horodatage_dernier = (SELECT horodatage FROM chaine)
   WHERE id = p.id;
END $$;

-- UniswapV2Pair.swap after the output left: K check on fee-adjusted balances, then reserves := balances.
CREATE FUNCTION valider_swap(p pool, sortie0 numeric, sortie1 numeric) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE
  solde0 numeric := solde_de(caisse(p.id), p.jeton0);
  solde1 numeric := solde_de(caisse(p.id), p.jeton1);
  entree0 numeric := GREATEST(solde0 - (p.reserve0 - sortie0), 0);
  entree1 numeric := GREATEST(solde1 - (p.reserve1 - sortie1), 0);
BEGIN
  IF entree0 = 0 AND entree1 = 0 THEN RAISE EXCEPTION 'INSUFFICIENT_INPUT_AMOUNT'; END IF;
  IF (solde0 * 1000 - entree0 * p.frais_pour_mille) * (solde1 * 1000 - entree1 * p.frais_pour_mille)
       < p.reserve0 * p.reserve1 * 1000000 THEN
    RAISE EXCEPTION 'UniswapV2: K';
  END IF;
  PERFORM maj_pool(p, solde0, solde1);
END $$;

-- Low-level swap: the caller sends the input to the pool first, as with UniswapV2Pair.swap.
CREATE FUNCTION swap(id_pool int, sortie0 uint256, sortie1 uint256) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE p pool := pool_verrouille(id_pool);
BEGIN
  IF sortie0 = 0 AND sortie1 = 0 THEN RAISE EXCEPTION 'INSUFFICIENT_OUTPUT_AMOUNT'; END IF;
  IF sortie0 >= p.reserve0 OR sortie1 >= p.reserve1 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY'; END IF;
  PERFORM deplacer(caisse(id_pool), session_user::text, p.jeton0, sortie0);
  PERFORM deplacer(caisse(id_pool), session_user::text, p.jeton1, sortie1);
  PERFORM valider_swap(p, sortie0, sortie1);
END $$;

CREATE FUNCTION echanger(id_pool int, jeton_entree text, entree uint256, sortie_min uint256 DEFAULT 0)
  RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
  p pool := pool_verrouille(id_pool);
  achat_de_jeton1 boolean := jeton_entree = p.jeton0;
  sortie numeric;
BEGIN
  IF NOT achat_de_jeton1 AND jeton_entree <> p.jeton1 THEN RAISE EXCEPTION 'JETON_INCONNU'; END IF;
  sortie := CASE WHEN achat_de_jeton1
                 THEN montant_sortie(entree, p.reserve0, p.reserve1, p.frais_pour_mille)
                 ELSE montant_sortie(entree, p.reserve1, p.reserve0, p.frais_pour_mille) END;
  IF sortie < sortie_min THEN RAISE EXCEPTION 'INSUFFICIENT_OUTPUT_AMOUNT'; END IF;
  PERFORM deplacer(session_user::text, caisse(id_pool), jeton_entree, entree);
  PERFORM swap(id_pool, CASE WHEN achat_de_jeton1 THEN 0 ELSE sortie END,
                        CASE WHEN achat_de_jeton1 THEN sortie ELSE 0 END);
  RETURN sortie;
END $$;

-- First deposit: sqrt(x*y) minus 1000 parts locked on a dead account, so the pool can never be emptied.
CREATE FUNCTION ajouter_liquidite(id_pool int, montant0 uint256, montant1 uint256) RETURNS numeric
  LANGUAGE plpgsql AS $$
DECLARE
  p pool := pool_verrouille(id_pool);
  parts numeric;
  parts_bloquees numeric := 0;
BEGIN
  IF p.parts_total = 0 THEN
    parts_bloquees := 1000;
    parts := racine_entiere(montant0 * montant1) - parts_bloquees;
  ELSE
    parts := LEAST(div_bas(montant0 * p.parts_total, p.reserve0),
                   div_bas(montant1 * p.parts_total, p.reserve1));
  END IF;
  IF parts <= 0 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY_MINTED'; END IF;
  PERFORM deplacer(session_user::text, caisse(id_pool), p.jeton0, montant0);
  PERFORM deplacer(session_user::text, caisse(id_pool), p.jeton1, montant1);
  IF parts_bloquees > 0 THEN
    INSERT INTO part_lp VALUES (id_pool, '0x000000000000000000000000000000000000dEaD', parts_bloquees);
  END IF;
  INSERT INTO part_lp VALUES (id_pool, session_user, parts)
  ON CONFLICT (pool_id, compte) DO UPDATE SET parts = part_lp.parts + EXCLUDED.parts;
  UPDATE pool SET parts_total = parts_total + parts + parts_bloquees WHERE id = id_pool;
  PERFORM maj_pool(p, solde_de(caisse(id_pool), p.jeton0), solde_de(caisse(id_pool), p.jeton1));
  RETURN parts;
END $$;

CREATE FUNCTION retirer_liquidite(id_pool int, a_retirer uint256) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE
  p pool := pool_verrouille(id_pool);
  solde0 numeric := solde_de(caisse(id_pool), p.jeton0);
  solde1 numeric := solde_de(caisse(id_pool), p.jeton1);
  sortie0 numeric := div_bas(a_retirer * solde0, p.parts_total);
  sortie1 numeric := div_bas(a_retirer * solde1, p.parts_total);
BEGIN
  IF sortie0 = 0 OR sortie1 = 0 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY_BURNED'; END IF;
  UPDATE part_lp SET parts = parts - a_retirer
   WHERE pool_id = id_pool AND compte = session_user AND parts >= a_retirer;
  IF NOT FOUND THEN RAISE EXCEPTION 'PARTS_INSUFFISANTES'; END IF;
  UPDATE pool SET parts_total = parts_total - a_retirer WHERE id = id_pool;
  PERFORM deplacer(caisse(id_pool), session_user::text, p.jeton0, sortie0);
  PERFORM deplacer(caisse(id_pool), session_user::text, p.jeton1, sortie1);
  PERFORM maj_pool(p, solde0 - sortie0, solde1 - sortie1);
END $$;
