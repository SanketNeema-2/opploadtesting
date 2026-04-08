/**
 * LineItemCreatorBatch
 *
 * Batch Apex class that creates OpportunityLineItem records for existing
 * BulkTest Opportunities. Uses QueryLocator to iterate over Opportunities
 * and creates N line items per Opportunity.
 *
 * Supports two modes:
 *   - Unscoped: processes ALL BulkTest_Opp_% Opportunities
 *   - Scoped:   processes only Opportunities in a specific index range
 *               (used when chained from OpportunityCreatorBatch to avoid
 *               duplicating line items on Opportunities from previous runs)
 *
 * Prerequisites:
 *   - Products + PricebookEntries exist (01_create_products.apex)
 *   - Opportunities exist (OpportunityCreatorBatch)
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Execute Anonymous:
 *     // All BulkTest Opportunities:
 *     Database.executeBatch(new LineItemCreatorBatch(3), 200);
 *     // Scoped to a specific range (e.g., Opps 501-1000):
 *     Database.executeBatch(new LineItemCreatorBatch(3, 501, 1000), 200);
 */
public class LineItemCreatorBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer lineItemsPerOpp;
    private List<PricebookEntry> pricebookEntries;
    private Id stdPricebookId;

    // Scoping: when set, only process Opportunities in this name range
    private String nameFrom;  // e.g. 'BulkTest_Opp_000501'
    private String nameTo;    // e.g. 'BulkTest_Opp_001000'

    // Stateful counters
    private Integer successCount  = 0;
    private Integer failureCount  = 0;
    private Integer batchNumber   = 0;
    private Integer oppsProcessed = 0;

    /**
     * Unscoped constructor — creates line items for ALL BulkTest Opportunities.
     * @param lineItemsPerOpp Number of OpportunityLineItems to create per Opportunity
     */
    public LineItemCreatorBatch(Integer lineItemsPerOpp) {
        this.lineItemsPerOpp = lineItemsPerOpp;
        this.nameFrom = null;
        this.nameTo = null;
    }

    /**
     * Scoped constructor — creates line items only for Opportunities in the given index range.
     * Used by OpportunityCreatorBatch when chaining, to avoid duplicating line items
     * on Opportunities from previous runs.
     *
     * @param lineItemsPerOpp Number of OpportunityLineItems to create per Opportunity
     * @param startIndex      Starting Opportunity index (maps to BulkTest_Opp_XXXXXX naming)
     * @param endIndex        Ending Opportunity index (inclusive)
     */
    public LineItemCreatorBatch(Integer lineItemsPerOpp, Integer startIndex, Integer endIndex) {
        this.lineItemsPerOpp = lineItemsPerOpp;
        this.nameFrom = 'BulkTest_Opp_' + String.valueOf(startIndex).leftPad(6, '0');
        this.nameTo   = 'BulkTest_Opp_' + String.valueOf(endIndex).leftPad(6, '0');
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

        if (nameFrom != null && nameTo != null) {
            System.debug('LineItemCreatorBatch started (SCOPED). Range: ' + nameFrom + ' to ' + nameTo +
                          ', PricebookEntries: ' + pricebookEntries.size() +
                          ', LineItems per Opp: ' + lineItemsPerOpp);
            return Database.getQueryLocator([
                SELECT Id, Name, Pricebook2Id
                FROM Opportunity
                WHERE Name >= :nameFrom AND Name <= :nameTo
                ORDER BY Name
            ]);
        } else {
            System.debug('LineItemCreatorBatch started (ALL). PricebookEntries: ' + pricebookEntries.size() +
                          ', LineItems per Opp: ' + lineItemsPerOpp);
            return Database.getQueryLocator([
                SELECT Id, Name, Pricebook2Id
                FROM Opportunity
                WHERE Name LIKE 'BulkTest_Opp_%'
                ORDER BY Name
            ]);
        }
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
        System.debug('Mode:                    ' + (nameFrom != null ? 'SCOPED (' + nameFrom + ' to ' + nameTo + ')' : 'ALL'));
        System.debug('Opportunities processed: ' + oppsProcessed);
        System.debug('LineItems per Opp:       ' + lineItemsPerOpp);
        System.debug('Total Success:           ' + successCount);
        System.debug('Total Failed:            ' + failureCount);
        System.debug('Total Batches:           ' + batchNumber);
        System.debug('===================================');
    }
}
