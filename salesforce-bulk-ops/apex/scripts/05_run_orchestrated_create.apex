// ============================================================================
// 05_run_orchestrated_create.apex
// Orchestrated, fully-automated bulk creation of Opportunities + LineItems.
//
// One paste-and-run. You set TOTAL_OPPORTUNITIES and CHUNK_SIZE, and the
// system chains automatically:
//
//   OrchestratedOppBatch(chunk 1)
//     -> OrchestratedLineItemBatch(chunk 1)
//       -> OrchestratedOppBatch(chunk 2)
//         -> OrchestratedLineItemBatch(chunk 2)
//           -> ... until grand total reached or storage exhausted
//
// START_INDEX auto-detects from existing data (set to 0). If you already
// have BulkTest_Opp_000500 in the org, it starts at 501 automatically.
//
// Stops the entire chain on the first STORAGE_LIMIT_EXCEEDED error.
//
// PREREQUISITES:
//   1. Deploy these classes to the org (Setup > Apex Classes > New):
//      - OrchestratedOppBatch.cls
//      - OrchestratedLineItemBatch.cls
//   2. Run 01_create_products.apex (Products + PricebookEntries must exist)
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
//        Monitor: Setup > Environments > Jobs > Apex Jobs
// ============================================================================

// ======================== CONFIGURATION ========================
Integer TOTAL_OPPORTUNITIES = 50000;    // Grand total Opportunities to create
Integer CHUNK_SIZE          = 500;    // Opportunities per orchestration cycle
                                       // Each cycle: create CHUNK_SIZE Opps,
                                       // then create their LineItems,
                                       // then start the next cycle.
Boolean CHAIN_LINEITEMS     = true;   // Create LineItems after each Opp chunk
Integer LINE_ITEMS_PER_OPP  = 3;     // LineItems per Opportunity

// START_INDEX: Set to 0 for auto-detect (recommended).
// Auto-detect queries the highest existing BulkTest_Opp_XXXXXX and starts
// at the next index. Set to a specific value to override.
Integer START_INDEX         = 0;
// ===============================================================

// --- Auto-detect START_INDEX ---
if (START_INDEX == 0) {
    List<Opportunity> lastOpp = [
        SELECT Name FROM Opportunity
        WHERE Name LIKE 'BulkTest_Opp_%'
        ORDER BY Name DESC
        LIMIT 1
    ];
    if (!lastOpp.isEmpty()) {
        String lastNum = lastOpp[0].Name.substringAfter('BulkTest_Opp_');
        START_INDEX = Integer.valueOf(lastNum) + 1;
        System.debug('Auto-detected START_INDEX = ' + START_INDEX +
                      ' (last existing: ' + lastOpp[0].Name + ')');
    } else {
        START_INDEX = 1;
        System.debug('No existing BulkTest Opportunities found. START_INDEX = 1');
    }
} else {
    System.debug('Manual START_INDEX = ' + START_INDEX);
}

// --- Pre-flight validation ---
Boolean valid = true;

if (TOTAL_OPPORTUNITIES <= 0) {
    System.debug(LoggingLevel.ERROR, 'TOTAL_OPPORTUNITIES must be > 0');
    valid = false;
}

if (CHUNK_SIZE <= 0) {
    System.debug(LoggingLevel.ERROR, 'CHUNK_SIZE must be > 0');
    valid = false;
}

if (CHUNK_SIZE > TOTAL_OPPORTUNITIES) {
    CHUNK_SIZE = TOTAL_OPPORTUNITIES;
    System.debug('CHUNK_SIZE adjusted to TOTAL_OPPORTUNITIES: ' + CHUNK_SIZE);
}

