-- ============================================================
-- COMPANION QUERIES: OpportunityManager (PostgreSQL)
-- ============================================================
--
-- Purpose:
--   Run these queries on the OpportunityManager Postgres database
--   to complete the 3-way comparison:
--   Salesforce (Apex) → Outreach (MySQL) → OpportunityManager (this file)
--
-- Table Mapping:
--   SF Opportunity          → opportunity            (join key: external_id = SF Id)
--   SF OpportunityLineItem  → opportunity_line_item  (join key: external_id = SF Id)
--   CDC events              → opportunity_all        (every event with row_hash, change_fields)
--
-- Usage:
--   Replace :from_ts / :to_ts with your time window.
--   Replace '<sf_id_1>' placeholders with IDs from Apex script output.
-- ============================================================


-- ============================================================
-- METRIC: Record Count Parity
-- Formula: accuracy_pct = (1 - ABS(sf_count - sink_count) / sf_count) * 100
-- Compare with: Script 01 (Apex) + Script 09 (Outreach MySQL)
-- ============================================================

SELECT 'opportunity' AS entity,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE is_deleted = false) AS active,
       COUNT(*) FILTER (WHERE is_deleted = true) AS deleted
FROM opportunity;

SELECT 'opportunity_line_item' AS entity,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE is_deleted = false) AS active,
       COUNT(*) FILTER (WHERE is_deleted = true) AS deleted
FROM opportunity_line_item;


-- ============================================================
-- METRIC: Record Count in Time Window
-- Formula: throughput = records / window_seconds
-- Compare with: Script 04 (Apex)
-- ============================================================

-- SET from_ts = '2026-04-07 00:00:00';
-- SET to_ts   = '2026-04-08 23:59:59';

SELECT
    'opportunity' AS entity,
    COUNT(*) AS records_synced,
    MIN(updated_at) AS first_record_at,
    MAX(updated_at) AS last_record_at,
    EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS total_sync_sec,
    COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))), 0) AS throughput_per_sec
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts

UNION ALL

SELECT
    'opportunity_line_item',
    COUNT(*),
    MIN(updated_at),
    MAX(updated_at),
    EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))),
    COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))), 0)
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;


-- ============================================================
-- METRIC: Performance — Total Sync Time, Avg Time Per Record, Throughput
-- Formulas:
--   total_sync_time     = MAX(updated_at) - MIN(updated_at) in window
--   avg_time_per_record = total_sync_time / records_synced
--   opp_per_sec         = opp_count / window_seconds
--   oli_per_sec         = oli_count / window_seconds
-- ============================================================

WITH opp_perf AS (
    SELECT
        COUNT(*) AS records,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec
    FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
oli_perf AS (
    SELECT
        COUNT(*) AS records,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec
    FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
)
SELECT
    'opportunity' AS entity,
    o.records,
    o.duration_sec AS total_sync_sec,
    o.duration_sec / NULLIF(o.records, 0) AS avg_sec_per_record,
    o.records / NULLIF(o.duration_sec, 0) AS throughput_per_sec
FROM opp_perf o
UNION ALL
SELECT
    'opportunity_line_item',
    l.records,
    l.duration_sec,
    l.duration_sec / NULLIF(l.records, 0),
    l.records / NULLIF(l.duration_sec, 0)
FROM oli_perf l;


-- ============================================================
-- METRIC: Performance — Sync Lag (end-to-end)
-- Formula: sync_lag_sec = updated_at - external_updated_at
-- Compare with: Script 04 (Apex) SF LastModifiedDate
-- ============================================================

-- Aggregate stats
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records,
    AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at))) AS avg_lag_sec,
    PERCENTILE_CONT(0.50) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ) AS p50_lag_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ) AS p95_lag_sec,
    MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at))) AS max_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts

UNION ALL

SELECT
    'opportunity_line_item',
    COUNT(*),
    AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at))),
    PERCENTILE_CONT(0.50) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ),
    PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ),
    MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
FROM opportunity_line_item
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts;

-- Per-record lag (top 100 worst)
SELECT
    external_id,
    external_updated_at AS sf_last_modified,
    updated_at AS sink_persisted_at,
    EXTRACT(EPOCH FROM (updated_at - external_updated_at)) AS sync_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts
ORDER BY sync_lag_sec DESC
LIMIT 100;


-- ============================================================
-- METRIC: Performance — Throughput Over Time (5-min buckets)
-- For "Records processed over time" chart
-- ============================================================

SELECT
    date_trunc('minute', updated_at)
      - (EXTRACT(MINUTE FROM updated_at)::int % 5) * INTERVAL '1 minute' AS bucket_5min,
    SUM(CASE WHEN tbl = 'opp' THEN 1 ELSE 0 END) AS opportunities,
    SUM(CASE WHEN tbl = 'oli' THEN 1 ELSE 0 END) AS line_items,
    COUNT(*) AS total
FROM (
    SELECT 'opp' AS tbl, updated_at FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    UNION ALL
    SELECT 'oli', updated_at FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
) combined
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- METRIC: Performance — Throughput vs Batch Size
-- Uses opportunity_all event density as batch proxy
-- ============================================================

