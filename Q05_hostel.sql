-- =====================================================================
-- ICT371  Q5  HOSTEL ROOM ALLOCATION   (PostgreSQL)
-- =====================================================================

-- ---------- (0) SETUP: own schema so the 10 questions never clash [run first]
DROP SCHEMA IF EXISTS q05 CASCADE;
CREATE SCHEMA q05;
SET search_path TO q05, public;

-- ---------- (a) DATABASE: TABLES  [run first] ------------------------
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

CREATE TABLE students (
    student_id      SERIAL PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      SERIAL PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  SERIAL PRIMARY KEY,
    student_id     INTEGER     NOT NULL REFERENCES students(student_id),
    room_id        INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE,
    status         VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE    NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds  INTEGER NOT NULL,
    free_beds      INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- ---------- (a) SEED: STUDENTS + ROOMS  [run now] --------------------
INSERT INTO students (student_number, full_name) VALUES
    ('H001', 'Alick Njovu'),
    ('H002', 'Bupe Kasonde'),
    ('H003', 'Charity Mwila'),
    ('H004', 'David Simfukwe'),
    ('H005', 'Elina Musonda'),
    ('H006', 'Felix Hamoonga');

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),      -- will be FULL
    ('A102', 3),      -- will be PARTLY occupied
    ('A103', 2);      -- will be EMPTY (only history)

-- ---------- (b) FUNCTION  [run after (a)] ----------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';   -- ENDED ignored

    RETURN v_capacity - v_active;
END;
$$;

-- ---------- (c) PROCEDURE  [run after (b)] ---------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- lock room while checking
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ---------- (d) TRIGGER  [run after (a)] -----------------------------
-- Protects direct INSERT/UPDATE statements that bypass the procedure.
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room row so concurrent inserts are checked one at a time
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

        -- one ACTIVE allocation per student (exclude the row being updated)
        IF EXISTS (SELECT 1 FROM allocations
                   WHERE student_id = NEW.student_id
                     AND status = 'ACTIVE'
                     AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- capacity (exclude the row being updated)
        SELECT COUNT(*) INTO v_active
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_active >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------- (a) SEED: ALLOCATIONS  [run after (c) and (d)] ------------
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);     -- A101 full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);     -- A102 partly (1/3)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 200, CURRENT_DATE - 100, 'ENDED');   -- A103 history only

-- ---------- (e) VIEW  [run after (a)] --------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'  -- keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_number;

SELECT * FROM v_room_occupancy;

-- ---------- (f) INDEX  [run after (a)] -------------------------------
-- Partial index on ACTIVE rows only: ENDED history never slows the
-- capacity check, and the index stays small.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- ---------- (g) SCHEDULED JOB  [run last] ---------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule('refresh_occupancy_daily', '55 23 * * *', $$CALL q05.pr_refresh_occupancy()$$);

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                          -- rerun replaces values
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- ---------- TESTS: errors are expected here ---------------------------
DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);      -- room full
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 2, CURRENT_DATE);      -- student already active
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)   -- direct SQL
            VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_free_beds(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected: %', SQLERRM; END $$;
SELECT fn_free_beds(3) AS free_in_empty_room_A103;
