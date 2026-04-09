/**
 * ============================================================
 * METRIC: Record Count Parity (Data Accuracy)
 * ============================================================
 *
 * Purpose:
 *   Count total Opportunity and OpportunityLineItem records in Salesforce.
 *   Compare these counts with Outreach (MySQL) and OpportunityManager (Postgres)
 *   to detect missing or extra records at each stage of the pipeline.
 *
 * Formula:
 *   count_delta       = sf_count - sink_count
 *   accuracy_pct      = (1 - ABS(count_delta) / sf_count) * 100
 *   missing_records   = sf_count - sink_count   (if positive)
 *   extra_records     = sink_count - sf_count   (if positive)
 *
 * Run: Developer Console > Debug > Open Execute Anonymous > Paste > Execute
 * Output: Check Logs > filter "USER_DEBUG"
 *
 * Companion Queries (run after this script):
 *
 *   -- Outreach (MySQL):
 *   SELECT 'opportunity' AS entity,
 *          COUNT(*) AS total,
 *          SUM(CASE WHEN trashed_at IS NULL THEN 1 ELSE 0 END) AS active,
 *          SUM(CASE WHEN trashed_at IS NOT NULL THEN 1 ELSE 0 END) AS deleted
 *   FROM opportunities;
 *
 *   SELECT 'opportunity_line_item' AS entity,
 *          COUNT(*) AS total,
 *          SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END) AS active,
 *          SUM(CASE WHEN deleted = 1 THEN 1 ELSE 0 END) AS deleted
 *   FROM opportunity_line_items;
 *
 *   -- OpportunityManager (Postgres):
 *   SELECT 'opportunity' AS entity,
 *          COUNT(*) AS total,
 *          COUNT(*) FILTER (WHERE is_deleted = false) AS active,
 *          COUNT(*) FILTER (WHERE is_deleted = true) AS deleted
 *   FROM opportunity;
 *
 *   SELECT 'opportunity_line_item' AS entity,
 *          COUNT(*) AS total,
 *          COUNT(*) FILTER (WHERE is_deleted = false) AS active,
 *          COUNT(*) FILTER (WHERE is_deleted = true) AS deleted
 *   FROM opportunity_line_item;
 * ============================================================
 */

// --- Opportunity Counts ---
Integer oppActive     = [SELECT COUNT() FROM Opportunity WHERE IsDeleted = false];
Integer oppDeleted    = [SELECT COUNT() FROM Opportunity WHERE IsDeleted = true ALL ROWS];
Integer oppTotal      = oppActive + oppDeleted;

// BulkTest subset (records created by load testing scripts)
Integer oppBulkActive = [SELECT COUNT() FROM Opportunity
                         WHERE Name LIKE 'BulkTest_Opp_%' AND IsDeleted = false];
Integer oppBulkDeleted = [SELECT COUNT() FROM Opportunity
                          WHERE Name LIKE 'BulkTest_Opp_%' AND IsDeleted = true ALL ROWS];
Integer oppBulkTotal  = oppBulkActive + oppBulkDeleted;

// --- OpportunityLineItem Counts ---
Integer oliActive     = [SELECT COUNT() FROM OpportunityLineItem WHERE IsDeleted = false];
Integer oliDeleted    = [SELECT COUNT() FROM OpportunityLineItem WHERE IsDeleted = true ALL ROWS];
Integer oliTotal      = oliActive + oliDeleted;

// BulkTest subset
Integer oliBulkActive = [SELECT COUNT() FROM OpportunityLineItem
                         WHERE Description LIKE 'BulkTest LineItem%' AND IsDeleted = false];
Integer oliBulkDeleted = [SELECT COUNT() FROM OpportunityLineItem
                          WHERE Description LIKE 'BulkTest LineItem%' AND IsDeleted = true ALL ROWS];
Integer oliBulkTotal  = oliBulkActive + oliBulkDeleted;

// --- By Stage Distribution (for context) ---
List<AggregateResult> byStage = [
    SELECT StageName, COUNT(Id) cnt
    FROM Opportunity
    WHERE IsDeleted = false
    GROUP BY StageName
    ORDER BY COUNT(Id) DESC
];

// --- Output ---
System.debug('================================================================');
System.debug('  METRIC: RECORD COUNT PARITY (Salesforce Source of Truth)');
System.debug('================================================================');
System.debug('');
System.debug('--- ALL RECORDS ---');
System.debug('  Opportunity (active):           ' + oppActive);
System.debug('  Opportunity (deleted):          ' + oppDeleted);
System.debug('  Opportunity (total):            ' + oppTotal);
System.debug('  OpportunityLineItem (active):   ' + oliActive);
System.debug('  OpportunityLineItem (deleted):  ' + oliDeleted);
System.debug('  OpportunityLineItem (total):    ' + oliTotal);
System.debug('');
System.debug('--- BULKTEST RECORDS ONLY ---');
System.debug('  BulkTest Opportunity (active):  ' + oppBulkActive);
System.debug('  BulkTest Opportunity (deleted): ' + oppBulkDeleted);
System.debug('  BulkTest Opportunity (total):   ' + oppBulkTotal);
System.debug('  BulkTest LineItem (active):     ' + oliBulkActive);
System.debug('  BulkTest LineItem (deleted):    ' + oliBulkDeleted);
System.debug('  BulkTest LineItem (total):      ' + oliBulkTotal);
System.debug('');
System.debug('--- OPPORTUNITY BY STAGE ---');
for (AggregateResult ar : byStage) {
    System.debug('  ' + ar.get('StageName') + ': ' + ar.get('cnt'));
}
System.debug('');
System.debug('--- HOW TO COMPARE ---');
System.debug('  accuracy_pct = (1 - ABS(sf_active - sink_active) / sf_active) * 100');
System.debug('  Run companion SQL queries above on Outreach and OpportunityManager');
System.debug('================================================================');
