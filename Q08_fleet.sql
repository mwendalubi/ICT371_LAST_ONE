-- =====================================================================
-- ICT371  Q8  TRANSPORT FLEET MAINTENANCE   (PostgreSQL)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q08 CASCADE;
CREATE SCHEMA q08;
SET search_path TO q08, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id             SERIAL PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer       >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer  >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service  INTEGER NOT NULL,
    flagged_on        DATE    NOT NULL
);

-- ---------- (a) SEED: VEHICLES  [run now] ----------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1234', 10000,  8000),     -- 2,000 km since service
    ('BAZ 5678', 20000, 14000),     -- 6,000 km  -> due
    ('CAD 9012',  5000,     0);     -- exactly 5,000 km -> due (boundary)

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;                  -- "at least" 5,000 km
END;
$$;

-- ---------- (c) PROCEDURE  [run after (a)] ---------------------------
-- It does NOT update the odometer; the trigger in (d) does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ---------- (d) TRIGGER  [run after (a)] -----------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % must be greater than start %',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), got %',
                        v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer     -- the ONLY place this happens
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------- (a) SEED: SIX TRIPS VIA PROCEDURE  [run after (c),(d)] ----
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10300);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10300, 10800);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20400, 20900);
CALL pr_record_trip(3, CURRENT_DATE - 4,  5000,  5200);
CALL pr_record_trip(3, CURRENT_DATE - 1,  5200,  5500);

-- ---------- (e) VIEW  [run after (b)] --------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE fn_service_due(vehicle_id);

SELECT * FROM v_service_due;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Equality on vehicle_id first, range on trip_on second.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- insert a new alert, or update km on an existing one
    -- (flagged_on keeps the date the vehicle was FIRST flagged)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles that are no longer due (serviced)
    DELETE FROM service_alerts sa
    WHERE NOT fn_service_due(sa.vehicle_id);
END;
$$;

-- every Monday at 06:00
SELECT cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1', $$CALL q08.pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- ---------- TESTS: errors are expected here ---------------------------
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 10800, 10700);      -- end <= start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 9999, 11000);       -- wrong start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_service_due(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;   -- vehicle 2 serviced
CALL pr_refresh_service_alerts();                                    -- its alert is removed
SELECT * FROM service_alerts ORDER BY vehicle_id;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY vehicle_id;
