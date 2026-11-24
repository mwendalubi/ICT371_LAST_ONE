-- =====================================================================
-- ICT371  Q7  WATER METER READINGS AND BILLING   (PostgreSQL)
-- Tariff: first 10 units K5 each, units above 10 cost K8 each.
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q07 CASCADE;
CREATE SCHEMA q07;
SET search_path TO q07, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

CREATE TABLE customers (
    customer_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        SERIAL PRIMARY KEY,
    customer_id       INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month     DATE          NOT NULL,
    previous_reading  NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT chk_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id      SERIAL PRIMARY KEY,
    reading_id   INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge       NUMERIC(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(10,2) NOT NULL DEFAULT 0,
    due_on       DATE          NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date  DATE PRIMARY KEY,
    total_due      NUMERIC(14,2) NOT NULL
);

-- ---------- (a) SEED: CUSTOMERS  [run now] ---------------------------
INSERT INTO customers (full_name) VALUES ('Kelvin Mwanza'), ('Linda Sichone'), ('Moses Kapambwe');

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);                      -- 0 units => K0
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);          -- K50 + K8 per extra unit
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev   NUMERIC;
    v_curr   NUMERIC;
    v_charge NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- ---------- (d) TRIGGER  [run after (a), BEFORE seeding readings] -----
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;       -- raising an exception means the row is never stored
END;
$$;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_reading();

-- ---------- (a) SEED: SIX READINGS  [run after (d)] -------------------
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100),    -- 0 units
    (1, DATE '2026-10-01', 100, 110),    -- exactly 10 units
    (2, DATE '2026-09-01',  50,  65),    -- 15 units
    (2, DATE '2026-10-01',  65,  70),    --  5 units
    (3, DATE '2026-09-01', 200, 212),    -- 12 units
    (3, DATE '2026-10-01', 212, 230);    -- 18 units

-- ---------- (a) SEED: BILLS VIA PROCEDURE  [run after (b),(c)] --------
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 20);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE - 20);
CALL pr_generate_bill(5, CURRENT_DATE -  5);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

UPDATE bills SET amount_paid = charge WHERE bill_id IN (1, 2);   -- fully paid
UPDATE bills SET amount_paid = 40     WHERE bill_id = 3;         -- part paid

-- ---------- (e) VIEW  [run after (a)] --------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Partial index: only UNPAID bills are indexed (fully paid bills never
-- appear in overdue searches), ordered by due_on for date comparisons.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE due_on < CURRENT_DATE AND amount_paid < charge;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule('refresh_receivables_daily', '30 0 * * *', $$CALL q07.pr_refresh_receivables()$$);

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                        -- rerun replaces the total
SELECT * FROM receivable_snapshot;

-- ---------- TESTS: errors are expected here ---------------------------
SELECT fn_water_charge(0) a, fn_water_charge(10) b, fn_water_charge(15) c, fn_water_charge(12.5) d;
DO $$ BEGIN PERFORM fn_water_charge(-1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(NULL);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);          -- already billed
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, DATE '2026-11-01', 110, 90);          -- direct import, rejected
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_stored FROM readings;            -- still 6
