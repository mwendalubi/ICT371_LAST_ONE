-- =====================================================================
-- ICT371  Q3  LIBRARY RETURNS AND OVERDUE FINES   (PostgreSQL)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q03 CASCADE;
CREATE SCHEMA q03;
SET search_path TO q03, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

CREATE TABLE books (
    book_id  SERIAL PRIMARY KEY,
    title    VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id        SERIAL PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE,                                   -- NULL = still out
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL PRIMARY KEY,
    loan_id           INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE,
    new_returned_on   DATE,
    changed_at        TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL,
    total_fine     NUMERIC(12,2) NOT NULL
);

-- ---------- (a) SEED: BOOKS + SIX LOANS (all unreturned for now) -----
INSERT INTO books (title) VALUES
    ('Database Systems'),
    ('Operating Systems'),
    ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mumba',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open OVERDUE
    (1, 'Brian Tembo',   CURRENT_DATE -  5, CURRENT_DATE +  9),  -- 2 open, on time
    (2, 'Chipo Daka',    CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 3 will be returned late
    (2, 'Daniel Sakala', CURRENT_DATE - 20, CURRENT_DATE -  6),  -- 4 returned ON due date
    (3, 'Esther Lungu',  CURRENT_DATE - 10, CURRENT_DATE +  4),  -- 5 returned early
    (3, 'Farai Moyo',    CURRENT_DATE - 25, CURRENT_DATE - 11);  -- 6 open OVERDUE

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;

    -- earlier of as-of date and return date (if there is one)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);      -- K2/day, never below 0
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans                                  -- date and final fine in ONE statement
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ---------- (d) TRIGGER  [run after (c)] -----------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_fn_loan_audit();

-- ---------- (a) SEED: RETURN THREE LOANS VIA PROCEDURE [after (d)] ----
CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late  -> K12
CALL pr_return_loan(4, CURRENT_DATE -  6);   -- on due date  -> K0
CALL pr_return_loan(5, CURRENT_DATE -  2);   -- early        -> K0

-- ---------- (e) VIEW  [run after (b)] --------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Partial index: only unreturned loans are stored, so it is small and
-- exactly matches "this book's unreturned loans".
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
-- Counts loans that are overdue and not yet returned as of p_as_of.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
    FROM loans l
    WHERE l.borrowed_on <= p_as_of
      AND (l.returned_on IS NULL OR l.returned_on > p_as_of)   -- still out on that date
      AND l.due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule('refresh_overdue_daily', '10 0 * * *',
                     $$CALL q03.pr_refresh_overdue(CURRENT_DATE)$$);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                -- rerun replaces the row
SELECT * FROM overdue_summary;

-- ---------- TESTS: errors are expected here ---------------------------
SELECT fn_loan_fine(1, CURRENT_DATE) AS fine_loan1, fn_loan_fine(3, CURRENT_DATE) AS fine_loan3;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;   -- unchanged: no audit row
SELECT * FROM loan_audit ORDER BY audit_id;
