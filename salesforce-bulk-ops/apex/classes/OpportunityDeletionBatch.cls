/**
 * OpportunityDeletionBatch
 *
 * Batch Apex class that deletes BulkTest Opportunity records.
 * OpportunityLineItems are cascade-deleted automatically by Salesforce.
 * Optionally chains to ProductCleanupBatch for full cleanup.
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Execute Anonymous:
 *     Database.executeBatch(new OpportunityDeletionBatch('ALL', true, false), 200);
 */
public class OpportunityDeletionBatch implements Database.Batchable<SObject>, Database.Stateful {

    private String  deleteScope;     // 'ALL', 'DATE', or 'PATTERN'
    private Date    afterDate;       // Used when deleteScope = 'DATE'
    private String  namePattern;     // Used when deleteScope = 'PATTERN'
    private Boolean deleteProducts;  // Chain ProductCleanupBatch after deletion
    private Boolean hardDelete;      // Permanently delete (skip Recycle Bin)

    // Stateful counters
    private Integer successCount = 0;
    private Integer failureCount = 0;
    private Integer batchNumber  = 0;

    /**
     * @param deleteScope    'ALL' (all BulkTest opps), 'DATE' (after specific date), 'PATTERN' (custom LIKE)
     * @param deleteProducts If true, chains ProductCleanupBatch after all Opps are deleted
     * @param hardDelete     If true, permanently deletes (skips Recycle Bin)
     */
    public OpportunityDeletionBatch(String deleteScope, Boolean deleteProducts, Boolean hardDelete) {
        this.deleteScope = deleteScope;
        this.namePattern = 'BulkTest_Opp_%';
        this.afterDate = Date.today().addDays(-365);
        this.deleteProducts = deleteProducts;
        this.hardDelete = hardDelete;
    }

    /**
     * Full constructor with all parameters.
     */
    public OpportunityDeletionBatch(String deleteScope, Date afterDate, String namePattern,
                                     Boolean deleteProducts, Boolean hardDelete) {
        this.deleteScope = deleteScope;
        this.afterDate = afterDate;
        this.namePattern = namePattern;
        this.deleteProducts = deleteProducts;
        this.hardDelete = hardDelete;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String query = 'SELECT Id, Name FROM Opportunity WHERE ';

        if (deleteScope == 'DATE') {
            query += 'Name LIKE \'BulkTest_Opp_%\' AND CreatedDate >= :afterDate';
            System.debug('Deleting BulkTest Opportunities created after: ' + afterDate);
        } else if (deleteScope == 'PATTERN') {
            query += 'Name LIKE :namePattern';
            System.debug('Deleting Opportunities matching: ' + namePattern);
        } else {
            query += 'Name LIKE \'BulkTest_Opp_%\'';
            System.debug('Deleting ALL BulkTest Opportunities');
        }

        query += ' ORDER BY CreatedDate ASC';
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        batchNumber++;

        List<Database.DeleteResult> results = Database.delete(scope, false);

        // Hard delete: empty recycle bin for permanently deleted records
        if (hardDelete) {
            List<Id> deletedIds = new List<Id>();
            for (Database.DeleteResult dr : results) {
                if (dr.isSuccess()) {
                    deletedIds.add(dr.getId());
                }
            }
            if (!deletedIds.isEmpty()) {
                Database.emptyRecycleBin(deletedIds);
            }
        }

        for (Database.DeleteResult dr : results) {
            if (dr.isSuccess()) {
                successCount++;
            } else {
                failureCount++;
                for (Database.Error err : dr.getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'Delete error [' + dr.getId() + ']: ' +
                        err.getStatusCode() + ' - ' + err.getMessage());
                }
            }
        }

        System.debug('Batch #' + batchNumber + ' | deleted: ' + scope.size() +
                      ' | running total — success: ' + successCount + ', failed: ' + failureCount);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== OPPORTUNITY DELETION COMPLETE ===');
        System.debug('Total Deleted:  ' + successCount);
        System.debug('Total Failed:   ' + failureCount);
        System.debug('Total Batches:  ' + batchNumber);
        System.debug('Hard Delete:    ' + hardDelete);
        System.debug('NOTE: LineItems were cascade-deleted with their parent Opportunities.');
        System.debug('=====================================');

        if (deleteProducts) {
            System.debug('Chaining ProductCleanupBatch...');
            Database.executeBatch(new ProductCleanupBatch(), 200);
        }
    }
}
