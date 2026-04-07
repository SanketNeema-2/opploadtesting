// ============================================================================
// 01_create_products.apex
// Creates Product2 records and their Standard PricebookEntry records.
// Run this FIRST before creating Opportunities or LineItems.
//
// Usage: Paste into Developer Console > Execute Anonymous Window > Execute
// ============================================================================

// ======================== CONFIGURATION ========================
Integer NUM_PRODUCTS    = 10;       // Number of products to create
Decimal BASE_UNIT_PRICE = 100.00;   // Base price; each product gets BASE + (index * 50)
String  NAME_PREFIX     = 'BulkTest_Product_';  // Prefix for easy identification/cleanup
// ===============================================================

// Step 1: Get the standard Pricebook
Pricebook2 stdPricebook;
try {
    stdPricebook = [SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
    if (!stdPricebook.IsActive) {
        stdPricebook.IsActive = true;
        update stdPricebook;
        System.debug('Activated standard Pricebook: ' + stdPricebook.Id);
    }
} catch (QueryException e) {
    System.debug(LoggingLevel.ERROR, 'No standard Pricebook found. This should not happen in any Salesforce org.');
    return;
}

System.debug('Using Standard Pricebook: ' + stdPricebook.Id);

// Step 2: Create Product2 records
List<Product2> products = new List<Product2>();
for (Integer i = 1; i <= NUM_PRODUCTS; i++) {
    products.add(new Product2(
        Name        = NAME_PREFIX + String.valueOf(i).leftPad(4, '0'),
        ProductCode = 'BT-' + String.valueOf(i).leftPad(4, '0'),
        Description = 'Bulk test product #' + i + ' created via Apex script',
        IsActive    = true
    ));
}

List<Database.SaveResult> productResults = Database.insert(products, false);

Integer productSuccessCount = 0;
Integer productFailCount = 0;
List<Product2> successfulProducts = new List<Product2>();

for (Integer i = 0; i < productResults.size(); i++) {
    if (productResults[i].isSuccess()) {
        productSuccessCount++;
        successfulProducts.add(products[i]);
    } else {
        productFailCount++;
        for (Database.Error err : productResults[i].getErrors()) {
            System.debug(LoggingLevel.ERROR,
                'Product insert failed [' + products[i].Name + ']: ' +
                err.getStatusCode() + ' - ' + err.getMessage());
        }
    }
}

System.debug('Products created: ' + productSuccessCount + ' success, ' + productFailCount + ' failed');

if (successfulProducts.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'No products were created. Aborting PricebookEntry creation.');
    return;
}

// Step 3: Create PricebookEntry records for standard Pricebook
List<PricebookEntry> pricebookEntries = new List<PricebookEntry>();
for (Integer i = 0; i < successfulProducts.size(); i++) {
    pricebookEntries.add(new PricebookEntry(
        Pricebook2Id = stdPricebook.Id,
        Product2Id   = successfulProducts[i].Id,
        UnitPrice    = BASE_UNIT_PRICE + (i * 50),
        IsActive     = true
    ));
}

List<Database.SaveResult> pbeResults = Database.insert(pricebookEntries, false);

Integer pbeSuccessCount = 0;
Integer pbeFailCount = 0;

for (Integer i = 0; i < pbeResults.size(); i++) {
    if (pbeResults[i].isSuccess()) {
        pbeSuccessCount++;
    } else {
        pbeFailCount++;
        for (Database.Error err : pbeResults[i].getErrors()) {
            System.debug(LoggingLevel.ERROR,
                'PricebookEntry insert failed [Product: ' + successfulProducts[i].Name + ']: ' +
                err.getStatusCode() + ' - ' + err.getMessage());
        }
    }
}

System.debug('=== PRODUCT CREATION SUMMARY ===');
System.debug('Products:        ' + productSuccessCount + ' created, ' + productFailCount + ' failed');
System.debug('PricebookEntries: ' + pbeSuccessCount + ' created, ' + pbeFailCount + ' failed');
System.debug('Standard Pricebook ID: ' + stdPricebook.Id);
System.debug('================================');
