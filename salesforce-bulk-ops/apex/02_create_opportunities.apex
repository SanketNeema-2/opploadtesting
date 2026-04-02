// ============================================================================
// 02_create_opportunities.apex
// Batch class to create Opportunity records at configurable scale.
// Uses Database.Batchable with Iterable<Integer> to generate data.
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
//        Monitor: Setup > Apex Jobs  OR  query AsyncApexJob
// ============================================================================

// ======================== CONFIGURATION ========================
Integer TOTAL_OPPORTUNITIES = 500;  // Total number of Opportunities to create
Integer BATCH_SIZE          = 200;  // Records per batch execution (max 2000, recommended 200)
Boolean CHAIN_LINEITEMS     = false; // If true, auto-starts LineItem batch on completion
// ===============================================================

// --- Batch Class Definition ---
public class OpportunityCreatorBatch implements Database.Batchable<Integer>, Database.Stateful {

    private Integer totalRecords;
    private Boolean chainLineItems;

    // Stateful counters
    private Integer successCount = 0;
    private Integer failureCount = 0;
    private Integer batchNumber  = 0;

    // Opportunity field value pools for randomization
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

    public OpportunityCreatorBatch(Integer totalRecords, Boolean chainLineItems) {
        this.totalRecords = totalRecords;
        this.chainLineItems = chainLineItems;
    }

    // start(): Generate a list of integers as work units
    public Iterable<Integer> start(Database.BatchableContext bc) {
        List<Integer> workUnits = new List<Integer>();
        for (Integer i = 1; i <= totalRecords; i++) {
            workUnits.add(i);
        }
        System.debug('OpportunityCreatorBatch started. Total records to create: ' + totalRecords);
        return workUnits;
    }

    // execute(): Create Opportunity records for this batch
    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        batchNumber++;
        List<Opportunity> opps = new List<Opportunity>();

        for (Integer idx : scope) {
            // Generate varied but deterministic data based on index
            Integer stageIdx  = Math.mod(idx, STAGE_NAMES.size());
            Integer sourceIdx = Math.mod(idx, LEAD_SOURCES.size());
            Integer typeIdx   = Math.mod(idx, TYPES.size());

            // CloseDate: spread across next 12 months
            Integer daysOffset = Math.mod(idx * 7, 365);
            Date closeDate = Date.today().addDays(daysOffset);

            // Amount: varied range $1,000 - $500,000
            Decimal amount = 1000 + Math.mod(idx * 1337, 499000);

            opps.add(new Opportunity(
                Name        = 'BulkTest_Opp_' + String.valueOf(idx).leftPad(6, '0'),
                StageName   = STAGE_NAMES[stageIdx],
                CloseDate   = closeDate,
                Amount      = amount,
                Probability = Math.mod(idx * 13, 101),  // 0-100
                LeadSource  = LEAD_SOURCES[sourceIdx],
                Type        = TYPES[typeIdx],
                Description = 'Bulk test opportunity #' + idx + ' created via Apex batch'
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

        System.debug('Batch #' + batchNumber + ' complete. Scope size: ' + scope.size() +
                      ' | Running total - Success: ' + successCount + ', Failed: ' + failureCount);
    }

    // finish(): Log final results, optionally chain LineItem batch
    public void finish(Database.BatchableContext bc) {
        System.debug('=== OPPORTUNITY CREATION COMPLETE ===');
        System.debug('Total Success: ' + successCount);
        System.debug('Total Failed:  ' + failureCount);
        System.debug('Total Batches: ' + batchNumber);
        System.debug('=====================================');

        if (chainLineItems && successCount > 0) {
            System.debug('Chaining OpportunityLineItem batch...');
            // NOTE: To auto-chain, the LineItemCreatorBatch class must already
            // be deployed. See 03_create_lineitems.apex.
            // Uncomment the line below after deploying the LineItem batch class:
            // Database.executeBatch(new LineItemCreatorBatch(3), 200);
        }
    }
}

// --- Execute the batch ---
System.debug('Submitting OpportunityCreatorBatch: ' + TOTAL_OPPORTUNITIES + ' records, batch size: ' + BATCH_SIZE);
Id batchJobId = Database.executeBatch(new OpportunityCreatorBatch(TOTAL_OPPORTUNITIES, CHAIN_LINEITEMS), BATCH_SIZE);
System.debug('Batch Job submitted. Job ID: ' + batchJobId);
System.debug('Monitor at: Setup > Environments > Jobs > Apex Jobs');
System.debug('Or run: SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors FROM AsyncApexJob WHERE Id = \'' + batchJobId + '\'');