if (CHAIN_LINEITEMS) {
    Integer pbeCount = [SELECT COUNT() FROM PricebookEntry
                        WHERE Pricebook2.IsStandard = true AND IsActive = true
                          AND Product2.Name LIKE 'BulkTest_%'];
    if (pbeCount == 0) {
        System.debug(LoggingLevel.ERROR,
            'No BulkTest PricebookEntries found. Run 01_create_products.apex first.');
        valid = false;
    } else {
        System.debug('Pre-flight: ' + pbeCount + ' BulkTest PricebookEntries found');
    }
}

// --- Storage estimate ---
Integer endIndex = START_INDEX + TOTAL_OPPORTUNITIES - 1;
Integer totalChunks = (Integer)Math.ceil((Decimal)TOTAL_OPPORTUNITIES / CHUNK_SIZE);

Decimal estKbPerOpp;
if (CHAIN_LINEITEMS) {
    estKbPerOpp = 3 + (LINE_ITEMS_PER_OPP * 2);  // ~3 KB Opp + ~2 KB per LineItem
} else {
    estKbPerOpp = 3;
}
Decimal estTotalKb = TOTAL_OPPORTUNITIES * estKbPerOpp;
Decimal estTotalMb = estTotalKb / 1024;

System.debug('--- Storage Estimate ---');
System.debug('Estimated ' + estTotalKb.setScale(0) + ' KB (' +
              estTotalMb.setScale(1) + ' MB) for ' + TOTAL_OPPORTUNITIES +
              ' Opps' + (CHAIN_LINEITEMS ? ' + ' + LINE_ITEMS_PER_OPP + ' LineItems each' : ''));

if (estTotalMb > 5) {
    System.debug(LoggingLevel.WARN,
        '*** WARNING: Estimated storage (' + estTotalMb.setScale(1) +
        ' MB) exceeds Developer Edition limit (5 MB). ' +
        'The chain will stop automatically on STORAGE_LIMIT_EXCEEDED. ***');
}

// --- Submit orchestrated batch ---
if (valid) {
    System.debug('=== Submitting OrchestratedOppBatch ===');
    System.debug('Grand total:     ' + TOTAL_OPPORTUNITIES + ' Opportunities');
    System.debug('Chunk size:      ' + CHUNK_SIZE + ' Opps per cycle');
    System.debug('Total chunks:    ' + totalChunks);
    System.debug('Index range:     ' + START_INDEX + ' to ' + endIndex);
    System.debug('Batch size:      200 (hardcoded)');
    System.debug('Chain LineItems: ' + CHAIN_LINEITEMS +
                  (CHAIN_LINEITEMS ? ' (' + LINE_ITEMS_PER_OPP + ' per Opp)' : ''));

    if (CHAIN_LINEITEMS) {
        Integer totalJobs = totalChunks * 2;  // 1 OppBatch + 1 LineItemBatch per chunk
        System.debug('Pipeline jobs:   ~' + totalJobs +
                      ' batch jobs (' + totalChunks + ' Opp + ' + totalChunks + ' LineItem)');
        System.debug('Pipeline flow:   OppBatch -> LineItemBatch -> OppBatch -> ... (sequential)');
    }

    Id jobId = Database.executeBatch(
        new OrchestratedOppBatch(
            TOTAL_OPPORTUNITIES, CHUNK_SIZE, START_INDEX,
            CHAIN_LINEITEMS, LINE_ITEMS_PER_OPP
        ), 200
    );

    System.debug('First batch job submitted. Job ID: ' + jobId);
    System.debug('The chain will continue automatically until completion or storage limit.');
    System.debug('Monitor: Setup > Environments > Jobs > Apex Jobs');
    System.debug('Query all jobs:');
    System.debug('  SELECT Id, ApexClass.Name, Status, JobItemsProcessed, TotalJobItems,');
    System.debug('         NumberOfErrors, CreatedDate, CompletedDate');
    System.debug('  FROM AsyncApexJob');
    System.debug('  WHERE JobType = \'BatchApex\'');
    System.debug('  ORDER BY CreatedDate DESC LIMIT 20');
}
