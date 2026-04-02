// ============================================================================
// 04_delete_opportunities.apex
// Batch class to delete Opportunities (and cascade-delete their LineItems).
// Optionally deletes Products and PricebookEntries created by the scripts.
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
// ============================================================================

// ======================== CONFIGURATION ========================
String  DELETE_SCOPE       = 'ALL';   // 'ALL' = all BulkTest_ opps
                                       // 'DATE' = created after DELETE_AFTER_DATE
                                       // 'PATTERN' = custom name pattern
Date    DELETE_AFTER_DATE  = Date.today().addDays(-30);  // Used when DELETE_SCOPE = 'DATE'
String  DELETE_PATTERN     = 'BulkTest_Opp_%';           // Name pattern to match
Integer BATCH_SIZE         = 200;     // Records per batch
Boolean DELETE_PRODUCTS    = true;    // Also delete Products + PricebookEntries after Opps
Boolean USE_HARD_DELETE    = false;   // true = permanent delete (skip Recycle Bin)
                                       // Requires "Bulk API Hard Delete" permission
// ===============================================================

// --- Opportunity Deletion Batch ---
public class OpportunityDeletionBatch implements Database.Batchable<SObject>, Database.Stateful {

    private String scope;
    private Date afterDate;
    private String namePattern;
    private Boolean deleteProducts;
    private Boolean hardDelete;

    // Stateful counters
    private Integer successCount = 0;
    private Integer failureCount = 0;
    private Integer batchNumber  = 0;

    public OpportunityDeletionBatch(String scope, Date afterDate, String namePattern,
                                     Boolean deleteProducts, Boolean hardDelete) {
        this.scope = scope;
        this.afterDate = afterDate;
        this.namePattern = namePattern;
        this.deleteProducts = deleteProducts;
        this.hardDelete = hardDelete;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String query = 'SELECT Id, Name, CreatedDate FROM Opportunity WHERE ';

        if (scope == 'DATE') {
            query += 'Name LIKE \'BulkTest_Opp_%\' AND CreatedDate >= :afterDate';
            System.debug('Deleting BulkTest Opportunities created after: ' + afterDate);
        } else if (scope == 'PATTERN') {
            query += 'Name LIKE :namePattern';
            System.debug('Deleting Opportunities matching pattern: ' + namePattern);
        } else {
            // Default: ALL BulkTest_ opportunities
            query += 'Name LIKE \'BulkTest_Opp_%\'';
            System.debug('Deleting ALL BulkTest Opportunities');
        }

        query += ' ORDER BY CreatedDate ASC';
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        batchNumber++;

        List<Database.DeleteResult> results;
        if (hardDelete) {
            // emptyRecycleBin permanently deletes
            results = Database.delete(scope, false);
            if (!results.isEmpty()) {
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
        } else {
            results = Database.delete(scope, false);
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

        System.debug('Batch #' + batchNumber + ' - Deleted: ' + scope.size() +
                      ' | Running total - Success: ' + successCount + ', Failed: ' + failureCount);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== OPPORTUNITY DELETION COMPLETE ===');
        System.debug('Total Deleted:  ' + successCount);
        System.debug('Total Failed:   ' + failureCount);
        System.debug('Total Batches:  ' + batchNumber);
        System.debug('Hard Delete:    ' + hardDelete);
        System.debug('=====================================');
        System.debug('NOTE: OpportunityLineItems are automatically cascade-deleted with their parent Opportunity.');

        if (deleteProducts) {
            System.debug('Chaining Product cleanup batch...');
            Database.executeBatch(new ProductCleanupBatch(), 200);
        }
    }
}

// --- Product + PricebookEntry Cleanup Batch ---
public class ProductCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer pbeDeleted = 0;
    private Integer prodDeleted = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        System.debug('Starting Product cleanup for BulkTest_ records');
        return Database.getQueryLocator([
            SELECT Id, Name FROM Product2 WHERE Name LIKE 'BulkTest_%' ORDER BY Name
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Product2> scope) {
        // First delete PricebookEntries referencing these products
        Set<Id> productIds = new Set<Id>();
        for (Product2 p : scope) {
            productIds.add(p.Id);
        }

        List<PricebookEntry> pbes = [
            SELECT Id FROM PricebookEntry WHERE Product2Id IN :productIds
        ];

        if (!pbes.isEmpty()) {
            List<Database.DeleteResult> pbeResults = Database.delete(pbes, false);
            for (Database.DeleteResult dr : pbeResults) {
                if (dr.isSuccess()) pbeDeleted++;
            }
        }

        // Then delete Products
        List<Database.DeleteResult> prodResults = Database.delete(scope, false);
        for (Database.DeleteResult dr : prodResults) {
            if (dr.isSuccess()) prodDeleted++;
        }

        System.debug('Cleanup batch - PBEs deleted: ' + pbeDeleted + ', Products deleted: ' + prodDeleted);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== PRODUCT CLEANUP COMPLETE ===');
        System.debug('PricebookEntries deleted: ' + pbeDeleted);
        System.debug('Products deleted:         ' + prodDeleted);
        System.debug('================================');
    }
}

// --- Pre-flight: Show what will be deleted ---
Integer oppCount = [SELECT COUNT() FROM Opportunity WHERE Name LIKE 'BulkTest_Opp_%'];
Integer liCount  = [SELECT COUNT() FROM OpportunityLineItem
                    WHERE Opportunity.Name LIKE 'BulkTest_Opp_%'];
Integer prodCount = [SELECT COUNT() FROM Product2 WHERE Name LIKE 'BulkTest_%'];
Integer pbeCount  = [SELECT COUNT() FROM PricebookEntry
                     WHERE Product2.Name LIKE 'BulkTest_%'];

System.debug('=== DELETION PRE-FLIGHT ===');
System.debug('Opportunities to delete:      ' + oppCount);
System.debug('LineItems (cascade-deleted):   ' + liCount);
System.debug('Products to delete:            ' + (DELETE_PRODUCTS ? String.valueOf(prodCount) : 'SKIPPED'));
System.debug('PricebookEntries to delete:    ' + (DELETE_PRODUCTS ? String.valueOf(pbeCount) : 'SKIPPED'));
System.debug('Scope:      ' + DELETE_SCOPE);
System.debug('Hard delete: ' + USE_HARD_DELETE);
System.debug('===========================');

if (oppCount == 0 && (DELETE_PRODUCTS == false || prodCount == 0)) {
    System.debug('Nothing to delete. Exiting.');
} else {
    Id batchJobId = Database.executeBatch(
        new OpportunityDeletionBatch(DELETE_SCOPE, DELETE_AFTER_DATE, DELETE_PATTERN,
                                      DELETE_PRODUCTS, USE_HARD_DELETE),
        BATCH_SIZE
    );
    System.debug('Deletion batch submitted. Job ID: ' + batchJobId);
    System.debug('Monitor at: Setup > Environments > Jobs > Apex Jobs');
}
