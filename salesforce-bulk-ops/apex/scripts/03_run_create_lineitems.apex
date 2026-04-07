// ============================================================================
// 03_run_create_lineitems.apex
// Invokes the LineItemCreatorBatch class to create OpportunityLineItems.
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
// ===============================================================

// --- Pre-flight checks ---
Integer oppCount = [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'BulkTest_Opp_%'];
Integer pbeCount = [SELECT COUNT() FROM PricebookEntry
                    WHERE Pricebook2.IsStandard = true AND IsActive = true
                      AND Product2.Name LIKE 'BulkTest_%'];

System.debug('Pre-flight: ' + oppCount + ' BulkTest Opportunities found');
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

        Id jobId = Database.executeBatch(new LineItemCreatorBatch(LINE_ITEMS_PER_OPP), BATCH_SIZE);

        System.debug('Batch job submitted. Job ID: ' + jobId);
        System.debug('Monitor: Setup > Environments > Jobs > Apex Jobs');
    }
}
