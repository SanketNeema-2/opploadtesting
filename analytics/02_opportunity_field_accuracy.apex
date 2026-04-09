/**
 * ============================================================
 * METRIC: Field-Level Accuracy Check — Opportunity
 * ============================================================
 *
 * Purpose:
 *   Export key fields for a sample of Opportunities from Salesforce.
 *   Compare field-by-field with Outreach and OpportunityManager
 *   to detect data corruption, truncation, or mapping errors.
 *
 * Formulas:
 *   For each field F and each record R present in both source and sink:
 *     mismatch(R, F) = 1  if sf.F != sink.F, else 0
 *     field_accuracy_pct(F) = (1 - SUM(mismatch) / total_compared) * 100
 *
 * Field Mapping (Salesforce -> Outreach -> OpportunityManager):
 *   Id                   -> custom_id           -> external_id
 *   Name                 -> name                -> name
 *   Amount               -> amount_precise      -> amount_precise
 *   StageName            -> (via stage_id)       -> stage_name
 *   CloseDate            -> close_date           -> close_date
 *   OwnerId              -> owner_id             -> owner_id
 *   Probability          -> probability          -> probability
 *   ForecastCategoryName -> forecast_category    -> forecast_category
 *   LeadSource           -> lead_source          -> lead_source
 *   NextStep             -> next_step            -> next_step
 *   Type                 -> opportunity_type     -> opportunity_type
 *   IsClosed             -> (via stage)           -> is_closed
 *   IsWon                -> (via stage)           -> is_won
 *   CurrencyIsoCode      -> currency_type        -> currency_type
 *   CreatedDate          -> external_created_at  -> external_created_at
 *   LastModifiedDate     -> updated_at           -> external_updated_at
 *   AccountId            -> account_id           -> account_id
 *   RecordType.Name      -> record_type          -> record_type
 *   Description          -> description          -> description
 *   IsDeleted            -> trashed_at NOT NULL  -> is_deleted
 *
 * Companion Queries:
 *
 *   -- Outreach (MySQL) — use the SF IDs from output:
 *   SELECT id, custom_id, name, amount_precise, close_date, owner_id,
 *          probability, forecast_category, lead_source, next_step,
 *          opportunity_type, currency_type, external_created_at,
 *          updated_at AS external_updated_at, account_id, record_type,
 *          CASE WHEN trashed_at IS NOT NULL THEN 1 ELSE 0 END AS is_deleted
 *   FROM opportunities
 *   WHERE custom_id IN ('<sf_id_1>', '<sf_id_2>', ...);
 *
 *   -- OpportunityManager (Postgres) — use the SF IDs from output:
 *   SELECT id, external_id, name, amount_precise, stage_name, close_date,
 *          owner_id, probability, forecast_category, lead_source, next_step,
 *          opportunity_type, is_closed, is_won, currency_type,
 *          external_created_at, external_updated_at, account_id,
 *          record_type, is_deleted
 *   FROM opportunity
 *   WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...)
 *   ORDER BY external_id;
 * ============================================================
 */

// Configuration: adjust sample size as needed
Integer sampleSize = 200;

List<Opportunity> opps = [
    SELECT Id, Name, Amount, StageName, CloseDate, OwnerId,
           Probability, ForecastCategoryName, LeadSource, NextStep,
           Type, IsClosed, IsWon, IsDeleted, CurrencyIsoCode,
           CreatedDate, LastModifiedDate, AccountId, Description,
           RecordType.Name
    FROM Opportunity
    WHERE IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT :sampleSize
];

System.debug('================================================================');
System.debug('  METRIC: OPPORTUNITY FIELD-LEVEL ACCURACY');
System.debug('  Sample size: ' + opps.size() + ' records');
System.debug('================================================================');
System.debug('');

// CSV Header
System.debug('SF_Id|Name|Amount|StageName|CloseDate|OwnerId|Probability|ForecastCategory|LeadSource|NextStep|Type|IsClosed|IsWon|CurrencyIsoCode|CreatedDate|LastModifiedDate|AccountId|RecordType|Description');

// CSV Data
for (Opportunity o : opps) {
    String descr = '';
    if (o.Description != null) {
        descr = o.Description.left(200);
    }
    String recType = '';
    if (o.RecordType != null) {
        recType = o.RecordType.Name;
    }

    String line =
        o.Id + '|' +
        (o.Name != null ? o.Name : '') + '|' +
        (o.Amount != null ? String.valueOf(o.Amount) : '') + '|' +
        (o.StageName != null ? o.StageName : '') + '|' +
        (o.CloseDate != null ? String.valueOf(o.CloseDate) : '') + '|' +
        (o.OwnerId != null ? String.valueOf(o.OwnerId) : '') + '|' +
        (o.Probability != null ? String.valueOf(o.Probability) : '') + '|' +
        (o.ForecastCategoryName != null ? o.ForecastCategoryName : '') + '|' +
        (o.LeadSource != null ? o.LeadSource : '') + '|' +
        (o.NextStep != null ? o.NextStep : '') + '|' +
        (o.Type != null ? o.Type : '') + '|' +
        o.IsClosed + '|' +
        o.IsWon + '|' +
        (o.CurrencyIsoCode != null ? o.CurrencyIsoCode : '') + '|' +
        o.CreatedDate + '|' +
        o.LastModifiedDate + '|' +
        (o.AccountId != null ? String.valueOf(o.AccountId) : '') + '|' +
        recType + '|' +
        descr;
    System.debug(line);
}

// --- Collect IDs for companion queries ---
System.debug('');
System.debug('--- IDs for companion SQL (copy-paste into WHERE IN clause) ---');
List<String> idBatch = new List<String>();
for (Integer i = 0; i < opps.size(); i++) {
    idBatch.add('\'' + opps[i].Id + '\'');
    if (Math.mod(i + 1, 50) == 0 || i == opps.size() - 1) {
        System.debug(String.join(idBatch, ','));
        idBatch.clear();
    }
}
