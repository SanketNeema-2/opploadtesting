/**
 * OrchestratedLineItemBatch
 *
 * Batch Apex class that creates OpportunityLineItems for a scoped range of
 * BulkTest Opportunities, then chains to the next OrchestratedOppBatch
 * to continue the orchestration pipeline.
 *
 * Chain flow (sequential safety):
 *   OrchestratedOppBatch(1-500)
 *     -> THIS CLASS: OrchestratedLineItemBatch(1-500)
 *       -> OrchestratedOppBatch(501-1000)
 *         -> OrchestratedLineItemBatch(501-1000)
 *           -> ... until remainingOppTotal = 0
 *
 * Stops the chain immediately on STORAGE_LIMIT_EXCEEDED errors.
 *
 * Prerequisites:
 *   - Products + PricebookEntries exist (01_create_products.apex)
 *   - Opportunities for the scoped range exist (created by OrchestratedOppBatch)
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Called automatically by OrchestratedOppBatch (do not call directly)
 */
public class OrchestratedLineItemBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer lineItemsPerOpp;
    private List<PricebookEntry> pricebookEntries;
    private Id stdPricebookId;

    // Scoping: process only Opportunities in this name range
    private String nameFrom;  // e.g. 'BulkTest_Opp_000501'
    private String nameTo;    // e.g. 'BulkTest_Opp_001000'

    // Forward-chain metadata (passed to the next OrchestratedOppBatch)
    private Integer remainingOppTotal;    // Opps still to create after this chunk (0 = last chunk)
    private Integer chunkSize;            // Opp chunk size for next cycle
    private Integer nextOppStartIndex;    // Where the next Opp chunk starts
    private Boolean chainLineItems;       // Pass through to next OppBatch
    private Integer lineItemsPerOppFwd;   // Pass through to next OppBatch

    // Stateful counters
    private Integer successCount    = 0;
    private Integer failureCount    = 0;
    private Integer batchNumber     = 0;
    private Integer oppsProcessed   = 0;
    private Boolean storageExceeded = false;

    /**
     * @param lineItemsPerOpp     Number of OpportunityLineItems to create per Opportunity
     * @param oppStartIndex       Starting Opportunity index (maps to BulkTest_Opp_XXXXXX)
     * @param oppEndIndex         Ending Opportunity index (inclusive)
     * @param remainingOppTotal   Opps remaining to create after this LineItem chunk (0 = done)
     * @param chunkSize           Opp chunk size for the next OrchestratedOppBatch
     * @param chainLineItems      Pass-through: whether future Opp chunks should chain LineItems
     * @param lineItemsPerOppFwd  Pass-through: LineItems per Opp for future chunks
     */
    public OrchestratedLineItemBatch(Integer lineItemsPerOpp,
                                      Integer oppStartIndex, Integer oppEndIndex,
                                      Integer remainingOppTotal, Integer chunkSize,
                                      Boolean chainLineItems, Integer lineItemsPerOppFwd) {
        this.lineItemsPerOpp    = lineItemsPerOpp;
        this.nameFrom           = 'BulkTest_Opp_' + String.valueOf(oppStartIndex).leftPad(6, '0');
        this.nameTo             = 'BulkTest_Opp_' + String.valueOf(oppEndIndex).leftPad(6, '0');
        this.nextOppStartIndex  = oppEndIndex + 1;
        this.remainingOppTotal  = remainingOppTotal;
        this.chunkSize          = chunkSize;
        this.chainLineItems     = chainLineItems;
        this.lineItemsPerOppFwd = lineItemsPerOppFwd;
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

        System.debug('=== OrchestratedLineItemBatch START ===');
        System.debug('Opp range:       ' + nameFrom + ' to ' + nameTo);
        System.debug('PricebookEntries: ' + pricebookEntries.size());
        System.debug('LineItems/Opp:   ' + lineItemsPerOpp);
        System.debug('Remaining Opps after this: ' + remainingOppTotal);
        System.debug('========================================');

        return Database.getQueryLocator([
            SELECT Id, Name, Pricebook2Id
            FROM Opportunity
            WHERE Name >= :nameFrom AND Name <= :nameTo
            ORDER BY Name
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        if (storageExceeded) {
            return; // Skip remaining batches in this job
        }

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
                    if (err.getStatusCode() == StatusCode.STORAGE_LIMIT_EXCEEDED) {
                        storageExceeded = true;
                    }
                }
            }
        }

        System.debug('Batch #' + batchNumber + ' | opps: ' + scope.size() +
                      ' | items: ' + lineItems.size() +
                      ' | running total - success: ' + successCount + ', failed: ' + failureCount +
                      (storageExceeded ? ' | *** STORAGE LIMIT HIT ***' : ''));
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== OrchestratedLineItemBatch CHUNK COMPLETE ===');
        System.debug('Opp range:      ' + nameFrom + ' to ' + nameTo);
        System.debug('Opps processed: ' + oppsProcessed);
        System.debug('LineItems/Opp:  ' + lineItemsPerOpp);
        System.debug('Success:        ' + successCount);
        System.debug('Failed:         ' + failureCount);
        System.debug('Batches:        ' + batchNumber);
        System.debug('=================================================');

        // STOP on storage limit
        if (storageExceeded) {
            System.debug(LoggingLevel.ERROR,
                '*** STORAGE_LIMIT_EXCEEDED detected during LineItem creation. Stopping orchestration chain. ***');
            System.debug(LoggingLevel.ERROR,
                'LineItems completed for range: ' + nameFrom + ' to ' + nameTo +
                '. Remaining Opps not created: ' + remainingOppTotal +
                '. Free storage or upgrade org before resuming.');
            return;
        }

        if (remainingOppTotal > 0) {
            // Chain to next OrchestratedOppBatch for the next chunk of Opportunities
            System.debug('Chaining to next OrchestratedOppBatch (start: ' +
                          nextOppStartIndex + ', remaining: ' + remainingOppTotal + ')...');
            Database.executeBatch(
                new OrchestratedOppBatch(
                    remainingOppTotal, chunkSize, nextOppStartIndex,
                    chainLineItems, lineItemsPerOppFwd
                ), 200
            );
        } else {
            System.debug('============================================');
            System.debug('=== GRAND ORCHESTRATION COMPLETE ===');
            System.debug('All Opportunity and LineItem chunks processed.');
            System.debug('No more work remaining.');
            System.debug('============================================');
        }
    }
}
