/**
 * ProductCleanupBatch
 *
 * Batch Apex class that deletes BulkTest Product2 and PricebookEntry records.
 * Typically chained from OpportunityDeletionBatch after Opportunities are deleted.
 *
 * Deploy: Setup > Apex Classes > New > paste this file > Save
 * Invoke: Execute Anonymous:
 *     Database.executeBatch(new ProductCleanupBatch(), 200);
 */
public class ProductCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer pbeDeleted  = 0;
    private Integer prodDeleted = 0;
    private Integer batchNumber = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        System.debug('ProductCleanupBatch started. Deleting BulkTest_ products and pricebook entries.');
        return Database.getQueryLocator([
            SELECT Id, Name FROM Product2 WHERE Name LIKE 'BulkTest_%' ORDER BY Name
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Product2> scope) {
        batchNumber++;

        // Collect product IDs
        Set<Id> productIds = new Set<Id>();
        for (Product2 p : scope) {
            productIds.add(p.Id);
        }

        // Delete PricebookEntries first (FK constraint: can't delete Product while PBE references it)
        List<PricebookEntry> pbes = [
            SELECT Id FROM PricebookEntry WHERE Product2Id IN :productIds
        ];

        if (!pbes.isEmpty()) {
            List<Database.DeleteResult> pbeResults = Database.delete(pbes, false);
            for (Database.DeleteResult dr : pbeResults) {
                if (dr.isSuccess()) pbeDeleted++;
            }
        }

        // Delete Products
        List<Database.DeleteResult> prodResults = Database.delete(scope, false);
        for (Database.DeleteResult dr : prodResults) {
            if (dr.isSuccess()) prodDeleted++;
        }

        System.debug('Batch #' + batchNumber + ' | PBEs deleted: ' + pbeDeleted +
                      ', Products deleted: ' + prodDeleted);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('=== PRODUCT CLEANUP COMPLETE ===');
        System.debug('PricebookEntries deleted: ' + pbeDeleted);
        System.debug('Products deleted:         ' + prodDeleted);
        System.debug('Total Batches:            ' + batchNumber);
        System.debug('================================');
    }
}
