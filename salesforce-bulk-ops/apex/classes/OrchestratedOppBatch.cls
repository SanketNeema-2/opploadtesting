/**
 * OrchestratedOppBatch
 *
 * Self-chaining Batch Apex class that creates Opportunities in chunks and
 * orchestrates the full pipeline: Opps -> LineItems -> next Opps -> next LineItems -> ...
 *
 * Each chunk creates up to CHUNK_SIZE Opportunities, then chains to
 * OrchestratedLineItemBatch (if CHAIN_LINEITEMS=true) which in turn chains
 * back to the next OrchestratedOppBatch — forming a sequential pipeline
 * that runs hands-free until the grand total is reached or storage is exhausted.
 *
 * Chain flow (sequential safety):
 *   OrchestratedOppBatch(1-500)
 *     -> OrchestratedLineItemBatch(1-500)
 *       -> OrchestratedOppBatch(501-1000)
 *         -> OrchestratedLineItemBatch(501-1000)
 *           -> ... until remainingTotal = 0
 *
 * Stops the chain immediately on STORAGE_LIMIT_EXCEEDED errors.
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Use 05_run_orchestrated_create.apex (do not call this class directly)
 */
public class OrchestratedOppBatch implements Database.Batchable<Integer>, Database.Stateful {

    private Integer remainingTotal;   // Opps still to create across ALL future chunks
    private Integer chunkSize;        // Max Opps per cycle
    private Integer startIndex;       // Starting index for THIS chunk's naming
    private Boolean chainLineItems;   // Create LineItems after each chunk?
    private Integer lineItemsPerOpp;  // LineItems per Opp (passed forward through chain)

    // Computed in start()
    private Integer thisChunkSize;

    // Stateful counters (survive across batch executions within this job)
    private Integer successCount    = 0;
    private Integer failureCount    = 0;
    private Integer batchNumber     = 0;
    private Boolean storageExceeded = false;

    // Field value pools for varied data (same as OpportunityCreatorBatch)
    private static final List<String> STAGE_NAMES = new List<String>{
        'Prospecting', 'Qualification', 'Needs Analysis',
        'Value Proposition', 'Perception Analysis',
        'Proposal/Price Quote', 'Negotiation/Review',
        'Closed Won', 'Closed Lost'
    };

    private static final List<String> LEAD_SOURCES = new List<String>{
        'Web', 'Phone Inquiry', 'Partner Referral',
        'Purchased List', 'Other'
    };

    private static final List<String> TYPES = new List<String>{
        'Existing Customer - Upgrade', 'Existing Customer - Replacement',
        'Existing Customer - Downgrade', 'New Customer'
    };

    /**
     * @param remainingTotal  Total Opps still to create across all future chunks
     * @param chunkSize       Max Opportunities per cycle (e.g., 500)
     * @param startIndex      Starting index for THIS chunk's record naming
     * @param chainLineItems  If true, chain to OrchestratedLineItemBatch after each chunk
     * @param lineItemsPerOpp Number of LineItems per Opportunity (passed forward)
     */
    public OrchestratedOppBatch(Integer remainingTotal, Integer chunkSize,
                                 Integer startIndex, Boolean chainLineItems,
                                 Integer lineItemsPerOpp) {
        this.remainingTotal  = remainingTotal;
        this.chunkSize       = chunkSize;
        this.startIndex      = startIndex;
        this.chainLineItems  = chainLineItems;
        this.lineItemsPerOpp = lineItemsPerOpp;
    }

