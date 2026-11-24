-- =====================================================================
-- ICT371  Q9  FARMER COOPERATIVE MAIZE DELIVERIES   (PostgreSQL)
-- Rates: grade A K5/kg, grade B K4/kg, grade C K3/kg.
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q09 CASCADE;
CREATE SCHEMA q09;
SET search_path TO q09, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

CREATE TABLE farmers (
    farmer_id      SERIAL PRIMARY KEY,
    farmer_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL PRIMARY KEY,
    farmer_id     INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade         CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10,2) NOT NULL,       -- filled in by the trigger
    total_value   NUMERIC(12,2) NOT NULL,       -- filled in by the trigger
    delivered_on  DATE          NOT NULL,
    is_paid       BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date  DATE PRIMARY KEY,
    total_weight   NUMERIC(12,2) NOT NULL,
    total_value    NUMERIC(14,2) NOT NULL
);

-- ---------- (a) SEED: FARMERS  [run now] -----------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Bwalya Mukuka'),
    ('F002', 'Mutinta Hachile'),
    ('F003', 'Lweendo Sikazwe');      -- will have no unpaid deliveries

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;
    RETURN v_rate;
END;
$$;

-- ---------- (d) TRIGGER  [run after (b), BEFORE any delivery is added] -
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade::text);        -- one pricing rule for all SQL
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_price_delivery();

-- ---------- (c) PROCEDURE  [run after (b),(d)] ------------------------
-- Inserts only the basic fields; the trigger supplies unit_rate/total_value.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade TEXT,
                                                p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
    END IF;

    PERFORM fn_maize_rate(p_grade);                   -- rejects NULL / unsupported grade early

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ---------- (a) SEED: SIX DELIVERIES  [run after (d)] -----------------
-- Direct INSERTs WITHOUT rate/value: the trigger fills them in.
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100, CURRENT_DATE - 1, TRUE),
    (1, 'B',  50, CURRENT_DATE - 1, FALSE),
    (2, 'C', 200, CURRENT_DATE - 1, FALSE),
    (2, 'A',  80, CURRENT_DATE - 2, TRUE),
    (3, 'B',  60, CURRENT_DATE - 2, TRUE),
    (3, 'C',  40, CURRENT_DATE,     TRUE);

-- ---------- (e) VIEW  [run after (a)] --------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE   -- keeps farmers with none
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

SELECT * FROM v_farmer_amount_due;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Equality column first (farmer_id), range column second (delivered_on).
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE             -- replace, never add on top
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

SELECT cron.schedule('refresh_purchases_daily', '30 1 * * *',
                     $$CALL q09.pr_refresh_purchases(CURRENT_DATE - 1)$$);

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);          -- rerun replaces totals
SELECT * FROM daily_purchases;

-- ---------- TESTS: errors are expected here ---------------------------
CALL pr_receive_delivery(1, 'A', 10, CURRENT_DATE);                 -- valid
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries ORDER BY delivery_id DESC LIMIT 1;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -3, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)   -- direct SQL
            VALUES (1, 'B', 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
