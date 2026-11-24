-- =====================================================================
-- ICT371  Q4  CLINIC APPOINTMENT SCHEDULING   (PostgreSQL)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q04 CASCADE;
CREATE SCHEMA q04;
SET search_path TO q04, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

CREATE TABLE patients (
    patient_id  SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL
                     CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                     CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Optional safety net: the DB itself blocks double booking even under
-- concurrency. The trigger in (d) still gives the friendly error message.
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- ---------- (a) SEED: PATIENTS + DOCTORS  [run now] ------------------
INSERT INTO patients (full_name) VALUES ('Grace Mulenga'), ('Joseph Kunda'), ('Ruth Chileshe');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Mwale'), ('Dr. Zimba');

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count                  -- COUNT gives 0 when no rows
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- ---------- (c) PROCEDURE  [run after (a)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date must not be in the past';
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks clashes
END;
$$;

-- ---------- (d) TRIGGER  [run after (a)] -----------------------------
CREATE OR REPLACE FUNCTION trg_fn_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1 FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- skip the row being changed
        ) THEN
            RAISE EXCEPTION 'Slot clash: doctor % already booked on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_slot_clash();

-- ---------- (a) SEED: SIX APPOINTMENTS  [run after (d)] ---------------
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 2, '10:00', 'CANCELLED'),
    (1, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 2, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 1, CURRENT_DATE + 1, '11:00', 'BOOKED'),
    (3, 3, CURRENT_DATE + 1, '12:00', 'BOOKED');

-- ---------- (e) VIEW  [run after (a)] --------------------------------
-- Only the patient name, doctor name and slot are exposed.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time;

SELECT * FROM v_today_appointments;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Non-unique: many appointments share a day. Day first (most selective
-- range/equality filter for daily work), then doctor_id.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 2;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
                     $$CALL q04.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);     -- rerun replaces the row
SELECT * FROM clinic_summary;

-- ---------- TESTS: errors are expected here ---------------------------
SELECT fn_daily_load(1, CURRENT_DATE + 1) AS load_with_booking,
       fn_daily_load(1, CURRENT_DATE + 30) AS load_empty_day;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE, '09:00');          -- clash
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE - 1, '11:00');      -- past
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE + 2, '13:00');      -- bad slot
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
CALL pr_book_appointment(1, 2, CURRENT_DATE + 2, '11:00');                  -- valid