    public Iterable<Integer> start(Database.BatchableContext bc) {
        thisChunkSize = Math.min(chunkSize, remainingTotal);

        List<Integer> workUnits = new List<Integer>();
        for (Integer i = startIndex; i < startIndex + thisChunkSize; i++) {
            workUnits.add(i);
        }

        Integer endIdx = startIndex + thisChunkSize - 1;
        Integer nextRemaining = remainingTotal - thisChunkSize;

        System.debug('=== OrchestratedOppBatch START ===');
        System.debug('Chunk range:    ' + startIndex + ' to ' + endIdx +
                      ' (' + thisChunkSize + ' Opps)');
        System.debug('Remaining after this chunk: ' + nextRemaining);
        System.debug('Chain LineItems: ' + chainLineItems);
        System.debug('==================================');

        return workUnits;
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        if (storageExceeded) {
            return; // Skip remaining batches in this job
        }

        batchNumber++;
        List<Opportunity> opps = new List<Opportunity>();

        for (Integer idx : scope) {
            Integer stageIdx  = Math.mod(idx, STAGE_NAMES.size());
            Integer sourceIdx = Math.mod(idx, LEAD_SOURCES.size());
            Integer typeIdx   = Math.mod(idx, TYPES.size());

            Integer daysOffset = Math.mod(idx * 7, 365);
            Date closeDate = Date.today().addDays(daysOffset);

            Decimal amount = 1000 + Math.mod(idx * 1337, 499000);

            opps.add(new Opportunity(
                Name        = 'BulkTest_Opp_' + String.valueOf(idx).leftPad(6, '0'),
                StageName   = STAGE_NAMES[stageIdx],
                CloseDate   = closeDate,
                Amount      = amount,
                Probability = Math.mod(idx * 13, 101),
                LeadSource  = LEAD_SOURCES[sourceIdx],
                Type        = TYPES[typeIdx],
                Description = 'Bulk test opportunity #' + idx
            ));
        }

        List<Database.SaveResult> results = Database.insert(opps, false);

        for (Database.SaveResult sr : results) {
            if (sr.isSuccess()) {
                successCount++;
            } else {
                failureCount++;
                for (Database.Error err : sr.getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'Opp insert error: ' + err.getStatusCode() + ' - ' + err.getMessage());
                    if (err.getStatusCode() == StatusCode.STORAGE_LIMIT_EXCEEDED) {
                        storageExceeded = true;
                    }
                }
            }
        }

        System.debug('Batch #' + batchNumber + ' | scope: ' + scope.size() +
                      ' | running total - success: ' + successCount + ', failed: ' + failureCount +
                      (storageExceeded ? ' | *** STORAGE LIMIT HIT ***' : ''));
    }

    public void finish(Database.BatchableContext bc) {
        Integer endIndex = startIndex + thisChunkSize - 1;
        Integer nextRemaining = remainingTotal - thisChunkSize;

        System.debug('=== OrchestratedOppBatch CHUNK COMPLETE ===');
        System.debug('Chunk range:  ' + startIndex + ' to ' + endIndex);
        System.debug('Success:      ' + successCount);
        System.debug('Failed:       ' + failureCount);
        System.debug('Batches:      ' + batchNumber);
        System.debug('Remaining:    ' + nextRemaining + ' Opps left to create');
        System.debug('============================================');

        // STOP on storage limit
        if (storageExceeded) {
            System.debug(LoggingLevel.ERROR,
                '*** STORAGE_LIMIT_EXCEEDED detected. Stopping orchestration chain. ***');
            System.debug(LoggingLevel.ERROR,
                'Last successful range: ' + startIndex + ' to ' + endIndex +
                '. Resume later with START_INDEX = ' + (endIndex + 1) +
                ' on a larger org or after freeing storage.');
            return;
        }

        if (chainLineItems && successCount > 0) {
            // Chain to OrchestratedLineItemBatch for THIS chunk's Opps.
            // It will chain back to the next OrchestratedOppBatch when done.
            System.debug('Chaining to OrchestratedLineItemBatch (range: ' +
                          startIndex + ' to ' + endIndex + ', ' +
                          lineItemsPerOpp + ' items per opp)...');
            Database.executeBatch(
                new OrchestratedLineItemBatch(
                    lineItemsPerOpp, startIndex, endIndex,
                    nextRemaining, chunkSize, chainLineItems, lineItemsPerOpp
                ), 200
            );
        } else if (nextRemaining > 0) {
            // No LineItem chaining — go straight to next Opp chunk
            Integer nextStart = endIndex + 1;
            System.debug('Chaining to next OrchestratedOppBatch (start: ' +
                          nextStart + ', remaining: ' + nextRemaining + ')...');
            Database.executeBatch(
                new OrchestratedOppBatch(
                    nextRemaining, chunkSize, nextStart,
                    chainLineItems, lineItemsPerOpp
                ), 200
            );
        } else {
            System.debug('=== ORCHESTRATION COMPLETE (no more Opps to create) ===');
        }
    }
}
