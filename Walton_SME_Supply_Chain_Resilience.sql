-- Creating replicas of the 5 core supply chain tables
CREATE TABLE IF NOT EXISTS products_backup AS SELECT * FROM products;
CREATE TABLE IF NOT EXISTS suppliers_backup AS SELECT * FROM suppliers;
CREATE TABLE IF NOT EXISTS orders_backup AS SELECT * FROM orders;
CREATE TABLE IF NOT EXISTS inventory_status_backup AS SELECT * FROM inventory_status;
CREATE TABLE IF NOT EXISTS delivery_incidents_backup AS SELECT * FROM delivery_incidents;




-- Deduplication of all 5 core tables
DELETE FROM products WHERE ctid NOT IN (SELECT MIN(ctid) FROM products GROUP BY product_id);
DELETE FROM suppliers WHERE ctid NOT IN (SELECT MIN(ctid) FROM suppliers GROUP BY supplier_id);
DELETE FROM orders WHERE ctid NOT IN (SELECT MIN(ctid) FROM orders GROUP BY order_id);
DELETE FROM inventory_status WHERE ctid NOT IN (SELECT MIN(ctid) FROM inventory_status GROUP BY snapshot_date, product_id);
DELETE FROM delivery_incidents WHERE ctid NOT IN (SELECT MIN(ctid) FROM delivery_incidents GROUP BY incident_id);



-- Products table standardization
UPDATE products SET 
    product_name = TRIM(product_name),
    product_category = TRIM(LOWER(product_category)),
    product_sub_category = TRIM(LOWER(product_sub_category)),
    brand_name = TRIM(UPPER(brand_name)),
    storage_requirement = COALESCE(TRIM(LOWER(storage_requirement)), 'ambient');

-- Suppliers table standardization
UPDATE suppliers SET 
    supplier_name = TRIM(supplier_name),
    supplier_category = TRIM(LOWER(supplier_category)),
    supplier_country = TRIM(UPPER(supplier_country)),
    supplier_city = TRIM(INITCAP(supplier_city)),
    contract_status = TRIM(LOWER(contract_status)),
    payment_terms = COALESCE(TRIM(UPPER(payment_terms)), 'NET 30');

-- Orders table standardization
UPDATE orders SET 
    order_status = TRIM(LOWER(order_status)),
    shipping_mode = TRIM(LOWER(shipping_mode)),
    carrier_name = TRIM(UPPER(carrier_name)),
    customs_clearance_status = COALESCE(TRIM(LOWER(customs_clearance_status)), 'not_applicable');



-- Products: Cost, price, lead time, weight
UPDATE products SET 
    unit_cost = CASE WHEN unit_cost < 0 OR unit_cost IS NULL THEN 0 ELSE unit_cost END,
    unit_price = CASE WHEN unit_price < 0 OR unit_price IS NULL THEN 0 ELSE unit_price END,
    lead_time_days = CASE WHEN lead_time_days < 0 OR lead_time_days IS NULL THEN 7 ELSE lead_time_days END,
    weight_kg = CASE WHEN weight_kg <= 0 OR weight_kg IS NULL THEN 1.0 ELSE weight_kg END;

-- Suppliers: Rating, risk score, delivery rate
UPDATE suppliers SET 
    supplier_rating = CASE WHEN supplier_rating < 1 OR supplier_rating > 5 THEN 3.0 ELSE supplier_rating END,
    risk_score = CASE WHEN risk_score < 0 OR risk_score > 100 THEN 50 ELSE risk_score END,
    on_time_delivery_rate = COALESCE(on_time_delivery_rate, 0.85);

-- Inventory: Stock parameters
UPDATE inventory_status SET 
    stock_on_hand = CASE WHEN stock_on_hand < 0 OR stock_on_hand IS NULL THEN 0 ELSE stock_on_hand END,
    stock_allocated = CASE WHEN stock_allocated < 0 OR stock_allocated IS NULL THEN 0 ELSE stock_allocated END,
    stock_in_transit = CASE WHEN stock_in_transit < 0 OR stock_in_transit IS NULL THEN 0 ELSE stock_in_transit END;


