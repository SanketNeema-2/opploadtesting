/**
 * ============================================================
 * METRIC: Sync Lag Analysis (Performance)
 * ============================================================
 *
 * Purpose:
 *   Export LastModifiedDate for recently changed records in Salesforce.
 *   Compare with external_updated_at and updated_at in OpportunityManager
 *   to measure end-to-end sync lag at each pipeline stage.
 *
 * Formulas:
 *   sync_lag_sec        = oppmanager.updated_at - oppmanager.external_updated_at
 *   avg_sync_lag        = AVG(sync_lag_sec) across all records in window
 *   p50_sync_lag        = PERCENTILE_CONT(0.50) of sync_lag_sec
 *   p95_sync_lag        = PERCENTILE_CONT(0.95) of sync_lag_sec
 *   max_sync_lag        = MAX(sync_lag_sec)
 *
 * Performance Metrics Derived:
 *   total_sync_time     = MAX(updated_at) - MIN(updated_at) in window
 *   avg_time_per_record = total_sync_time / records_synced
 *   throughput_opp_sec  = opp_count / window_seconds
 *   throughput_oli_sec  = oli_count / window_seconds
 *
 * Companion Queries:
 *
 *   -- OpportunityManager (Postgres) — Per-Record Sync Lag:
 *   SELECT
 *       external_id,
 *       external_updated_at  AS sf_last_modified,
 *       updated_at           AS sink_persisted_at,
 *       EXTRACT(EPOCH FROM (updated_at - external_updated_at)) AS sync_lag_sec
 *   FROM opportunity
 *   WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...)
 *   ORDER BY sync_lag_sec DESC;
 *
 *   -- OpportunityManager (Postgres) — Aggregate Sync Lag Stats:
 *   SELECT
 *       'opportunity' AS entity,
 *       COUNT(*) AS records,
 *       AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at))) AS avg_lag_sec,
 *       PERCENTILE_CONT(0.50) WITHIN GROUP (
 *           ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
 *       ) AS p50_lag_sec,
 *       PERCENTILE_CONT(0.95) WITHIN GROUP (
 *           ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
 *       ) AS p95_lag_sec,
 *       MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at))) AS max_lag_sec
 *   FROM opportunity
 *   WHERE external_updated_at IS NOT NULL
 *     AND updated_at BETWEEN '<from_ts>' AND '<to_ts>';
 *
 *   -- OpportunityManager (Postgres) — Throughput:
 *   SELECT
 *       'opportunity' AS entity,
 *       COUNT(*) AS records_synced,
 *       EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS total_sync_sec,
 *       COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))), 0)
 *           AS throughput_per_sec
 *   FROM opportunity
 *   WHERE updated_at BETWEEN '<from_ts>' AND '<to_ts>'
 *   UNION ALL
 *   SELECT
 *       'opportunity_line_item',
 *       COUNT(*),
 *       EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))),
 *       COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))), 0)
 *   FROM opportunity_line_item
 *   WHERE updated_at BETWEEN '<from_ts>' AND '<to_ts>';
 * ============================================================
 */

// ========== CONFIGURATION ==========
// Set your time window (UTC). Adjust to match your sync run.
DateTime fromTs = DateTime.valueOf('2026-04-07 00:00:00');
DateTime toTs   = DateTime.valueOf('2026-04-08 23:59:59');
// ====================================

// --- Opportunity: records modified in window ---
List<Opportunity> recentOpps = [
    SELECT Id, Name, LastModifiedDate, CreatedDate, StageName, Amount
    FROM Opportunity
    WHERE LastModifiedDate >= :fromTs
      AND LastModifiedDate <= :toTs
      AND IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT 2000
];

// --- LineItem: records modified in window ---
List<OpportunityLineItem> recentOlis = [
    SELECT Id, Name, OpportunityId, LastModifiedDate, CreatedDate
    FROM OpportunityLineItem
    WHERE LastModifiedDate >= :fromTs
      AND LastModifiedDate <= :toTs
      AND IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT 2000
];

// --- Aggregate counts for the full window ---
Integer oppCountInWindow = [
    SELECT COUNT() FROM Opportunity
    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
];
Integer oliCountInWindow = [
    SELECT COUNT() FROM OpportunityLineItem
    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
];

// --- Compute window duration ---
Long windowSeconds = (toTs.getTime() - fromTs.getTime()) / 1000;

System.debug('================================================================');
System.debug('  METRIC: SYNC LAG & PERFORMANCE ANALYSIS');
System.debug('  Window: ' + fromTs + ' to ' + toTs);
System.debug('  Window duration: ' + windowSeconds + ' seconds');
System.debug('================================================================');
System.debug('');
System.debug('--- SALESFORCE RECORD COUNTS IN WINDOW ---');
System.debug('  Opportunities modified:     ' + oppCountInWindow);
System.debug('  LineItems modified:          ' + oliCountInWindow);
System.debug('  Total records:              ' + (oppCountInWindow + oliCountInWindow));
System.debug('');
System.debug('--- SALESFORCE-SIDE THROUGHPUT (upper bound) ---');
Decimal oppThroughput = windowSeconds > 0 ? Decimal.valueOf(oppCountInWindow) / windowSeconds : 0;
Decimal oliThroughput = windowSeconds > 0 ? Decimal.valueOf(oliCountInWindow) / windowSeconds : 0;
System.debug('  Opportunities/sec:          ' + oppThroughput.setScale(4));
System.debug('  LineItems/sec:              ' + oliThroughput.setScale(4));
System.debug('');

// --- Export Opportunity sync lag data ---
System.debug('--- OPPORTUNITY SYNC LAG DATA (sample ' + recentOpps.size() + ') ---');
System.debug('SF_Id|LastModifiedDate|Name|StageName|Amount');
for (Opportunity o : recentOpps) {
    System.debug(
        o.Id + '|' +
        o.LastModifiedDate + '|' +
        (o.Name != null ? o.Name : '') + '|' +
        (o.StageName != null ? o.StageName : '') + '|' +
        (o.Amount != null ? String.valueOf(o.Amount) : '')
    );
}

System.debug('');
System.debug('--- LINE ITEM SYNC LAG DATA (sample ' + recentOlis.size() + ') ---');
System.debug('SF_Id|OpportunityId|LastModifiedDate|Name');
for (OpportunityLineItem oli : recentOlis) {
    System.debug(
        oli.Id + '|' +
        (oli.OpportunityId != null ? String.valueOf(oli.OpportunityId) : '') + '|' +
        oli.LastModifiedDate + '|' +
        (oli.Name != null ? oli.Name : '')
    );
}

// --- IDs for companion SQL ---
System.debug('');
System.debug('--- OPP IDs for SQL lag comparison ---');
List<String> idBatch = new List<String>();
for (Integer i = 0; i < recentOpps.size(); i++) {
    idBatch.add('\'' + recentOpps[i].Id + '\'');
    if (Math.mod(i + 1, 100) == 0 || i == recentOpps.size() - 1) {
        System.debug(String.join(idBatch, ','));
        idBatch.clear();
    }
}
System.debug('');
System.debug('--- OLI IDs for SQL lag comparison ---');
idBatch.clear();
for (Integer i = 0; i < recentOlis.size(); i++) {
    idBatch.add('\'' + recentOlis[i].Id + '\'');
    if (Math.mod(i + 1, 100) == 0 || i == recentOlis.size() - 1) {
        System.debug(String.join(idBatch, ','));
        idBatch.clear();
    }
}
