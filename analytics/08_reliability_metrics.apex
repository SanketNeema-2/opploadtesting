/**
 * ============================================================
 * METRIC: Reliability Metrics (Failure Rate, Retry, Error Types)
 * ============================================================
 *
 * Purpose:
 *   Detect records in Salesforce that may have failed to sync
 *   by analyzing patterns: recently modified but old sink timestamps,
 *   deleted records, records with null critical fields, etc.
 *
 * Formulas:
 *   failure_rate_pct    = (failed_records / total_records) * 100
 *   retry_indicator     = records with multiple CDC events in opportunity_all
 *                         for same row_hash (detected on OpportunityManager side)
 *
 * Error Type Classification:
 *   validation_errors   = records with NULL required fields (Name, CloseDate, StageName)
 *   timeout_candidates  = records modified long ago but never reaching sink
 *   api_limit_candidates= large bursts of modifications in short windows
 *
 * This script identifies POTENTIAL problem records from the SF side.
 * Actual error confirmation requires OpportunityManager logs/tables.
 *
 * Companion Queries:
 *
 *   -- OpportunityManager (Postgres) — Retry detection via opportunity_all:
 *   SELECT id, row_hash, COUNT(*) AS event_count,
 *          COUNT(*) - 1 AS retry_count
 *   FROM opportunity_all
 *   WHERE updated_at BETWEEN '<from_ts>' AND '<to_ts>'
 *     AND row_hash IS NOT NULL
 *   GROUP BY id, row_hash
 *   HAVING COUNT(*) > 1
 *   ORDER BY retry_count DESC;
 *
 *   -- OpportunityManager (Postgres) — Retry summary:
 *   SELECT
 *       SUM(CASE WHEN cnt > 1 THEN cnt - 1 ELSE 0 END) AS total_retries,
 *       COUNT(CASE WHEN cnt > 1 THEN 1 END) AS records_with_retries
 *   FROM (
 *       SELECT id, row_hash, COUNT(*) AS cnt
 *       FROM opportunity_all
 *       WHERE updated_at BETWEEN '<from_ts>' AND '<to_ts>'
 *         AND row_hash IS NOT NULL
 *       GROUP BY id, row_hash
 *   ) sub;
 *
 *   -- OpportunityManager (Postgres) — Orphaned events (potential failures):
 *   SELECT COUNT(*) AS orphaned_events
 *   FROM opportunity_all oa
 *   LEFT JOIN opportunity o ON o.id = oa.id
 *   WHERE oa.updated_at BETWEEN '<from_ts>' AND '<to_ts>'
 *     AND o.id IS NULL;
 * ============================================================
 */

// ========== CONFIGURATION ==========
DateTime fromTs = DateTime.valueOf('2026-04-07 00:00:00');
DateTime toTs   = DateTime.valueOf('2026-04-08 23:59:59');
// ====================================

// --- Potential Validation Errors: records with NULL required fields ---
Integer oppNullName = [
    SELECT COUNT() FROM Opportunity
    WHERE Name = null AND IsDeleted = false
];
Integer oppNullStage = [
    SELECT COUNT() FROM Opportunity
    WHERE StageName = null AND IsDeleted = false
];
Integer oppNullCloseDate = [
    SELECT COUNT() FROM Opportunity
    WHERE CloseDate = null AND IsDeleted = false
];

// --- Burst detection: modifications per minute in window (API limit risk) ---
List<AggregateResult> burstAnalysis = [
    SELECT COUNT(Id) cnt
    FROM Opportunity
    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
    GROUP BY HOUR_IN_DAY(LastModifiedDate), DAY_IN_MONTH(LastModifiedDate)
    ORDER BY COUNT(Id) DESC
    LIMIT 10
];

// --- Recently deleted records (potential sync complications) ---
Integer recentlyDeleted = [
    SELECT COUNT() FROM Opportunity
    WHERE IsDeleted = true
      AND LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
    ALL ROWS
];
Integer oliRecentlyDeleted = [
    SELECT COUNT() FROM OpportunityLineItem
    WHERE IsDeleted = true
      AND LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
    ALL ROWS
];

// --- Total records in window (for failure rate denominator) ---
Integer oppInWindow = [
    SELECT COUNT() FROM Opportunity
    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
];
Integer oliInWindow = [
    SELECT COUNT() FROM OpportunityLineItem
    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
];

// --- Stale records: modified > 30 days ago, never updated since ---
Integer staleOpps = [
    SELECT COUNT() FROM Opportunity
    WHERE LastModifiedDate < LAST_N_DAYS:30
      AND IsDeleted = false
      AND CreatedDate > LAST_N_MONTHS:6
];

System.debug('================================================================');
System.debug('  METRIC: RELIABILITY ANALYSIS');
System.debug('  Window: ' + fromTs + ' to ' + toTs);
System.debug('================================================================');
System.debug('');

System.debug('--- POTENTIAL VALIDATION ERRORS (all time) ---');
System.debug('  Opportunities with NULL Name:      ' + oppNullName);
System.debug('  Opportunities with NULL StageName:  ' + oppNullStage);
System.debug('  Opportunities with NULL CloseDate:  ' + oppNullCloseDate);
System.debug('  (These may cause sync failures due to NOT NULL constraints)');
System.debug('');

System.debug('--- RECORDS IN SYNC WINDOW ---');
System.debug('  Opportunities modified:    ' + oppInWindow);
System.debug('  LineItems modified:         ' + oliInWindow);
System.debug('  Opportunities deleted:      ' + recentlyDeleted);
System.debug('  LineItems deleted:          ' + oliRecentlyDeleted);
System.debug('');

System.debug('--- BURST ANALYSIS (peak hourly volumes in window) ---');
System.debug('  Top 10 busiest hours by modification count:');
Integer rank = 1;
for (AggregateResult ar : burstAnalysis) {
    System.debug('    #' + rank + ': ' + ar.get('cnt') + ' modifications');
    rank++;
}
System.debug('  (High bursts may trigger API rate limits or timeouts)');
System.debug('');

System.debug('--- STALE RECORDS ---');
System.debug('  Opps created in last 6mo but not modified in 30 days: ' + staleOpps);
System.debug('  (May indicate records stuck in sync pipeline)');
System.debug('');

System.debug('--- NEXT STEPS ---');
System.debug('  1. Run companion SQL on OpportunityManager to get retry counts');
System.debug('  2. Run companion SQL to find orphaned events in opportunity_all');
System.debug('  3. Cross-reference with Script 05 (missing records) for gap analysis');
System.debug('');
System.debug('--- FORMULAS FOR REPORTING ---');
System.debug('  failure_rate_pct = (missing_in_sink / sf_total_in_window) * 100');
System.debug('  retry_rate       = records_with_retries / total_synced');
System.debug('  validation_error_rate = validation_errors / total_synced');
System.debug('================================================================');
