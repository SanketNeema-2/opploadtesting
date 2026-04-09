/**
 * ============================================================
 * METRIC: Field-Level Accuracy Check — OpportunityLineItem
 * ============================================================
 *
 * Purpose:
 *   Export key fields for a sample of OpportunityLineItems from Salesforce.
 *   Compare field-by-field with Outreach and OpportunityManager.
 *
 * Formulas:
 *   mismatch(R, F) = 1  if sf.F != sink.F, else 0
 *   field_accuracy_pct(F) = (1 - SUM(mismatch) / total_compared) * 100
 *
 * Field Mapping (Salesforce -> Outreach -> OpportunityManager):
 *   Id                -> external_id          -> external_id
 *   Name              -> name                 -> name
 *   OpportunityId     -> opportunity_id (FK)  -> opportunity_id (resolved via DSNG mapping)
 *   UnitPrice         -> unit_price           -> unit_price
 *   Quantity          -> quantity              -> quantity
 *   TotalPrice        -> total_price           -> total_price
 *   Discount          -> discount              -> discount
 *   Description       -> line_description      -> line_description
 *   Product2Id        -> external_product_id   -> external_product_id
 *   ServiceDate       -> close_date            -> close_date
 *   CurrencyIsoCode   -> currency_type         -> currency_type
 *   IsDeleted         -> deleted               -> is_deleted
 *   CreatedDate       -> created_at            -> created_at
 *   LastModifiedDate  -> updated_at            -> external_updated_at
 *
 * Companion Queries:
 *
 *   -- Outreach (MySQL):
 *   SELECT id, external_id, name, opportunity_id, unit_price, quantity,
 *          total_price, discount, line_description, external_product_id,
 *          close_date, currency_type, deleted AS is_deleted,
 *          created_at, updated_at AS external_updated_at
 *   FROM opportunity_line_items
 *   WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...);
 *
 *   -- OpportunityManager (Postgres):
 *   SELECT id, external_id, name, opportunity_id, unit_price, quantity,
 *          total_price, discount, line_description, external_product_id,
 *          close_date, currency_type, is_deleted,
 *          created_at, external_updated_at
 *   FROM opportunity_line_item
 *   WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...)
 *   ORDER BY external_id;
 * ============================================================
 */

Integer sampleSize = 200;

List<OpportunityLineItem> olis = [
    SELECT Id, Name, OpportunityId, Opportunity.Name,
           UnitPrice, Quantity, TotalPrice, Discount,
           Description, Product2Id, Product2.Name,
           ServiceDate, IsDeleted,
           CreatedDate, LastModifiedDate
    FROM OpportunityLineItem
    WHERE IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT :sampleSize
];

System.debug('================================================================');
System.debug('  METRIC: LINE ITEM FIELD-LEVEL ACCURACY');
System.debug('  Sample size: ' + olis.size() + ' records');
System.debug('================================================================');
System.debug('');

// CSV Header
System.debug('SF_Id|Name|OpportunityId|OppName|UnitPrice|Quantity|TotalPrice|Discount|Description|Product2Id|ProductName|ServiceDate|CreatedDate|LastModifiedDate');

for (OpportunityLineItem oli : olis) {
    String desc = '';
    if (oli.Description != null) {
        desc = oli.Description.left(200);
    }
    String prodName = '';
    if (oli.Product2 != null) {
        prodName = oli.Product2.Name;
    }

    String line =
        oli.Id + '|' +
        (oli.Name != null ? oli.Name : '') + '|' +
        (oli.OpportunityId != null ? String.valueOf(oli.OpportunityId) : '') + '|' +
        (oli.Opportunity != null ? oli.Opportunity.Name : '') + '|' +
        (oli.UnitPrice != null ? String.valueOf(oli.UnitPrice) : '') + '|' +
        (oli.Quantity != null ? String.valueOf(oli.Quantity) : '') + '|' +
        (oli.TotalPrice != null ? String.valueOf(oli.TotalPrice) : '') + '|' +
        (oli.Discount != null ? String.valueOf(oli.Discount) : '') + '|' +
        desc + '|' +
        (oli.Product2Id != null ? String.valueOf(oli.Product2Id) : '') + '|' +
        prodName + '|' +
        (oli.ServiceDate != null ? String.valueOf(oli.ServiceDate) : '') + '|' +
        oli.CreatedDate + '|' +
        oli.LastModifiedDate;
    System.debug(line);
}

// --- IDs for companion queries ---
System.debug('');
System.debug('--- IDs for companion SQL ---');
List<String> idBatch = new List<String>();
for (Integer i = 0; i < olis.size(); i++) {
    idBatch.add('\'' + olis[i].Id + '\'');
    if (Math.mod(i + 1, 50) == 0 || i == olis.size() - 1) {
        System.debug(String.join(idBatch, ','));
        idBatch.clear();
    }
}
