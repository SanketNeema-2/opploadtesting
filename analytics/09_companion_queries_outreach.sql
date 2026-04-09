-- ============================================================
-- COMPANION QUERIES: Outreach (MySQL)
-- ============================================================
--
-- Purpose:
--   Run these queries on the Outreach MySQL database to get the
--   middle-layer data for 3-way comparison:
--   Salesforce (Apex scripts) → Outreach (this file) → OpportunityManager (next file)
--
-- Table Mapping:
--   SF Opportunity      → outreach.opportunities      (join key: custom_id = SF Id)
--   SF OpportunityLineItem → outreach.opportunity_line_items (join key: external_id = SF Id)
--
-- Usage:
--   Replace :from_ts / :to_ts with your time window.
--   Replace '<sf_id_1>' placeholders with IDs from Apex script output.
-- ============================================================


-- ============================================================
-- METRIC: Record Count Parity
-- Compare with: Script 01 (Apex) + Script 09b (Postgres)
-- ============================================================

SELECT 'opportunity' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN trashed_at IS NULL THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN trashed_at IS NOT NULL THEN 1 ELSE 0 END) AS deleted
FROM opportunities;

SELECT 'opportunity_line_item' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN deleted = 1 THEN 1 ELSE 0 END) AS deleted_count
FROM opportunity_line_items;

-- BulkTest subset
SELECT 'bulktest_opportunity' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN trashed_at IS NULL THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN trashed_at IS NOT NULL THEN 1 ELSE 0 END) AS deleted
FROM opportunities
WHERE name LIKE 'BulkTest_Opp_%';


-- ============================================================
-- METRIC: Record Count in Time Window
-- Compare with: Script 04 (Apex)
-- ============================================================

-- SET @from_ts = '2026-04-07 00:00:00';
-- SET @to_ts   = '2026-04-08 23:59:59';

SELECT 'opportunity' AS entity,
       COUNT(*) AS modified_in_window
FROM opportunities
WHERE updated_at BETWEEN @from_ts AND @to_ts;

SELECT 'opportunity_line_item' AS entity,
       COUNT(*) AS modified_in_window
FROM opportunity_line_items
WHERE updated_at BETWEEN @from_ts AND @to_ts;


-- ============================================================
-- METRIC: Field-Level Accuracy — Opportunity
-- Compare with: Script 02 (Apex)
-- Use IDs output by Script 02
-- ============================================================

SELECT
    id,
    custom_id           AS sf_id,
    name,
    amount_precise,
    close_date,
    owner_id,
    probability,
    forecast_category,
    lead_source,
    next_step,
    opportunity_type,
    currency_type,
    external_created_at,
    updated_at          AS last_modified,
    account_id,
    record_type,
    state,
    CASE WHEN trashed_at IS NOT NULL THEN 1 ELSE 0 END AS is_deleted
FROM opportunities
WHERE custom_id IN ('<sf_id_1>', '<sf_id_2>')
ORDER BY custom_id;


-- ============================================================
-- METRIC: Field-Level Accuracy — OpportunityLineItem
-- Compare with: Script 03 (Apex)
-- Use IDs output by Script 03
-- ============================================================

SELECT
    id,
    external_id         AS sf_id,
    name,
    opportunity_id,
    unit_price,
    quantity,
    total_price,
    discount,
    line_description,
    external_product_id,
    close_date,
    currency_type,
    deleted             AS is_deleted,
    created_at,
    updated_at          AS last_modified
FROM opportunity_line_items
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>')
ORDER BY external_id;


-- ============================================================
-- METRIC: Missing Records Detection
-- Compare with: Script 05 (Apex)
-- Paste SF IDs from Script 05 output
-- ============================================================

-- Find Opportunities in SF but missing from Outreach
-- (Paste comma-separated SF IDs from Script 05 output)
SELECT 'missing_in_outreach' AS check_type, COUNT(*) AS cnt
FROM (
    -- Replace with actual IDs from Script 05
    SELECT '<sf_id_1>' AS sf_id UNION ALL
    SELECT '<sf_id_2>'
) t
LEFT JOIN opportunities o ON o.custom_id = t.sf_id
WHERE o.id IS NULL;


-- ============================================================
-- METRIC: Sync Lag — Outreach ingestion lag
-- How long after SF LastModifiedDate did Outreach persist it?
-- ============================================================

SELECT
    custom_id AS sf_id,
    external_updated_at,
    updated_at AS outreach_updated_at,
    TIMESTAMPDIFF(SECOND, external_updated_at, updated_at) AS outreach_lag_sec
FROM opportunities
WHERE updated_at BETWEEN @from_ts AND @to_ts
  AND external_updated_at IS NOT NULL
ORDER BY outreach_lag_sec DESC
LIMIT 100;


-- ============================================================
-- METRIC: DB Write Latency (Outreach side)
-- Records processed per minute = proxy for write throughput
-- ============================================================

SELECT
    DATE_FORMAT(updated_at, '%Y-%m-%d %H:%i') AS minute_bucket,
    COUNT(*) AS records_this_minute
FROM opportunities
WHERE updated_at BETWEEN @from_ts AND @to_ts
GROUP BY minute_bucket
ORDER BY records_this_minute DESC
LIMIT 20;