-- Orders: Date logic and quantity integrity
-- First, clean empty strings to NULL
UPDATE orders SET 
    order_date = NULLIF(order_date, ''),
    promised_delivery_date = NULLIF(promised_delivery_date, ''),
    actual_delivery_date = NULLIF(actual_delivery_date, '');

-- Then run your original update with safe casting
UPDATE orders SET 
    promised_delivery_date = CASE 
        WHEN order_date IS NULL THEN promised_delivery_date
        WHEN promised_delivery_date::DATE < order_date::DATE 
        THEN (order_date::DATE + INTERVAL '7 days')::TEXT 
        ELSE promised_delivery_date 
    END,
    actual_delivery_date = CASE 
        WHEN order_date IS NULL THEN actual_delivery_date
        WHEN actual_delivery_date::DATE < order_date::DATE 
        THEN promised_delivery_date 
        ELSE actual_delivery_date 
    END,
    quantity_damaged = COALESCE(quantity_damaged::INT, 0),
    shipping_cost = COALESCE(shipping_cost::NUMERIC, 0)
WHERE quantity_damaged::INT > quantity_ordered::INT 
   OR shipping_cost::NUMERIC < 0
   OR (promised_delivery_date IS NOT NULL AND order_date IS NOT NULL);




DELETE FROM orders WHERE product_id NOT IN (SELECT product_id FROM products);
DELETE FROM orders WHERE supplier_id NOT IN (SELECT supplier_id FROM suppliers);
DELETE FROM inventory_status WHERE product_id NOT IN (SELECT product_id FROM products);



-- Lead time variance imputation using median
UPDATE suppliers s SET lead_time_variance_days = COALESCE(
    s.lead_time_variance_days,
    (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lead_time_variance_days::NUMERIC) 
     FROM suppliers WHERE lead_time_variance_days IS NOT NULL)
);

-- Minimum order quantity fallback
UPDATE suppliers SET minimum_order_quantity = COALESCE(minimum_order_quantity::INTEGER, 100)
WHERE minimum_order_quantity IS NULL;




-- ============================================================
-- SAFE APPROACH: Drop dependent objects first
-- ============================================================

-- Step 1: Drop dependent views (CASCADE will handle dependencies)
DROP VIEW IF EXISTS vFact_SupplyChain CASCADE;
DROP VIEW IF EXISTS vDim_Products CASCADE;
DROP VIEW IF EXISTS vDim_Suppliers CASCADE;
DROP VIEW IF EXISTS vDim_Date CASCADE;
DROP VIEW IF EXISTS feat_inventory_health CASCADE;
DROP VIEW IF EXISTS feat_supplier_resilience CASCADE;

-- Step 2: Drop base views
DROP VIEW IF EXISTS vRaw_Orders_Clean CASCADE;
DROP VIEW IF EXISTS vRaw_Products_Clean CASCADE;
DROP VIEW IF EXISTS vRaw_Suppliers_Clean CASCADE;

-- Step 3: Recreate all views
-- (Your original CREATE VIEW statements here)

-- Products base view
CREATE VIEW vRaw_Products_Clean AS
SELECT 
    MD5(product_id::TEXT)::UUID AS product_sk,
    product_id,
    product_name,
    product_category,
    product_sub_category,
    brand_name,
    unit_cost::NUMERIC AS unit_cost,
    unit_price::NUMERIC AS unit_price,
    reorder_point::INTEGER AS reorder_point,
    safety_stock_level::INTEGER AS safety_stock_level,
    lead_time_days::INTEGER AS lead_time_days,
    is_perishable,
    storage_requirement,
    weight_kg::NUMERIC AS weight_kg,
    dimensions_cm,
    MD5(supplier_id::TEXT)::UUID AS supplier_sk,
    supplier_id
FROM products;