WITH batches AS (
    SELECT
        date_trunc('second', updated_at) AS batch_ts,
        COUNT(*) AS batch_size
    FROM opportunity_all
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    GROUP BY 1
)
SELECT
    CASE
        WHEN batch_size <= 10 THEN '01-10'
        WHEN batch_size <= 50 THEN '11-50'
        WHEN batch_size <= 100 THEN '51-100'
        WHEN batch_size <= 500 THEN '101-500'
        ELSE '500+'
    END AS batch_size_bucket,
    COUNT(*) AS num_batches,
    AVG(batch_size)::int AS avg_batch_size,
    SUM(batch_size) AS total_records
FROM batches
GROUP BY 1
ORDER BY MIN(batch_size);


-- ============================================================
-- METRIC: Field-Level Accuracy — Opportunity
-- Compare with: Script 02 (Apex)
-- Paste SF IDs from Script 02 output
-- ============================================================

SELECT
    id,
    external_id AS sf_id,
    name,
    amount_precise,
    stage_name,
    close_date,
    owner_id,
    probability,
    forecast_category,
    lead_source,
    next_step,
    opportunity_type,
    is_closed,
    is_won,
    currency_type,
    external_created_at,
    external_updated_at,
    account_id,
    record_type,
    description,
    is_deleted,
    state,
    updated_at AS sink_updated_at
FROM opportunity
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>')
ORDER BY external_id;


-- ============================================================
-- METRIC: Field-Level Accuracy — OpportunityLineItem
-- Compare with: Script 03 (Apex)
-- Paste SF IDs from Script 03 output
-- ============================================================

SELECT
    id,
    external_id AS sf_id,
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
    is_deleted,
    created_at,
    external_updated_at,
    updated_at AS sink_updated_at
FROM opportunity_line_item
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>')
ORDER BY external_id;


-- ============================================================
-- METRIC: Missing Records Detection
-- Compare with: Script 05 (Apex)
-- Formula: missing_rate_pct = (missing / sf_total) * 100
-- ============================================================

-- Option A: Using unnest (paste SF IDs as array)
SELECT unnest(ARRAY['<sf_id_1>','<sf_id_2>']) AS sf_id
EXCEPT
SELECT external_id FROM opportunity WHERE external_id IS NOT NULL;

-- Same for line items:
SELECT unnest(ARRAY['<sf_id_1>','<sf_id_2>']) AS sf_id
EXCEPT
SELECT external_id FROM opportunity_line_item WHERE external_id IS NOT NULL;


-- ============================================================
-- METRIC: Duplicate Detection
-- Should return 0 rows if sync is correct
-- ============================================================

SELECT external_id, COUNT(*) AS dupes
FROM opportunity
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;

SELECT external_id, COUNT(*) AS dupes
FROM opportunity_line_item
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;


-- ============================================================
-- METRIC: Reliability — Retry Detection (via opportunity_all)
-- Formula: retries = events_for_same_row_hash - 1
-- ============================================================

-- Per-record retries
SELECT id, row_hash, COUNT(*) AS event_count,
       COUNT(*) - 1 AS retry_count
FROM opportunity_all
WHERE updated_at BETWEEN :from_ts AND :to_ts
  AND row_hash IS NOT NULL
GROUP BY id, row_hash
HAVING COUNT(*) > 1
ORDER BY retry_count DESC
LIMIT 50;

-- Summary
SELECT
    SUM(CASE WHEN cnt > 1 THEN cnt - 1 ELSE 0 END) AS total_retries,
    COUNT(CASE WHEN cnt > 1 THEN 1 END) AS records_with_retries,
    SUM(cnt) AS total_events
FROM (
    SELECT id, row_hash, COUNT(*) AS cnt
    FROM opportunity_all
    WHERE updated_at BETWEEN :from_ts AND :to_ts
      AND row_hash IS NOT NULL
    GROUP BY id, row_hash
) sub;


-- ============================================================
-- METRIC: Reliability — Orphaned Events (potential failures)
-- Events in opportunity_all that never made it to opportunity
-- ============================================================

SELECT COUNT(*) AS orphaned_events
FROM opportunity_all oa
LEFT JOIN opportunity o ON o.id = oa.id
WHERE oa.updated_at BETWEEN :from_ts AND :to_ts
  AND o.id IS NULL;


-- ============================================================
-- METRIC: Reliability — Redundant Events
-- Same row_hash appearing multiple times = wasted processing
-- ============================================================

SELECT
    COUNT(*) AS total_events,
    COUNT(DISTINCT (id::text || ':' || COALESCE(row_hash, ''))) AS distinct_events,
    COUNT(*) - COUNT(DISTINCT (id::text || ':' || COALESCE(row_hash, ''))) AS redundant_events
FROM opportunity_all
WHERE updated_at BETWEEN :from_ts AND :to_ts;


-- ============================================================
-- METRIC: Load — Error Rate vs Load (per minute)
-- Formula: error_rate_pct = errors / processed * 100
-- Requires sync_errors table (see design doc) OR use orphaned events
-- ============================================================

