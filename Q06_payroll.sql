-- =====================================================================
-- ICT371  Q6  MONTHLY PAYROLL PROCESSING   (PostgreSQL)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q06 CASCADE;
CREATE SCHEMA q06;
SET search_path TO q06, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

CREATE TABLE employees (
    employee_id   SERIAL PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction     NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   SERIAL PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month    DATE          NOT NULL,
    gross_pay    NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay      NUMERIC(12,2) NOT NULL CHECK (net_pay   >= 0),
    CONSTRAINT chk_pay_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_employee_month   UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id     SERIAL PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMP     NOT NULL DEFAULT now()
);

-- ---------- (a) SEED: EMPLOYEES  [run now] ---------------------------
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Kabwe Lubinda',  12000.00, 2000.00, 1500.00, TRUE),
    ('Ms. Natasha Phiri',   9000.00, 1500.00, 1000.00, TRUE),
    ('Mr. Owen Chanda',     7000.00, 1000.00,  800.00, TRUE),
    ('Mrs. Precious Zulu',  8000.00, 1200.00,  900.00, TRUE);   -- becomes inactive later

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_basic NUMERIC;
    v_allow NUMERIC;
    v_deduc NUMERIC;
    v_net   NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_deduc
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_deduc;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    rec     RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees WHERE active = TRUE ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(rec.employee_id);          -- raises => whole call fails
        v_gross := rec.basic_salary + rec.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING; -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- ---------- (d) TRIGGER  [run after (a)] -----------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------- (a) SEED: TWO PAYROLL MONTHS  [run after (b),(c),(d)] -----
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;   -- history must remain visible

-- ---------- (e) VIEW  [run after (a)] --------------------------------
-- Plain JOIN with no "active" filter, so ex-employees' history still shows.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month, e.full_name;

SELECT * FROM v_payroll_report;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- UNIQUE (employee_id, pay_month) leads with employee_id, so it cannot
-- efficiently serve "all employees for one month". This index leads with
-- pay_month and is NOT a copy of the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
-- 02:00 on the 1st of every month, processing the PREVIOUS month.
SELECT cron.schedule('process_payroll_monthly', '0 2 1 * *',
  $$CALL q06.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history:
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'process_payroll_monthly';
SELECT * FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'process_payroll_monthly')
ORDER BY start_time DESC;

-- ---------- TESTS: errors are expected here ---------------------------
UPDATE employees SET basic_salary = 13000 WHERE employee_id = 1;   -- audited
UPDATE employees SET basic_salary = 13000 WHERE employee_id = 1;   -- unchanged: NOT audited
CALL pr_process_payroll(DATE '2026-10-01');                        -- rerun: row for emp 1 stays at old pay
SELECT * FROM salary_audit;
SELECT employee_id, pay_month, gross_pay, net_pay FROM payroll WHERE employee_id = 1 ORDER BY pay_month;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-15');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_net_pay(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
-- negative net pay makes the WHOLE call fail and nothing is inserted:
UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-01');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
SELECT COUNT(*) AS rows_for_nov FROM payroll WHERE pay_month = DATE '2026-11-01';   -- 0
UPDATE employees SET deduction = 800 WHERE employee_id = 3;        -- restore