-- Suppliers base view
CREATE VIEW vRaw_Suppliers_Clean AS
SELECT 
    MD5(supplier_id::TEXT)::UUID AS supplier_sk,
    supplier_id,
    supplier_name,
    supplier_category,
    supplier_country,
    supplier_city,
    supplier_rating::NUMERIC AS supplier_rating,
    contract_status,
    payment_terms,
    risk_score::INTEGER AS risk_score,
    lead_time_variance_days::INTEGER AS lead_time_variance_days,
    on_time_delivery_rate::NUMERIC AS on_time_delivery_rate,
    minimum_order_quantity::INTEGER AS minimum_order_quantity
FROM suppliers;

-- Orders base view (with product_id and supplier_id)
CREATE VIEW vRaw_Orders_Clean AS
SELECT 
    order_id,
    product_id,
    supplier_id,
    MD5(product_id::TEXT)::UUID AS product_sk,
    MD5(supplier_id::TEXT)::UUID AS supplier_sk,
    order_date::DATE AS order_date,
    promised_delivery_date::DATE AS promised_delivery_date,
    actual_delivery_date::DATE AS actual_delivery_date,
    quantity_ordered::INTEGER AS quantity_ordered,
    quantity_received::INTEGER AS quantity_received,
    quantity_damaged::INTEGER AS quantity_damaged,
    order_status,
    shipping_mode,
    carrier_name,
    shipping_cost::NUMERIC AS shipping_cost,
    tracking_number,
    customs_clearance_status
FROM orders;



CREATE OR REPLACE VIEW vDim_Products AS
SELECT 
    product_sk,
    product_id,
    product_name,
    product_category,
    product_sub_category,
    brand_name,
    unit_cost,
    unit_price,
    is_perishable,
    storage_requirement,
    reorder_point,
    safety_stock_level,
    lead_time_days,
    weight_kg,
    dimensions_cm,
    -- Price tier classification
    CASE 
        WHEN unit_price < 50 THEN 'Budget Tier'
        WHEN unit_price < 250 THEN 'Mid-Range Tier'
        ELSE 'Premium Tier'
    END AS price_tier,
    -- Margin category
    CASE 
        WHEN (unit_price - unit_cost) / NULLIF(unit_cost, 0) > 0.4 THEN 'High Margin Profile'
        WHEN (unit_price - unit_cost) / NULLIF(unit_cost, 0) > 0.15 THEN 'Medium Margin Profile'
        ELSE 'Low Margin Profile'
    END AS margin_category
FROM vRaw_Products_Clean;



CREATE OR REPLACE VIEW vDim_Suppliers AS
SELECT 
    supplier_sk,
    supplier_id,
    supplier_name,
    supplier_category,
    supplier_country,
    supplier_city,
    supplier_rating,
    contract_status,
    payment_terms,
    risk_score,
    minimum_order_quantity,
    lead_time_variance_days,
    -- Risk category
    CASE 
        WHEN risk_score <= 25 THEN 'Low Risk Tier'
        WHEN risk_score <= 65 THEN 'Medium Risk Operational Tier'
        ELSE 'High Strategic Risk Tier'
    END AS risk_category,
    -- Supplier tier based on delivery rate
    CASE 
        WHEN on_time_delivery_rate >= 0.96 THEN 'Elite Gold Vendor'
        WHEN on_time_delivery_rate >= 0.88 THEN 'Standard Silver Vendor'
        ELSE 'Restricted Bronze Vendor'
    END AS supplier_tier
FROM vRaw_Suppliers_Clean;


CREATE OR REPLACE VIEW vDim_Date AS
WITH date_boundaries AS (
    SELECT 
        MIN(order_date)::DATE AS start_date,
        MAX(order_date)::DATE AS end_date
    FROM orders
    WHERE order_date IS NOT NULL
),
calculated_time_series AS (
    SELECT GENERATE_SERIES(start_date, end_date, '1 day'::INTERVAL)::DATE AS calendar_date
    FROM date_boundaries
)
SELECT 
    calendar_date AS date_sk,
    EXTRACT(YEAR FROM calendar_date)::INTEGER AS calendar_year,
    EXTRACT(QUARTER FROM calendar_date)::INTEGER AS calendar_quarter,
    EXTRACT(MONTH FROM calendar_date)::INTEGER AS month_numerical,
    TO_CHAR(calendar_date, 'Month') AS month_name_expanded,
    EXTRACT(WEEK FROM calendar_date)::INTEGER AS week_of_year,
    EXTRACT(DOW FROM calendar_date)::INTEGER AS day_of_week_numerical,
    TO_CHAR(calendar_date, 'Day') AS day_name,
    CASE WHEN EXTRACT(DOW FROM calendar_date) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend_flag,
    TO_CHAR(calendar_date, 'YYYY-MM') AS financial_period_code
