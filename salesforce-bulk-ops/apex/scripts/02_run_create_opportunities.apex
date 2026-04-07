// ============================================================================
// 02_run_create_opportunities.apex
// Invokes the OpportunityCreatorBatch class to create Opportunities at scale.
//
// PREREQUISITE: Deploy OpportunityCreatorBatch.cls to the org first.
//   Setup > Apex Classes > New > paste OpportunityCreatorBatch.cls > Save
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
//        Monitor: Setup > Apex Jobs
// ============================================================================

// ======================== CONFIGURATION ========================
Integer TOTAL_OPPORTUNITIES = 500;   // Total Opportunities to create
Integer BATCH_SIZE          = 200;   // Records per batch (max 2000, recommended 200)
Boolean CHAIN_LINEITEMS     = false; // Auto-start LineItemCreatorBatch on completion
Integer START_INDEX         = 1;     // Starting index (increase for subsequent runs)
// ===============================================================

System.debug('=== Submitting OpportunityCreatorBatch ===');
System.debug('Total records: ' + TOTAL_OPPORTUNITIES);
System.debug('Batch size:    ' + BATCH_SIZE);
System.debug('Start index:   ' + START_INDEX);
System.debug('Chain items:   ' + CHAIN_LINEITEMS);

Id jobId = Database.executeBatch(
    new OpportunityCreatorBatch(TOTAL_OPPORTUNITIES, CHAIN_LINEITEMS, START_INDEX),
    BATCH_SIZE
);

System.debug('Batch job submitted. Job ID: ' + jobId);
System.debug('Monitor: Setup > Environments > Jobs > Apex Jobs');
System.debug('Query:   SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors FROM AsyncApexJob WHERE Id = \'' + jobId + '\'');
System.debug('Next run: set START_INDEX = ' + (START_INDEX + TOTAL_OPPORTUNITIES));
