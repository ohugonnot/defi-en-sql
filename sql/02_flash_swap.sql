CREATE TABLE flash_swap (
  id             bigserial PRIMARY KEY,
  pool_id        int NOT NULL REFERENCES pool,
  compte         text NOT NULL,
  sortie0        uint256 NOT NULL,
  sortie1        uint256 NOT NULL
);

-- The tokens leave now; the repayment is checked at COMMIT by the deferred trigger below.
CREATE FUNCTION flash_swap(id_pool int, sortie0 uint256, sortie1 uint256) RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE p pool := pool_verrouille(id_pool);
BEGIN
  IF sortie0 = 0 AND sortie1 = 0 THEN RAISE EXCEPTION 'INSUFFICIENT_OUTPUT_AMOUNT'; END IF;
  IF sortie0 >= p.reserve0 OR sortie1 >= p.reserve1 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY'; END IF;
  PERFORM deplacer(caisse(id_pool), session_user::text, p.jeton0, sortie0);
  PERFORM deplacer(caisse(id_pool), session_user::text, p.jeton1, sortie1);
  -- Before the insert: under SET CONSTRAINTS IMMEDIATE the check runs at the end of the insert and clears the flag.
  UPDATE pool SET flash_en_cours = true WHERE id = id_pool;
  INSERT INTO flash_swap (pool_id, compte, sortie0, sortie1)
  VALUES (id_pool, session_user, sortie0, sortie1);
END $$;

CREATE FUNCTION verifier_flash_swap() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p pool;
BEGIN
  -- The row is already locked by flash_swap in this transaction; pool_verrouille would refuse the flag.
  SELECT * INTO p FROM pool WHERE id = NEW.pool_id;
  UPDATE pool SET flash_en_cours = false WHERE id = NEW.pool_id;
  PERFORM valider_swap(p, NEW.sortie0, NEW.sortie1);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER flash_swap_rembourse
  AFTER INSERT ON flash_swap
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION verifier_flash_swap();