FROM calculated_time_series;





-- ============================================================
-- STEP 1: Fix vRaw_Orders_Clean with product_id
-- ============================================================
DROP VIEW IF EXISTS vRaw_Orders_Clean;

CREATE OR REPLACE VIEW vRaw_Orders_Clean AS
SELECT 
    o.order_id,
    o.product_id,      -- CRITICAL: Needed for inventory_status join
    o.supplier_id,     -- CRITICAL: Needed for supplier joins
    MD5(o.product_id::TEXT)::UUID AS product_sk,
    MD5(o.supplier_id::TEXT)::UUID AS supplier_sk,
    o.order_date::DATE AS order_date,
    o.promised_delivery_date::DATE AS promised_delivery_date,
    o.actual_delivery_date::DATE AS actual_delivery_date,
    o.quantity_ordered::INTEGER AS quantity_ordered,
    o.quantity_received::INTEGER AS quantity_received,
    o.quantity_damaged::INTEGER AS quantity_damaged,
    o.order_status,
    o.shipping_mode,
    o.carrier_name,
    o.shipping_cost::NUMERIC AS shipping_cost,
    o.tracking_number,
    o.customs_clearance_status
FROM orders o
WHERE o.order_date IS NOT NULL 
   AND o.order_date != '';  -- Filter out empty dates

-- ============================================================
-- STEP 2: Recreate vFact_SupplyChain
-- ============================================================
DROP VIEW IF EXISTS vFact_SupplyChain;

CREATE OR REPLACE VIEW vFact_SupplyChain AS
SELECT 
    o.order_id,
    o.product_sk,
    o.supplier_sk,
    o.order_date AS date_sk,
    o.promised_delivery_date,
    o.actual_delivery_date,
    o.quantity_ordered,
    o.quantity_received,
    o.quantity_damaged,
    o.shipping_cost,
    o.order_status,
    o.shipping_mode,
    o.carrier_name,
    o.customs_clearance_status,
    
    -- Financial metrics
    (o.quantity_ordered * p.unit_cost) AS cost_of_goods_sold,
    (o.quantity_ordered * p.unit_price) AS gross_expected_revenue,
    (o.quantity_ordered * (p.unit_price - p.unit_cost)) AS gross_projected_profit,
    
    -- Inventory fulfillment metrics
    (o.quantity_ordered - o.quantity_received) AS warehouse_backlog_volume,
    (o.quantity_ordered - COALESCE(o.quantity_received, 0) - COALESCE(o.quantity_damaged, 0)) AS net_perfect_fulfillment_volume,
    
    -- Lead time metrics
    CASE 
        WHEN o.actual_delivery_date IS NULL THEN NULL
        ELSE (o.actual_delivery_date - o.order_date)
    END AS actual_transit_duration_days,
    
    CASE 
        WHEN o.promised_delivery_date IS NULL THEN NULL
        ELSE (o.promised_delivery_date - o.order_date)
    END AS contractual_transit_duration_days,
    
    -- Binary flags with NULL handling
    CASE 
        WHEN o.actual_delivery_date IS NOT NULL AND o.promised_delivery_date IS NOT NULL
        THEN CASE WHEN o.actual_delivery_date <= o.promised_delivery_date THEN 1 ELSE 0 END
        ELSE NULL
    END AS binary_is_on_time,
    
    CASE WHEN COALESCE(o.quantity_damaged, 0) > 0 THEN 1 ELSE 0 END AS binary_contains_damage,
    CASE WHEN o.customs_clearance_status IN ('delayed', 'pending_inspection') THEN 1 ELSE 0 END AS binary_customs_disrupted,
    
    -- Inventory snapshot integration
    COALESCE(inv.stock_on_hand::INTEGER, 0) AS snapshot_stock_on_hand,
    COALESCE(inv.stock_allocated::INTEGER, 0) AS snapshot_stock_allocated,
    COALESCE(inv.stock_in_transit::INTEGER, 0) AS snapshot_stock_in_transit,
    COALESCE(inv.maximum_capacity_stock::INTEGER, 0) AS snapshot_max_capacity,
    COALESCE(inv.days_of_supply_remaining::NUMERIC, 0) AS snapshot_days_of_supply,
    
    -- Incident integration
    COALESCE(inc.financial_loss_amount::NUMERIC, 0) AS disruption_financial_loss,
    COALESCE(inc.impact_level, 'no_incident') AS disruption_severity_index,
    COALESCE(inc.root_cause_category, 'compliant') AS disruption_root_cause

