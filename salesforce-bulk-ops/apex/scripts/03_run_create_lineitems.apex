// ============================================================================
// 03_run_create_lineitems.apex
// Invokes the LineItemCreatorBatch class to create OpportunityLineItems.
//
// Supports two modes:
//   - ALL mode (default): Creates line items for ALL BulkTest Opportunities
//   - SCOPED mode: Creates line items only for Opps in a specific index range
//     Set START_INDEX and END_INDEX to a non-zero value to use scoped mode.
//
// PREREQUISITES:
//   1. Deploy LineItemCreatorBatch.cls to the org
//      Setup > Apex Classes > New > paste LineItemCreatorBatch.cls > Save
//   2. Run 01_create_products.apex (Products + PricebookEntries must exist)
//   3. Run 02_run_create_opportunities.apex and wait for completion
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
//        Monitor: Setup > Apex Jobs
// ============================================================================

// ======================== CONFIGURATION ========================
Integer LINE_ITEMS_PER_OPP = 3;    // Number of line items per Opportunity
Integer BATCH_SIZE         = 200;  // Opportunities per batch
                                    // Each batch creates BATCH_SIZE * LINE_ITEMS_PER_OPP DML rows
                                    // Keep BATCH_SIZE * LINE_ITEMS_PER_OPP < 10000

// Optional: scope to a specific range of Opportunities
// Set both to non-zero to process ONLY Opps in that range.
// Leave both at 0 to process ALL BulkTest Opportunities.
Integer START_INDEX = 0;   // e.g. 501  (maps to BulkTest_Opp_000501)
Integer END_INDEX   = 0;   // e.g. 1000 (maps to BulkTest_Opp_001000)
// ===============================================================

// --- Pre-flight checks ---
Integer oppCount;
if (START_INDEX > 0 && END_INDEX > 0) {
    String nameFrom = 'BulkTest_Opp_' + String.valueOf(START_INDEX).leftPad(6, '0');
    String nameTo   = 'BulkTest_Opp_' + String.valueOf(END_INDEX).leftPad(6, '0');
    oppCount = [SELECT COUNT() FROM Opportunity WHERE Name >= :nameFrom AND Name <= :nameTo];
    System.debug('Pre-flight (SCOPED ' + nameFrom + ' to ' + nameTo + '): ' + oppCount + ' Opportunities found');
} else {
    oppCount = [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'BulkTest_Opp_%'];
    System.debug('Pre-flight (ALL): ' + oppCount + ' BulkTest Opportunities found');
}

Integer pbeCount = [SELECT COUNT() FROM PricebookEntry
                    WHERE Pricebook2.IsStandard = true AND IsActive = true
                      AND Product2.Name LIKE 'BulkTest_%'];
System.debug('Pre-flight: ' + pbeCount + ' BulkTest PricebookEntries found');

if (oppCount == 0) {
    System.debug(LoggingLevel.ERROR,
        'No BulkTest Opportunities found. Run 02_run_create_opportunities.apex first and wait for completion.');
} else if (pbeCount == 0) {
    System.debug(LoggingLevel.ERROR,
        'No BulkTest PricebookEntries found. Run 01_create_products.apex first.');
} else {
    // Safety check: batch size * items per opp must fit in DML row limit
    Integer dmlRowsPerBatch = BATCH_SIZE * LINE_ITEMS_PER_OPP;
    if (dmlRowsPerBatch > 9500) {
        System.debug(LoggingLevel.ERROR,
            'BATCH_SIZE (' + BATCH_SIZE + ') x LINE_ITEMS_PER_OPP (' + LINE_ITEMS_PER_OPP +
            ') = ' + dmlRowsPerBatch + ' exceeds safe DML row limit per batch. Reduce BATCH_SIZE.');
    } else {
        System.debug('=== Submitting LineItemCreatorBatch ===');
        System.debug('Items per opp:      ' + LINE_ITEMS_PER_OPP);
        System.debug('Batch size:         ' + BATCH_SIZE);
        System.debug('DML rows per batch: ' + dmlRowsPerBatch);
        System.debug('Expected total:     ~' + (oppCount * LINE_ITEMS_PER_OPP) + ' line items');

        Id jobId;
        if (START_INDEX > 0 && END_INDEX > 0) {
            System.debug('Mode: SCOPED (Opps ' + START_INDEX + ' to ' + END_INDEX + ')');
            jobId = Database.executeBatch(
                new LineItemCreatorBatch(LINE_ITEMS_PER_OPP, START_INDEX, END_INDEX), BATCH_SIZE);
        } else {
            System.debug('Mode: ALL BulkTest Opportunities');
            jobId = Database.executeBatch(
                new LineItemCreatorBatch(LINE_ITEMS_PER_OPP), BATCH_SIZE);
        }

        System.debug('Batch job submitted. Job ID: ' + jobId);
        System.debug('Monitor: Setup > Environments > Jobs > Apex Jobs');
    }
}
