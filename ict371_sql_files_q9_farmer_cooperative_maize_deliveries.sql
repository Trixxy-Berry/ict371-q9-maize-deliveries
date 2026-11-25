-- ============================================================================
-- ICT371 Advanced Database
-- Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL / PL/pgSQL)
-- ============================================================================

-- (a) Database and seed data
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(12, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value >= 0),
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0),
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-001', 'Jones Hamusonde'),
    ('FRM-002', 'Agnes Chibwe'),
    ('FRM-003', 'Peter Nyirenda');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE RAISE EXCEPTION 'Unsupported maize grade: %', p_grade;
    END CASE;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade     TEXT,
    p_weight    NUMERIC(12, 2),
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(TRIM(p_grade)), p_weight, 1.00, 0.00, p_date, FALSE);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_calculate_delivery_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight_kg must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.grade := UPPER(TRIM(NEW.grade));
    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND((NEW.weight_kg * NEW.unit_rate)::numeric, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_pricing();

-- Load 6 deliveries after installing the trigger
CALL pr_receive_delivery(1, 'A', 200.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 150.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 300.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 100.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 120.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C',  80.00, CURRENT_DATE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 4);

-- (e) View
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0.00) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index, Query, and Plan
-- Justification: Composite index on (farmer_id, delivered_on) serves equality lookup by farmer and range scan by delivery date.
CREATE INDEX idx_deliveries_farmer_delivered_on
ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT
        p_day,
        COALESCE(SUM(weight_kg), 0.00),
        COALESCE(SUM(total_value), 0.00)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

-- Daily at 01:30 for the previous day (pg_cron)
SELECT cron.schedule(
    'refresh_daily_purchases',
    '30 1 * * *',
    $$CALL pr_refresh_purchases((CURRENT_DATE - 1)::date);$$
);
