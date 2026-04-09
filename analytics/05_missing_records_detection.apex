/**
 * ============================================================
 * METRIC: Missing Records Detection (Data Accuracy)
 * ============================================================
 *
 * Purpose:
 *   Export all active Salesforce IDs for Opportunity and
 *   OpportunityLineItem. Use companion SQL to LEFT JOIN against
 *   Outreach and OpportunityManager to find records that exist
 *   in SF but are missing from the downstream sinks.
 *
 * Formulas:
 *   missing_count    = sf_count - matched_count
 *   missing_rate_pct = (missing_count / sf_count) * 100
 *
 * Limitations:
 *   SOQL governor limit = 50,000 rows per query.
 *   For larger orgs, filter by date range or use BulkTest subset.
 *
 * Companion Queries:
 *
 *   -- Outreach (MySQL) — Find missing Opportunities:
 *   -- Paste SF IDs below into a temp table or IN clause
 *   SELECT t.sf_id
 *   FROM (SELECT '<id1>' AS sf_id UNION ALL SELECT '<id2>' ...) t
 *   LEFT JOIN opportunities o ON o.custom_id = t.sf_id
 *   WHERE o.id IS NULL;
 *
 *   -- OpportunityManager (Postgres) — Find missing Opportunities:
 *   -- Option A: Using VALUES list
 *   SELECT sf_id FROM (
 *       VALUES ('<id1>'), ('<id2>'), ...
 *   ) AS sf(sf_id)
 *   LEFT JOIN opportunity o ON o.external_id = sf.sf_id
 *   WHERE o.external_id IS NULL;
 *
 *   -- Option B: Using unnest (easier for large lists)
 *   SELECT unnest(ARRAY['<id1>','<id2>',...]) AS sf_id
 *   EXCEPT
 *   SELECT external_id FROM opportunity WHERE external_id IS NOT NULL;
 *
 *   -- Same pattern for OpportunityLineItem:
 *   SELECT unnest(ARRAY['<id1>','<id2>',...]) AS sf_id
 *   EXCEPT
 *   SELECT external_id FROM opportunity_line_item WHERE external_id IS NOT NULL;
 * ============================================================
 */

// ========== CONFIGURATION ==========
// Set to true to only check BulkTest records (faster, smaller set)
Boolean bulkTestOnly = true;
// ====================================

// --- Opportunities ---
List<Opportunity> allOpps;
if (bulkTestOnly) {
    allOpps = [
        SELECT Id, Name, LastModifiedDate
        FROM Opportunity
        WHERE Name LIKE 'BulkTest_Opp_%' AND IsDeleted = false
        ORDER BY Name
        LIMIT 50000
    ];
} else {
    allOpps = [
        SELECT Id, Name, LastModifiedDate
        FROM Opportunity
        WHERE IsDeleted = false
        ORDER BY LastModifiedDate DESC
        LIMIT 50000
    ];
}

System.debug('================================================================');
System.debug('  METRIC: MISSING RECORDS DETECTION');
System.debug('  Mode: ' + (bulkTestOnly ? 'BulkTest only' : 'All records'));
System.debug('================================================================');
System.debug('');
System.debug('--- OPPORTUNITY IDs (' + allOpps.size() + ' records) ---');
System.debug('  Use these IDs in the companion SQL to find missing records.');
System.debug('');

// Print IDs in batches of 200 per debug line
List<String> idBatch = new List<String>();
for (Integer i = 0; i < allOpps.size(); i++) {
    idBatch.add('\'' + allOpps[i].Id + '\'');
    if (Math.mod(i + 1, 200) == 0 || i == allOpps.size() - 1) {
        System.debug('OPP_IDS: ' + String.join(idBatch, ','));
        idBatch.clear();
    }
}

// --- OpportunityLineItems ---
List<OpportunityLineItem> allOlis;
if (bulkTestOnly) {
    allOlis = [
        SELECT Id, Name, OpportunityId, LastModifiedDate
        FROM OpportunityLineItem
        WHERE Description LIKE 'BulkTest LineItem%' AND IsDeleted = false
        ORDER BY LastModifiedDate DESC
        LIMIT 50000
    ];
} else {
    allOlis = [
        SELECT Id, Name, OpportunityId, LastModifiedDate
        FROM OpportunityLineItem
        WHERE IsDeleted = false
        ORDER BY LastModifiedDate DESC
        LIMIT 50000
    ];
}

System.debug('');
System.debug('--- LINE ITEM IDs (' + allOlis.size() + ' records) ---');

idBatch.clear();
for (Integer i = 0; i < allOlis.size(); i++) {
    idBatch.add('\'' + allOlis[i].Id + '\'');
    if (Math.mod(i + 1, 200) == 0 || i == allOlis.size() - 1) {
        System.debug('OLI_IDS: ' + String.join(idBatch, ','));
        idBatch.clear();
    }
}

System.debug('');
System.debug('--- SUMMARY ---');
System.debug('  Opportunity IDs exported:  ' + allOpps.size());
System.debug('  LineItem IDs exported:     ' + allOlis.size());
System.debug('  Run companion SQL to find which are missing from sinks.');
System.debug('================================================================');
