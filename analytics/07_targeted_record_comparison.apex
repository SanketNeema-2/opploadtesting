/**
 * ============================================================
 * METRIC: Targeted Record Comparison (Data Accuracy)
 * ============================================================
 *
 * Purpose:
 *   Look up specific Opportunity/LineItem records by Salesforce ID
 *   and export all fields for 1:1 comparison with Outreach and
 *   OpportunityManager. Use this for debugging specific mismatches
 *   found by other scripts.
 *
 * How to use:
 *   1. Replace the IDs in targetOppIds / targetOliIds below
 *   2. Run in Developer Console
 *   3. Run companion SQL with same IDs on Outreach + OpportunityManager
 *   4. Compare field-by-field
 *
 * Companion Queries:
 *
 *   -- Outreach (MySQL) — Opportunity:
 *   SELECT id, custom_id, name, amount_precise, close_date, owner_id,
 *          probability, forecast_category, lead_source, next_step,
 *          opportunity_type, currency_type, external_created_at,
 *          updated_at, account_id, record_type, description,
 *          trashed_at, state
 *   FROM opportunities
 *   WHERE custom_id IN ('<sf_id_1>', ...);
 *
 *   -- OpportunityManager (Postgres) — Opportunity:
 *   SELECT id, external_id, name, amount_precise, stage_name,
 *          close_date, owner_id, probability, forecast_category,
 *          lead_source, next_step, opportunity_type, is_closed,
 *          is_won, currency_type, external_created_at,
 *          external_updated_at, updated_at, account_id,
 *          record_type, description, is_deleted, state
 *   FROM opportunity
 *   WHERE external_id IN ('<sf_id_1>', ...);
 *
 *   -- Outreach (MySQL) — LineItem:
 *   SELECT id, external_id, name, opportunity_id, unit_price,
 *          quantity, total_price, discount, line_description,
 *          external_product_id, close_date, currency_type,
 *          deleted, created_at, updated_at
 *   FROM opportunity_line_items
 *   WHERE external_id IN ('<sf_id_1>', ...);
 *
 *   -- OpportunityManager (Postgres) — LineItem:
 *   SELECT id, external_id, name, opportunity_id, unit_price,
 *          quantity, total_price, discount, line_description,
 *          external_product_id, close_date, currency_type,
 *          is_deleted, created_at, external_updated_at, updated_at
 *   FROM opportunity_line_item
 *   WHERE external_id IN ('<sf_id_1>', ...);
 * ============================================================
 */

// ========== CONFIGURATION ==========
// Replace with actual Salesforce IDs you want to compare
Set<Id> targetOppIds = new Set<Id>{
    // '006XXXXXXXXXXXXXXX',
    // '006YYYYYYYYYYYYYYY'
};

Set<Id> targetOliIds = new Set<Id>{
    // '00kXXXXXXXXXXXXXXX',
    // '00kYYYYYYYYYYYYYYY'
};
// ====================================

// --- Opportunity comparison ---
if (!targetOppIds.isEmpty()) {
    List<Opportunity> opps = [
        SELECT Id, Name, Amount, StageName, CloseDate, OwnerId,
               Probability, ForecastCategoryName, LeadSource, NextStep,
               Type, IsClosed, IsWon, IsDeleted, CurrencyIsoCode,
               CreatedDate, LastModifiedDate, AccountId, Description,
               RecordType.Name, LossReason
        FROM Opportunity
        WHERE Id IN :targetOppIds
        ALL ROWS
    ];

    System.debug('================================================================');
    System.debug('  TARGETED OPPORTUNITY COMPARISON (' + opps.size() + ' records)');
    System.debug('================================================================');

    for (Opportunity o : opps) {
        System.debug('');
        System.debug('--- ' + o.Id + ' ---');
        System.debug('  Name:               ' + o.Name);
        System.debug('  Amount:             ' + o.Amount);
        System.debug('  StageName:          ' + o.StageName);
        System.debug('  CloseDate:          ' + o.CloseDate);
        System.debug('  OwnerId:            ' + o.OwnerId);
        System.debug('  Probability:        ' + o.Probability);
        System.debug('  ForecastCategory:   ' + o.ForecastCategoryName);
        System.debug('  LeadSource:         ' + o.LeadSource);
        System.debug('  NextStep:           ' + o.NextStep);
        System.debug('  Type:               ' + o.Type);
        System.debug('  IsClosed:           ' + o.IsClosed);
        System.debug('  IsWon:              ' + o.IsWon);
        System.debug('  IsDeleted:          ' + o.IsDeleted);
        System.debug('  CurrencyIsoCode:    ' + o.CurrencyIsoCode);
        System.debug('  CreatedDate:        ' + o.CreatedDate);
        System.debug('  LastModifiedDate:   ' + o.LastModifiedDate);
        System.debug('  AccountId:          ' + o.AccountId);
        System.debug('  RecordType:         ' + (o.RecordType != null ? o.RecordType.Name : 'null'));
        System.debug('  Description:        ' + (o.Description != null ? o.Description.left(200) : 'null'));
        System.debug('  LossReason:         ' + o.LossReason);
    }
} else {
    System.debug('No Opportunity IDs configured. Set targetOppIds above.');
}

// --- LineItem comparison ---
if (!targetOliIds.isEmpty()) {
    List<OpportunityLineItem> olis = [
        SELECT Id, Name, OpportunityId, Opportunity.Name,
               UnitPrice, Quantity, TotalPrice, Discount,
               Description, Product2Id, Product2.Name,
               ServiceDate, IsDeleted,
               CreatedDate, LastModifiedDate
        FROM OpportunityLineItem
        WHERE Id IN :targetOliIds
        ALL ROWS
    ];

    System.debug('');
    System.debug('================================================================');
    System.debug('  TARGETED LINE ITEM COMPARISON (' + olis.size() + ' records)');
    System.debug('================================================================');

    for (OpportunityLineItem oli : olis) {
        System.debug('');
        System.debug('--- ' + oli.Id + ' ---');
        System.debug('  Name:               ' + oli.Name);
        System.debug('  OpportunityId:      ' + oli.OpportunityId);
        System.debug('  OppName:            ' + (oli.Opportunity != null ? oli.Opportunity.Name : 'null'));
        System.debug('  UnitPrice:          ' + oli.UnitPrice);
        System.debug('  Quantity:           ' + oli.Quantity);
        System.debug('  TotalPrice:         ' + oli.TotalPrice);
        System.debug('  Discount:           ' + oli.Discount);
        System.debug('  Description:        ' + (oli.Description != null ? oli.Description.left(200) : 'null'));
        System.debug('  Product2Id:         ' + oli.Product2Id);
        System.debug('  ProductName:        ' + (oli.Product2 != null ? oli.Product2.Name : 'null'));
        System.debug('  ServiceDate:        ' + oli.ServiceDate);
        System.debug('  IsDeleted:          ' + oli.IsDeleted);
        System.debug('  CreatedDate:        ' + oli.CreatedDate);
        System.debug('  LastModifiedDate:   ' + oli.LastModifiedDate);
    }
} else {
    System.debug('No LineItem IDs configured. Set targetOliIds above.');
}
