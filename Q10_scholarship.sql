-- =====================================================================
-- ICT371  Q10  SCHOLARSHIP APPLICATION ASSESSMENT   (PostgreSQL)
-- Eligible only when: age 18-25, monthly income <= K3,000, mark >= 70.
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

CREATE TABLE students (
    student_id      SERIAL PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL,
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        SERIAL PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status      VARCHAR(10) NOT NULL,
    new_status      VARCHAR(10) NOT NULL,
    changed_at      TIMESTAMP   NOT NULL DEFAULT now()
);

-- ---------- (a) SEED: STUDENTS + SIX PENDING APPLICATIONS [run now] ---
INSERT INTO students (student_number, full_name) VALUES
    ('S001', 'Anna Bwalya'),
    ('S002', 'Peter Nkandu'),
    ('S003', 'Sarah Mutale');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 80.00, CURRENT_DATE - 10, 'PENDING'),   -- qualifies
    (1, 17, 1000.00, 90.00, CURRENT_DATE -  9, 'PENDING'),   -- too young
    (2, 18, 3000.00, 70.00, CURRENT_DATE -  8, 'PENDING'),   -- boundary: all limits exactly -> qualifies
    (2, 25, 2500.00, 69.99, CURRENT_DATE -  7, 'PENDING'),   -- mark just below 70
    (3, 26, 1000.00, 85.00, CURRENT_DATE -  6, 'PENDING'),   -- too old
    (3, 22, 3000.01, 75.00, CURRENT_DATE -  5, 'PENDING');   -- income just above K3,000

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_age     INTEGER;
    v_income  NUMERIC;
    v_mark    NUMERIC;
    v_status  VARCHAR(10);
    v_ok      BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)', p_application_id, v_status;
    END IF;

    v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- ---------- (d) TRIGGER  [run after (a)] -----------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------- (e) VIEW  [run after (a)] --------------------------------
-- Household income is deliberately left out.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Equality column (status) first, range column (submitted_on) second.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id FROM applications
        WHERE status = 'PENDING' ORDER BY application_id     -- completed ones are never touched
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- every Monday at 08:00
SELECT cron.schedule('assess_pending_weekly', '0 8 * * 1', $$CALL q10.pr_assess_pending()$$);

CALL pr_assess_pending();
CALL pr_assess_pending();                             -- rerun: nothing pending, no new audit rows
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit ORDER BY audit_id;       -- exactly 6 rows

-- ---------- TESTS: errors are expected here ---------------------------
SELECT fn_scholarship_eligible(18, 3000, 70) AS boundary_ok,
       fn_scholarship_eligible(26, 1000, 85) AS too_old;
DO $$ BEGIN CALL pr_assess_application(1);           -- already assessed
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 100, 80);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
UPDATE applications SET status = status WHERE application_id = 1;   -- unchanged: no audit row
SELECT COUNT(*) AS audit_rows FROM decision_audit;                  -- still 6
