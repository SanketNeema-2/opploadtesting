/**
 * OpportunityCreatorBatch
 *
 * Batch Apex class that creates Opportunity records at scale.
 * Uses Iterable<Integer> to generate work units (no source query needed).
 * Implements Database.Stateful to track success/failure counts across batches.
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Execute Anonymous:
 *     Database.executeBatch(new OpportunityCreatorBatch(500, false), 200);
 */
public class OpportunityCreatorBatch implements Database.Batchable<Integer>, Database.Stateful {

    private Integer totalRecords;
    private Integer startIndex;
    private Boolean chainLineItems;

    // Stateful counters (survive across batch executions)
    private Integer successCount = 0;
    private Integer failureCount = 0;
    private Integer batchNumber  = 0;

    // Field value pools for varied data
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
     * @param totalRecords   Total number of Opportunities to create
     * @param chainLineItems If true, auto-starts LineItemCreatorBatch on completion
     */
    public OpportunityCreatorBatch(Integer totalRecords, Boolean chainLineItems) {
        this(totalRecords, chainLineItems, 1);
    }

    /**
     * @param totalRecords   Total number of Opportunities to create
     * @param chainLineItems If true, auto-starts LineItemCreatorBatch on completion
     * @param startIndex     Starting index for record naming (for multi-run scenarios)
     */
    public OpportunityCreatorBatch(Integer totalRecords, Boolean chainLineItems, Integer startIndex) {
        this.totalRecords = totalRecords;
        this.chainLineItems = chainLineItems;
        this.startIndex = startIndex;
    }

    public Iterable<Integer> start(Database.BatchableContext bc) {
        List<Integer> workUnits = new List<Integer>();
        for (Integer i = startIndex; i < startIndex + totalRecords; i++) {
            workUnits.add(i);
        }
        System.debug('OpportunityCreatorBatch started. Records to create: ' + totalRecords +
                      ', starting at index: ' + startIndex);
        return workUnits;
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
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
                }
            }
        }

        System.debug('Batch #' + batchNumber + ' | scope: ' + scope.size() +
                      ' | running total — success: ' + successCount + ', failed: ' + failureCount);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== OPPORTUNITY CREATION COMPLETE ===');
        System.debug('Total Success: ' + successCount);
        System.debug('Total Failed:  ' + failureCount);
        System.debug('Total Batches: ' + batchNumber);
        System.debug('=====================================');

        if (chainLineItems && successCount > 0) {
            System.debug('Auto-chaining LineItemCreatorBatch (3 items per opp, batch size 200)...');
            Database.executeBatch(new LineItemCreatorBatch(3), 200);
        }
    }
}
