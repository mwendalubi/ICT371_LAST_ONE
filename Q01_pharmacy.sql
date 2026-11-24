-- =====================================================================
-- ICT371  Q1  PHARMACY STOCK AND DAILY SALES   (PostgreSQL)
-- Run the file top to bottom. Sections are in the order they must run.
-- pg_cron needs:  CREATE EXTENSION IF NOT EXISTS pg_cron;  (once)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q01 CASCADE;
CREATE SCHEMA q01;
SET search_path TO q01, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

CREATE TABLE medicines (
    medicine_id    SERIAL PRIMARY KEY,
    medicine_name  VARCHAR(100)  NOT NULL,
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),   -- positive prices
    stock_qty      INTEGER       NOT NULL CHECK (stock_qty >= 0)    -- non-negative stock
);

CREATE TABLE sales (
    sale_id      SERIAL PRIMARY KEY,
    medicine_id  INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity     INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),     -- price at time of sale
    sold_on      DATE          NOT NULL
);

CREATE TABLE stock_audit (
    audit_id     SERIAL PRIMARY KEY,
    medicine_id  INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty      INTEGER   NOT NULL,
    new_qty      INTEGER   NOT NULL,
    changed_at   TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date    DATE PRIMARY KEY,
    total_qty     INTEGER       NOT NULL,
    total_amount  NUMERIC(12,2) NOT NULL
);

-- ---------- (a) SEED: MEDICINES  [run now] ---------------------------
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('Cough Syrup',      15.00,  12);

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC;
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    -- lock the row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines SET stock_qty = stock_qty - p_quantity      -- deducted exactly once
    WHERE medicine_id = p_medicine_id;
    -- any RAISE above aborts the CALL, so neither table changes on a bad sale
END;
$$;

-- ---------- (d) TRIGGER  [run after (c)] ------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN        -- only on real change
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------- (a) SEED: SIX SALES VIA THE PROCEDURE  [run after (d)] ----
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2,  4, CURRENT_DATE - 1);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(2,  2, CURRENT_DATE);
CALL pr_record_sale(3,  4, CURRENT_DATE);

-- ---------- (e) VIEW  [run after (a)] ---------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(3, 2, CURRENT_DATE);        -- Cough Syrup drops to 3
SELECT * FROM v_low_stock;                      -- query the view after a sale

-- ---------- (f) INDEX  [run after (a)] --------------------------------
-- Query: one medicine's sales in a date range -> equality column first
-- (medicine_id), range column second (sold_on). One index serves both.
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);

SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] -----------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE                -- replace, never add on top
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- 00:15 every day, for the previous day (pg_cron times are UTC by default)
SELECT cron.schedule('refresh_sales_daily', '15 0 * * *',
                     $$CALL q01.pr_refresh_sales(CURRENT_DATE - 1)$$);

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);              -- rerun: no double counting
SELECT * FROM daily_sales;

-- ---------- TESTS: errors are expected here ----------------------------
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_sale(1, 100000, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;
SELECT * FROM stock_audit ORDER BY audit_id;
