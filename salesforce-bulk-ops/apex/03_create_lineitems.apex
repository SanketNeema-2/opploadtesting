// ============================================================================
// 03_create_lineitems.apex
// Batch class to create OpportunityLineItem records for existing Opportunities.
// Requires: Products + PricebookEntries (script 01) and Opportunities (script 02)
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
//        Run AFTER script 02 has completed successfully.
// ============================================================================

// ======================== CONFIGURATION ========================
Integer LINE_ITEMS_PER_OPP = 3;     // Number of line items per Opportunity
Integer BATCH_SIZE         = 200;   // Opportunities processed per batch
String  OPP_NAME_PATTERN   = 'BulkTest_Opp_%';  // Match pattern for target Opportunities
// ===============================================================

// --- Batch Class Definition ---
public class LineItemCreatorBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer lineItemsPerOpp;
    private List<PricebookEntry> pricebookEntries;

    // Stateful counters
    private Integer successCount = 0;
    private Integer failureCount = 0;
    private Integer batchNumber  = 0;
    private Integer oppsProcessed = 0;

    public LineItemCreatorBatch(Integer lineItemsPerOpp) {
        this.lineItemsPerOpp = lineItemsPerOpp;
    }

    // start(): Query Opportunities that need line items
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Pre-fetch PricebookEntries (small set, fits in memory)
        pricebookEntries = [
            SELECT Id, UnitPrice, Product2Id, Product2.Name
            FROM PricebookEntry
            WHERE Pricebook2.IsStandard = true
              AND IsActive = true
              AND Product2.Name LIKE 'BulkTest_%'
            ORDER BY Product2.Name
        ];

        if (pricebookEntries.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'No PricebookEntries found matching BulkTest_ pattern. ' +
                'Run 01_create_products.apex first.');
        }

        System.debug('Found ' + pricebookEntries.size() + ' PricebookEntries for line item creation');
        System.debug('LineItems per Opportunity: ' + lineItemsPerOpp);

        // Query Opportunities that don't already have line items from our scripts
        return Database.getQueryLocator([
            SELECT Id, Name, Pricebook2Id
            FROM Opportunity
            WHERE Name LIKE :OPP_NAME_PATTERN
            ORDER BY Name
        ]);
    }

    // execute(): Create LineItems for each Opportunity in this batch
    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        batchNumber++;

        if (pricebookEntries.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Batch #' + batchNumber + ': No PricebookEntries available. Skipping.');
            return;
        }

        // First, ensure all Opportunities reference the standard Pricebook
        Id stdPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        List<Opportunity> oppsToUpdate = new List<Opportunity>();
        for (Opportunity opp : scope) {
            if (opp.Pricebook2Id == null || opp.Pricebook2Id != stdPricebookId) {
                oppsToUpdate.add(new Opportunity(
                    Id = opp.Id,
                    Pricebook2Id = stdPricebookId
                ));
            }
        }
        if (!oppsToUpdate.isEmpty()) {
            Database.update(oppsToUpdate, false);
        }

        // Create LineItems
        List<OpportunityLineItem> lineItems = new List<OpportunityLineItem>();

        for (Opportunity opp : scope) {
            for (Integer i = 0; i < lineItemsPerOpp; i++) {
                // Rotate through available PricebookEntries
                Integer pbeIdx = Math.mod(i, pricebookEntries.size());
                PricebookEntry pbe = pricebookEntries[pbeIdx];

                // Vary quantity and discount per line item
                Decimal quantity  = 1 + Math.mod(i * 3 + oppsProcessed, 20);  // 1-20
                Decimal unitPrice = pbe.UnitPrice;
                Decimal discount  = Math.mod(i * 7 + oppsProcessed, 25);      // 0-24%

                lineItems.add(new OpportunityLineItem(
                    OpportunityId  = opp.Id,
                    PricebookEntryId = pbe.Id,
                    Quantity       = quantity,
                    UnitPrice      = unitPrice,
                    Description    = 'BulkTest LineItem #' + (i + 1) + ' for ' + opp.Name
                ));
            }
            oppsProcessed++;
        }

        List<Database.SaveResult> results = Database.insert(lineItems, false);

        for (Database.SaveResult sr : results) {
            if (sr.isSuccess()) {
                successCount++;
            } else {
                failureCount++;
                for (Database.Error err : sr.getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'LineItem insert error: ' + err.getStatusCode() + ' - ' + err.getMessage());
                }
            }
        }

        System.debug('Batch #' + batchNumber + ' complete. Opps in scope: ' + scope.size() +
                      ' | LineItems attempted: ' + lineItems.size() +
                      ' | Running total - Success: ' + successCount + ', Failed: ' + failureCount);
    }

    // finish(): Log final results
    public void finish(Database.BatchableContext bc) {
        System.debug('=== LINE ITEM CREATION COMPLETE ===');
        System.debug('Opportunities processed: ' + oppsProcessed);
        System.debug('LineItems per Opp:       ' + lineItemsPerOpp);
        System.debug('Total LineItems Success:  ' + successCount);
        System.debug('Total LineItems Failed:   ' + failureCount);
        System.debug('Total Batches:            ' + batchNumber);
        System.debug('===================================');
    }
}

// --- Pre-flight checks ---
Integer oppCount = [SELECT COUNT() FROM Opportunity WHERE Name LIKE :OPP_NAME_PATTERN];
Integer pbeCount = [SELECT COUNT() FROM PricebookEntry
                    WHERE Pricebook2.IsStandard = true AND IsActive = true
                      AND Product2.Name LIKE 'BulkTest_%'];

System.debug('Pre-flight: Found ' + oppCount + ' Opportunities matching pattern');
System.debug('Pre-flight: Found ' + pbeCount + ' PricebookEntries matching pattern');

if (oppCount == 0) {
    System.debug(LoggingLevel.ERROR, 'No Opportunities found. Run 02_create_opportunities.apex first.');
} else if (pbeCount == 0) {
    System.debug(LoggingLevel.ERROR, 'No PricebookEntries found. Run 01_create_products.apex first.');
} else {
    System.debug('Submitting LineItemCreatorBatch: ' + LINE_ITEMS_PER_OPP +
                 ' items per opp, batch size: ' + BATCH_SIZE);
    Id batchJobId = Database.executeBatch(new LineItemCreatorBatch(LINE_ITEMS_PER_OPP), BATCH_SIZE);
    System.debug('Batch Job submitted. Job ID: ' + batchJobId);
    System.debug('Expected total LineItems: ~' + (oppCount * LINE_ITEMS_PER_OPP));
    System.debug('Monitor at: Setup > Environments > Jobs > Apex Jobs');
}
