/**
 * LineItemCreatorBatch
 *
 * Batch Apex class that creates OpportunityLineItem records for existing
 * BulkTest Opportunities. Uses QueryLocator to iterate over Opportunities
 * and creates N line items per Opportunity.
 *
 * Prerequisites:
 *   - Products + PricebookEntries exist (01_create_products.apex)
 *   - Opportunities exist (OpportunityCreatorBatch)
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Execute Anonymous:
 *     Database.executeBatch(new LineItemCreatorBatch(3), 200);
 */
public class LineItemCreatorBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer lineItemsPerOpp;
    private List<PricebookEntry> pricebookEntries;
    private Id stdPricebookId;

    // Stateful counters
    private Integer successCount  = 0;
    private Integer failureCount  = 0;
    private Integer batchNumber   = 0;
    private Integer oppsProcessed = 0;

    /**
     * @param lineItemsPerOpp Number of OpportunityLineItems to create per Opportunity
     */
    public LineItemCreatorBatch(Integer lineItemsPerOpp) {
        this.lineItemsPerOpp = lineItemsPerOpp;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Cache PricebookEntries (small set, survives across batches via Database.Stateful)
        pricebookEntries = [
            SELECT Id, UnitPrice, Product2Id, Product2.Name
            FROM PricebookEntry
            WHERE Pricebook2.IsStandard = true
              AND IsActive = true
              AND Product2.Name LIKE 'BulkTest_%'
            ORDER BY Product2.Name
        ];

        stdPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        if (pricebookEntries.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'No BulkTest PricebookEntries found. Run 01_create_products.apex first.');
        }

        System.debug('LineItemCreatorBatch started. PricebookEntries: ' + pricebookEntries.size() +
                      ', LineItems per Opp: ' + lineItemsPerOpp);

        return Database.getQueryLocator([
            SELECT Id, Name, Pricebook2Id
            FROM Opportunity
            WHERE Name LIKE 'BulkTest_Opp_%'
            ORDER BY Name
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        batchNumber++;

        if (pricebookEntries.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Batch #' + batchNumber + ': No PricebookEntries. Skipping.');
            return;
        }

        // Ensure all Opportunities reference the standard Pricebook
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
                Integer pbeIdx = Math.mod(i, pricebookEntries.size());
                PricebookEntry pbe = pricebookEntries[pbeIdx];

                Decimal quantity  = 1 + Math.mod(i * 3 + oppsProcessed, 20);
                Decimal unitPrice = pbe.UnitPrice;

                lineItems.add(new OpportunityLineItem(
                    OpportunityId    = opp.Id,
                    PricebookEntryId = pbe.Id,
                    Quantity         = quantity,
                    UnitPrice        = unitPrice,
                    Description      = 'BulkTest LineItem #' + (i + 1) + ' for ' + opp.Name
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

        System.debug('Batch #' + batchNumber + ' | opps: ' + scope.size() +
                      ' | items: ' + lineItems.size() +
                      ' | running total — success: ' + successCount + ', failed: ' + failureCount);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== LINE ITEM CREATION COMPLETE ===');
        System.debug('Opportunities processed: ' + oppsProcessed);
        System.debug('LineItems per Opp:       ' + lineItemsPerOpp);
        System.debug('Total Success:           ' + successCount);
        System.debug('Total Failed:            ' + failureCount);
        System.debug('Total Batches:           ' + batchNumber);
        System.debug('===================================');
    }
}
