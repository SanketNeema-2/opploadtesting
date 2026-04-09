# Sync Analytics Scripts

Comprehensive tracking and measurement scripts for the Salesforce → Outreach → OpportunityManager data sync pipeline.

## Data Flow

```
Salesforce (SOQL/Apex)
    ↓  Opportunity.Id = custom_id = external_id
Outreach (MySQL)  ─── opportunities / opportunity_line_items
    ↓  CDC via Clerk/Kafka
OpportunityManager (Postgres)  ─── opportunity / opportunity_line_item
```

## Scripts Overview

### Salesforce Apex Scripts (run in Developer Console → Execute Anonymous)

| Script | Metric | What It Measures |
|--------|--------|------------------|
| `01_record_count_parity.apex` | **Data Accuracy** | Total counts by entity, stage, active/deleted. Compare 3-way. |
| `02_opportunity_field_accuracy.apex` | **Data Accuracy** | Field-by-field export of 200 Opportunities for diff. |
| `03_lineitem_field_accuracy.apex` | **Data Accuracy** | Field-by-field export of 200 LineItems for diff. |
| `04_sync_lag_analysis.apex` | **Performance** | SF LastModifiedDate for sync lag computation. Throughput. |
| `05_missing_records_detection.apex` | **Data Accuracy** | Export all SF IDs to find records missing from sinks. |
| `06_data_distribution.apex` | **Load & Scalability** | Monthly volumes, hourly patterns, items-per-opp histogram. |
| `07_targeted_record_comparison.apex` | **Data Accuracy** | Deep-dive specific records by ID for debugging mismatches. |
| `08_reliability_metrics.apex` | **Reliability** | Validation errors, burst analysis, deleted records, stale records. |

### SQL Companion Scripts

| Script | Database | Purpose |
|--------|----------|---------|
| `09_companion_queries_outreach.sql` | Outreach (MySQL) | Middle-layer counts, field accuracy, missing records, write throughput |
| `10_companion_queries_oppmanager.sql` | OpportunityManager (Postgres) | Sink-side counts, throughput, sync lag, retries, DB stats, summary report |

## How To Run

### Step 1: Salesforce
1. Open Developer Console → Debug → Open Execute Anonymous
2. Paste the `.apex` script content
3. Click Execute
4. Open Logs → filter by `USER_DEBUG` to see output

### Step 2: Outreach (MySQL)
1. Connect to Outreach MySQL database
2. Set variables: `SET @from_ts = '2026-04-07 00:00:00'; SET @to_ts = '2026-04-08 23:59:59';`
3. Run relevant queries from `09_companion_queries_outreach.sql`

### Step 3: OpportunityManager (Postgres)
1. Connect to OpportunityManager Postgres (use `psql` or client)
2. Replace `:from_ts` / `:to_ts` placeholders with your time window
3. Run relevant queries from `10_companion_queries_oppmanager.sql`
4. The **Summary Report** query at the bottom gives all key metrics in one shot

## Metrics Reference

### Data Accuracy
| Metric | Formula |
|--------|---------|
| Count parity | `accuracy_pct = (1 - ABS(sf_count - sink_count) / sf_count) * 100` |
| Field accuracy | `field_accuracy_pct = (1 - mismatches / compared) * 100` |
| Missing rate | `missing_rate_pct = (missing / sf_total) * 100` |
| Duplicate check | `SELECT external_id HAVING COUNT(*) > 1` (should be 0) |

### Performance
| Metric | Formula |
|--------|---------|
| Total sync time | `MAX(updated_at) - MIN(updated_at) in window` |
| Avg time/record | `total_sync_time / records_synced` |
| Throughput (opp/sec) | `opp_count / window_seconds` |
| Throughput (oli/sec) | `oli_count / window_seconds` |
| Sync lag | `updated_at - external_updated_at` (p50, p95, max) |

### Reliability
| Metric | Formula |
|--------|---------|
| Failure rate | `(orphaned_events / total_events) * 100` |
| Retry count | `SUM(event_count - 1)` for same `(id, row_hash)` in `opportunity_all` |
| Validation errors | Records with NULL required fields in SF |
| Timeout candidates | Records with sync_lag > threshold |
| API limit risk | Peak hourly modification counts |

### Load & Scalability
| Metric | Source |
|--------|--------|
| CPU usage | Datadog: `container.cpu.utilization{service:opportunitymanager}` |
| Memory | Datadog: `container.memory.usage{service:opportunitymanager}` |
| DB write latency | `pg_stat_statements` (avg_ms, max_ms per operation) |
| Table I/O stats | `pg_stat_user_tables` (inserts, updates, deletes, dead rows) |
