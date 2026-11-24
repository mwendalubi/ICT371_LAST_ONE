-- =====================================================================
-- ICT371  Q2  UNIVERSITY FEE PAYMENTS   (PostgreSQL)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q02 CASCADE;
CREATE SCHEMA q02;
SET search_path TO q02, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

CREATE TABLE students (
    student_id      SERIAL PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  SERIAL PRIMARY KEY,
    student_id  INTEGER       NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on     DATE          NOT NULL
);

CREATE TABLE payment_audit (
    audit_id    SERIAL PRIMARY KEY,
    payment_id  INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id  INTEGER       NOT NULL REFERENCES students(student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date  DATE PRIMARY KEY,
    payment_count    INTEGER       NOT NULL,
    total_amount     NUMERIC(14,2) NOT NULL
);

-- ---------- (a) SEED: STUDENTS  [run now] ----------------------------
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('2026001', 'Mwansa Banda',   5000.00),
    ('2026002', 'Chanda Phiri',   3000.00),
    ('2026003', 'Temwa Zulu',     2500.00);     -- will have NO payments

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_fee  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid        -- 0 when no payments
    FROM payments WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
-- NOTE: it does NOT touch payment_audit; the trigger does that.
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero';
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise payments
    v_balance := fn_fee_balance(p_student_id);                           -- raises if unknown

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);          -- fee_due is never changed
END;
$$;

-- ---------- (d) TRIGGER  [run after (c)] -----------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

-- ---------- (a) SEED: SIX PAYMENTS VIA PROCEDURE  [run after (d)] ----
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);   -- student 1: pays 3000, owes 2000
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);   -- student 2: fully settled
CALL pr_receive_payment(2, 1200, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  800, CURRENT_DATE - 1);
-- student 3: no payments

-- ---------- (e) VIEW  [run after (a)] --------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;     -- settled students excluded

SELECT * FROM v_fee_balances;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Equality column (student_id) first, range column (paid_on) second.
CREATE INDEX idx_payments_student_paidon ON payments (student_id, paid_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule('refresh_collections_daily', '0 1 * * *',
                     $$CALL q02.pr_refresh_collections(CURRENT_DATE - 1)$$);

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);        -- rerun replaces the row
SELECT * FROM daily_collections;

-- ---------- TESTS: errors are expected here ---------------------------
SELECT fn_fee_balance(3) AS full_fee_no_payments;
DO $$ BEGIN CALL pr_receive_payment(1, 99999, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, -5, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_fee_balance(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
SELECT * FROM payment_audit ORDER BY audit_id;