FROM vRaw_Orders_Clean o
LEFT JOIN vRaw_Products_Clean p ON o.product_sk = p.product_sk
LEFT JOIN inventory_status inv ON o.order_date = inv.snapshot_date::DATE AND o.product_id = inv.product_id
LEFT JOIN delivery_incidents inc ON o.order_id = inc.order_id;

-- ============================================================
-- STEP 3: Verify the view works
-- ============================================================
SELECT COUNT(*) AS fact_row_count FROM vFact_SupplyChain LIMIT 10;



-- Must return all zeros
SELECT 
    (SELECT COUNT(*) FROM vFact_SupplyChain f 
     LEFT JOIN vDim_Products p ON f.product_sk = p.product_sk 
     WHERE p.product_sk IS NULL) AS orphan_product_keys,
    (SELECT COUNT(*) FROM vFact_SupplyChain f 
     LEFT JOIN vDim_Suppliers s ON f.supplier_sk = s.supplier_sk 
     WHERE s.supplier_sk IS NULL) AS orphan_supplier_keys,
    (SELECT COUNT(*) FROM vFact_SupplyChain f 
     LEFT JOIN vDim_Date d ON f.date_sk = d.date_sk 
     WHERE d.date_sk IS NULL) AS orphan_date_keys;



-- ============================================================
-- SAFE INDEX CREATION SCRIPT
-- ============================================================

-- Drop existing indexes (optional, if you want to recreate)
DROP INDEX IF EXISTS idx_orders_product_id CASCADE;
DROP INDEX IF EXISTS idx_orders_supplier_id CASCADE;
DROP INDEX IF EXISTS idx_orders_order_date CASCADE;
DROP INDEX IF EXISTS idx_inventory_product_snapshot CASCADE;
DROP INDEX IF EXISTS idx_incidents_order_id CASCADE;
DROP INDEX IF EXISTS idx_active_orders CASCADE;

-- Create indexes with IF NOT EXISTS (safest approach)
CREATE INDEX IF NOT EXISTS idx_orders_product_id ON orders(product_id);
CREATE INDEX IF NOT EXISTS idx_orders_supplier_id ON orders(supplier_id);
CREATE INDEX IF NOT EXISTS idx_orders_order_date ON orders(order_date);
CREATE INDEX IF NOT EXISTS idx_inventory_product_snapshot ON inventory_status(product_id, snapshot_date);
CREATE INDEX IF NOT EXISTS idx_incidents_order_id ON delivery_incidents(order_id);
CREATE INDEX IF NOT EXISTS idx_active_orders ON orders(order_id) 
    WHERE order_status NOT IN ('delivered', 'cancelled');

-- Verify all indexes exist
SELECT 
    indexname, 
    indexdef 
FROM pg_indexes 
WHERE tablename IN ('orders', 'inventory_status', 'delivery_incidents')
    AND indexname LIKE 'idx_%'
ORDER BY indexname;



commit;

