// ============================================================================
// 04_run_delete.apex
// Invokes OpportunityDeletionBatch (and optionally ProductCleanupBatch)
// to clean up all BulkTest records.
//
// PREREQUISITES:
//   Deploy these classes to the org:
//   1. OpportunityDeletionBatch.cls  (Setup > Apex Classes > New)
//   2. ProductCleanupBatch.cls       (Setup > Apex Classes > New)
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
//        Monitor: Setup > Apex Jobs
// ============================================================================

// ======================== CONFIGURATION ========================
String  DELETE_SCOPE    = 'ALL';   // 'ALL'     = all BulkTest_Opp_% opportunities
                                    // 'DATE'    = created after a specific date
                                    // 'PATTERN' = custom LIKE pattern
Integer BATCH_SIZE      = 200;     // Records per batch
Boolean DELETE_PRODUCTS = true;    // Also delete Products + PricebookEntries (chains ProductCleanupBatch)
Boolean HARD_DELETE     = false;   // true = permanent delete, skip Recycle Bin
// ===============================================================

// --- Pre-flight: Show what will be deleted ---
Integer oppCount  = [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'BulkTest_Opp_%'];
Integer liCount   = [SELECT COUNT() FROM OpportunityLineItem WHERE Opportunity.Name LIKE 'BulkTest_Opp_%'];
Integer prodCount = [SELECT COUNT() FROM Product2 WHERE Name LIKE 'BulkTest_%'];
Integer pbeCount  = [SELECT COUNT() FROM PricebookEntry WHERE Product2.Name LIKE 'BulkTest_%'];

System.debug('=== DELETION PRE-FLIGHT ===');
System.debug('Opportunities:      ' + oppCount);
System.debug('LineItems (cascade): ' + liCount);
System.debug('Products:            ' + (DELETE_PRODUCTS ? String.valueOf(prodCount) : 'SKIP'));
System.debug('PricebookEntries:    ' + (DELETE_PRODUCTS ? String.valueOf(pbeCount) : 'SKIP'));
System.debug('Scope:               ' + DELETE_SCOPE);
System.debug('Hard delete:         ' + HARD_DELETE);
System.debug('===========================');

if (oppCount == 0 && (!DELETE_PRODUCTS || prodCount == 0)) {
    System.debug('Nothing to delete.');
} else if (oppCount == 0 && DELETE_PRODUCTS && prodCount > 0) {
    // No opps but products exist — just clean up products directly
    System.debug('No Opportunities to delete. Running ProductCleanupBatch only...');
    Id jobId = Database.executeBatch(new ProductCleanupBatch(), BATCH_SIZE);
    System.debug('ProductCleanupBatch submitted. Job ID: ' + jobId);
} else {
    Id jobId = Database.executeBatch(
        new OpportunityDeletionBatch(DELETE_SCOPE, DELETE_PRODUCTS, HARD_DELETE),
        BATCH_SIZE
    );
    System.debug('OpportunityDeletionBatch submitted. Job ID: ' + jobId);
    if (DELETE_PRODUCTS) {
        System.debug('ProductCleanupBatch will auto-chain after Opportunity deletion completes.');
    }
    System.debug('Monitor: Setup > Environments > Jobs > Apex Jobs');
}