-- Using orphan detection as error proxy:
WITH per_minute AS (
    SELECT
        date_trunc('minute', updated_at) AS minute_ts,
        COUNT(*) AS records_processed
    FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    GROUP BY 1
),
orphans_per_minute AS (
    SELECT
        date_trunc('minute', oa.updated_at) AS minute_ts,
        COUNT(*) AS orphan_count
    FROM opportunity_all oa
    LEFT JOIN opportunity o ON o.id = oa.id
    WHERE oa.updated_at BETWEEN :from_ts AND :to_ts
      AND o.id IS NULL
    GROUP BY 1
)
SELECT
    p.minute_ts,
    p.records_processed AS load,
    COALESCE(e.orphan_count, 0) AS errors,
    100.0 * COALESCE(e.orphan_count, 0) / NULLIF(p.records_processed, 0) AS error_rate_pct
FROM per_minute p
LEFT JOIN orphans_per_minute e ON e.minute_ts = p.minute_ts
ORDER BY p.minute_ts;


-- ============================================================
-- METRIC: Load — DB Write Latency (from pg_stat_statements)
-- No code changes needed — uses built-in Postgres stats
-- ============================================================

SELECT
    CASE
        WHEN query ILIKE '%INSERT INTO%opportunity_all%' THEN 'opportunity_all_insert'
        WHEN query ILIKE '%INSERT INTO "opportunity"%' THEN 'opportunity_insert'
        WHEN query ILIKE '%UPDATE "opportunity"%' THEN 'opportunity_update'
        WHEN query ILIKE '%INSERT INTO%opportunity_line_item%' THEN 'line_item_insert'
        WHEN query ILIKE '%UPDATE%opportunity_line_item%' THEN 'line_item_update'
        ELSE 'other'
    END AS operation,
    calls,
    total_exec_time / NULLIF(calls, 0) AS avg_ms,
    min_exec_time AS min_ms,
    max_exec_time AS max_ms,
    stddev_exec_time AS stddev_ms
FROM pg_stat_statements
WHERE query ILIKE '%opportunity%'
  AND calls > 0
ORDER BY total_exec_time DESC
LIMIT 20;


-- ============================================================
-- METRIC: Load — Table I/O Stats
-- ============================================================

SELECT
    relname AS table_name,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes,
    n_tup_ins + n_tup_upd + n_tup_del AS total_writes,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
FROM pg_stat_user_tables
WHERE relname IN (
    'opportunity', 'opportunity_all',
    'opportunity_line_item', 'opportunity_line_item_all'
)
ORDER BY total_writes DESC;


-- ============================================================
-- METRIC: Summary Report (Executive View)
-- Combines all key metrics in one query
-- ============================================================

WITH opp_stats AS (
    SELECT
        COUNT(*) AS total,
        MIN(updated_at) AS first_at,
        MAX(updated_at) AS last_at,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec,
        AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
            FILTER (WHERE external_updated_at IS NOT NULL) AS avg_lag_sec
    FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
oli_stats AS (
    SELECT
        COUNT(*) AS total,
        MIN(updated_at) AS first_at,
        MAX(updated_at) AS last_at,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec,
        AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
            FILTER (WHERE external_updated_at IS NOT NULL) AS avg_lag_sec
    FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
retry_stats AS (
    SELECT
        SUM(CASE WHEN cnt > 1 THEN cnt - 1 ELSE 0 END) AS total_retries,
        COUNT(CASE WHEN cnt > 1 THEN 1 END) AS records_with_retries
    FROM (
        SELECT id, row_hash, COUNT(*) AS cnt
        FROM opportunity_all
        WHERE updated_at BETWEEN :from_ts AND :to_ts
          AND row_hash IS NOT NULL
        GROUP BY id, row_hash
    ) sub
),
orphan_stats AS (
    SELECT COUNT(*) AS orphaned
    FROM opportunity_all oa
    LEFT JOIN opportunity o ON o.id = oa.id
    WHERE oa.updated_at BETWEEN :from_ts AND :to_ts
      AND o.id IS NULL
)
SELECT
    '--- SUMMARY REPORT ---' AS section,

    -- Total records processed
    o.total AS opp_processed,
    l.total AS oli_processed,
    o.total + l.total AS total_processed,

    -- Throughput
    o.total / NULLIF(o.duration_sec, 0) AS opp_per_sec,
    l.total / NULLIF(l.duration_sec, 0) AS oli_per_sec,

    -- Total sync time
    o.duration_sec AS opp_sync_sec,
    l.duration_sec AS oli_sync_sec,

    -- Avg time per record
    o.duration_sec / NULLIF(o.total, 0) AS opp_avg_sec_per_record,
    l.duration_sec / NULLIF(l.total, 0) AS oli_avg_sec_per_record,

    -- Sync lag
    o.avg_lag_sec AS opp_avg_lag_sec,
    l.avg_lag_sec AS oli_avg_lag_sec,

    -- Reliability
    orph.orphaned AS failed_events,
    100.0 * orph.orphaned / NULLIF(o.total + l.total, 0) AS failure_rate_pct,
    r.total_retries,
    r.records_with_retries

FROM opp_stats o, oli_stats l, retry_stats r, orphan_stats orph;
