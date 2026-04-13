# Salesforce <-> Outreach Sync Performance & Accuracy Metrics Documentation

> **Scope:** Opportunity and OpportunityLineItem sync from Salesforce through the Outreach pipeline  
> **Pipeline:** Salesforce (DSNG) -> Flagship (MySQL) -> OpportunityManager (Postgres) + FRI (SingleStore)  
> **Last Updated:** 2026-04-10

---

## Table of Contents

1. [Overview & Data Flow](#1-overview--data-flow)
2. [Data Accuracy Metrics](#2-data-accuracy-metrics)
3. [Performance Metrics](#3-performance-metrics)
4. [Load & Scalability Metrics](#4-load--scalability-metrics)
5. [Reliability Metrics](#5-reliability-metrics)
6. [Summary & Executive Report](#6-summary--executive-report)
7. [Reporting & Visualization Guidance](#7-reporting--visualization-guidance)

---

## 1. Overview & Data Flow

### 1.1 Architecture

```
+-------------+       +-------------------+       +--------------------+       +-----------------+
|  Salesforce  | ----> |     Flagship      | ----> | OpportunityManager | ----> |      FRI        |
|   (Source)   |       |   (APIv2/MySQL)   |       |  (Postgres/CDC)    |       |  (SingleStore)  |
|              |       |   System of       |       |  Smartstore ingest |       |  Analytics &    |
|  DSNG Poller |       |   Record          |       |  via Universal     |       |  Forecasting    |
|  Lightning   |       |                   |       |  Consumer          |       |                 |
+-------------+       +-------------------+       +--------------------+       +-----------------+
                                |                                                      ^
                                |              +------------+                          |
                                +-----------> |  BigQuery   | --> GCS --> Geyser ------+
                                              |  (ETL/DW)   |
                                              +------------+
```

**Data flow paths:**

| Path | Mechanism | Latency Profile |
|---|---|---|
| SF -> Flagship | DSNG poller, Lightning, sync workflows | Near real-time (seconds to minutes) |
| Flagship -> OM | Clerk CDC / Polaroid events via Universal Consumer | Event-driven (seconds) |
| Flagship -> BigQuery -> GCS -> FRI | ETL batch export, Geyser load | Batch (minutes to hours) |
| OM -> FRI (optional) | Direct upsert via FRI/Geyser endpoint | Near real-time |

### 1.2 Key Timestamp Semantics

| Timestamp Column | Meaning | Present In |
|---|---|---|
| `LastModifiedDate` (SF) | When the record was last changed in Salesforce | Salesforce only (SOQL) |
| `external_updated_at` | Copy of SF `LastModifiedDate` — the moment the event originated in Salesforce | Flagship, OM, FRI |
| `updated_at` | When the downstream system persisted/processed the record | Flagship, OM, FRI |
| `created_at` | When the record was first created in the downstream system | Flagship, OM, FRI |
| `external_created_at` | Copy of SF `CreatedDate` | Flagship, OM (opportunity only) |

**Sync lag** is always measured as: `updated_at - external_updated_at` at each hop.

### 1.3 Table & Column Mapping

#### Opportunity

| Salesforce Field | Flagship (MySQL) | OM (Postgres) | FRI (SingleStore) |
|---|---|---|---|
| `Id` | `external_id` | `external_id` | `external_id` |
| `Name` | `name` | `name` | `name` |
| `Amount` | `amount_precise` | `amount_precise` | `amount_precise` |
| `StageName` | `stage_name` | `stage_name` | `stage_name` |
| `CloseDate` | `close_date` | `close_date` | `close_date` |
| `OwnerId` | `owner_id` | `owner_id` | `owner_id` |
| `Probability` | `probability` | `probability` | `probability` |
| `ForecastCategoryName` | `forecast_category` | `forecast_category` | `forecast_category` |
| `LeadSource` | `lead_source` | `lead_source` | `lead_source` |
| `NextStep` | `next_step` | `next_step` | `next_step` |
| `Type` | `opportunity_type` | `opportunity_type` | `opportunity_type` |
| `IsClosed` | `is_closed` | `is_closed` | `is_closed` |
| `IsWon` | `is_won` | `is_won` | `is_won` |
| `CurrencyIsoCode` | `currency_type` | `currency_type` | `currency_type` |
| `CreatedDate` | `external_created_at` | `external_created_at` | `external_created_at` |
| `LastModifiedDate` | `external_updated_at` | `external_updated_at` | `external_updated_at` |
| `AccountId` | `account_id` | `account_id` | `account_id` |
| `RecordType.Name` | `record_type` | `record_type` | `record_type` |
| `Description` | `description` | `description` | `description` |
| `IsDeleted` | `is_deleted` | `is_deleted` | `is_deleted` |
| `LossReason` | `lost_reason` | `lost_reason` | `lost_reason` |

#### OpportunityLineItem

| Salesforce Field | Flagship (MySQL) | OM (Postgres) | FRI (SingleStore) |
|---|---|---|---|
| `Id` | `external_id` | `external_id` | `external_id` |
| `Name` | `name` | `name` | `name` |
| `OpportunityId` | `opportunity_id` (FK) | `opportunity_id` (FK) | `opportunity_id` (FK) |
| `UnitPrice` | `unit_price` | `unit_price` | `unit_price` |
| `Quantity` | `quantity` | `quantity` | `quantity` |
| `TotalPrice` | `total_price` | `total_price` | `total_price` |
| `Discount` | `discount` | `discount` | `discount` |
| `Description` | `line_description` | `line_description` | `line_description` |
| `Product2Id` | `external_product_id` | `external_product_id` | `external_product_id` |
| `ServiceDate` | `close_date` | `close_date` | `close_date` |
| `CurrencyIsoCode` | `currency_type` | `currency_type` | `currency_type` |
| `IsDeleted` | `is_deleted` | `is_deleted` | `is_deleted` |
| `CreatedDate` | `created_at` | `created_at` | `created_at` |
| `LastModifiedDate` | `external_updated_at` | `external_updated_at` | `external_updated_at` |

### 1.4 Join Keys

```
SF Opportunity.Id  =  Flagship.opportunity.external_id
                   =  OM.opportunity.external_id
                   =  FRI.opportunity.external_id

SF OpportunityLineItem.Id  =  Flagship.opportunity_line_item.external_id
                            =  OM.opportunity_line_item.external_id
                            =  FRI.opportunity_line_item.external_id
```

### 1.5 Prerequisites

All queries below use parameterized time windows. Set these before running:

**Flagship (MySQL):**
```sql
SET @from_ts = '2026-04-07 00:00:00';
SET @to_ts   = '2026-04-08 23:59:59';
```

**OM (Postgres):**
```
Replace :from_ts and :to_ts with your time window values.
```

**FRI (SingleStore):**
```
Replace :from_ts and :to_ts with your time window values.
```

---

## 2. Data Accuracy Metrics

### 2.1 Record Count Parity

**Goal:** Verify that the number of records in each downstream system matches Salesforce.

**Formula:**
```
count_delta  = sf_count - sink_count
accuracy_pct = (1 - ABS(count_delta) / sf_count) * 100
missing      = sf_count - sink_count   (if positive)
extra        = sink_count - sf_count   (if positive)
```

#### 2.1.1 Salesforce (Source of Truth)

```sql
-- Run in Salesforce Developer Console (Execute Anonymous)

-- Opportunity counts
Integer oppActive  = [SELECT COUNT() FROM Opportunity WHERE IsDeleted = false];
Integer oppDeleted = [SELECT COUNT() FROM Opportunity WHERE IsDeleted = true ALL ROWS];
Integer oppTotal   = oppActive + oppDeleted;

-- OpportunityLineItem counts
Integer oliActive  = [SELECT COUNT() FROM OpportunityLineItem WHERE IsDeleted = false];
Integer oliDeleted = [SELECT COUNT() FROM OpportunityLineItem WHERE IsDeleted = true ALL ROWS];
Integer oliTotal   = oliActive + oliDeleted;

System.debug('Opportunity  — active: ' + oppActive + ', deleted: ' + oppDeleted + ', total: ' + oppTotal);
System.debug('LineItem     — active: ' + oliActive + ', deleted: ' + oliDeleted + ', total: ' + oliTotal);
```

#### 2.1.2 Flagship (MySQL)

```sql
-- Opportunity
SELECT 'opportunity' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN is_deleted = false THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN is_deleted = true  THEN 1 ELSE 0 END) AS deleted
FROM opportunity;

-- OpportunityLineItem
SELECT 'opportunity_line_item' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN is_deleted = false THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN is_deleted = true  THEN 1 ELSE 0 END) AS deleted
FROM opportunity_line_item;
```

#### 2.1.3 OpportunityManager (Postgres)

```sql
-- Opportunity
SELECT 'opportunity' AS entity,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE is_deleted = false) AS active,
       COUNT(*) FILTER (WHERE is_deleted = true)  AS deleted
FROM opportunity;

-- OpportunityLineItem
SELECT 'opportunity_line_item' AS entity,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE is_deleted = false) AS active,
       COUNT(*) FILTER (WHERE is_deleted = true)  AS deleted
FROM opportunity_line_item;
```

#### 2.1.4 FRI (SingleStore)

```sql
-- Opportunity
SELECT 'opportunity' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN is_deleted = false THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN is_deleted = true  THEN 1 ELSE 0 END) AS deleted
FROM opportunity;

-- OpportunityLineItem
SELECT 'opportunity_line_item' AS entity,
       COUNT(*) AS total,
       SUM(CASE WHEN is_deleted = false THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN is_deleted = true  THEN 1 ELSE 0 END) AS deleted
FROM opportunity_line_item;
```

#### 2.1.5 Count Parity — Time-Windowed

Compare records modified within a specific time window across all systems.

**Salesforce:**
```sql
-- Set fromTs / toTs in Apex
Integer oppInWindow = [SELECT COUNT() FROM Opportunity
                       WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs];
Integer oliInWindow = [SELECT COUNT() FROM OpportunityLineItem
                       WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs];
```

**Flagship (MySQL):**
```sql
SELECT 'opportunity' AS entity, COUNT(*) AS modified_in_window
FROM opportunity
WHERE updated_at BETWEEN @from_ts AND @to_ts;

SELECT 'opportunity_line_item' AS entity, COUNT(*) AS modified_in_window
FROM opportunity_line_item
WHERE updated_at BETWEEN @from_ts AND @to_ts;
```

**OM (Postgres):**
```sql
SELECT 'opportunity' AS entity, COUNT(*) AS modified_in_window
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts;

SELECT 'opportunity_line_item' AS entity, COUNT(*) AS modified_in_window
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

**FRI (SingleStore):**
```sql
SELECT 'opportunity' AS entity, COUNT(*) AS modified_in_window
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts;

SELECT 'opportunity_line_item' AS entity, COUNT(*) AS modified_in_window
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

#### 2.1.6 Parity Computation Template

Once you have counts from all systems, compute parity:

```
| Entity              | SF Count | Flagship | OM    | FRI   |
|---------------------|----------|----------|-------|-------|
| Opportunity (active)| X        | Y        | Z     | W     |
| Opportunity (del)   | X        | Y        | Z     | W     |
| LineItem (active)   | X        | Y        | Z     | W     |
| LineItem (del)      | X        | Y        | Z     | W     |

Flagship accuracy_pct = (1 - ABS(SF - Flagship) / SF) * 100
OM accuracy_pct       = (1 - ABS(SF - OM) / SF) * 100
FRI accuracy_pct      = (1 - ABS(SF - FRI) / SF) * 100
```

---

### 2.2 Field-Level Accuracy

**Goal:** Compare field values for a sample of records across SF and each downstream sink to detect data corruption, truncation, or mapping errors.

**Formula:**
```
For each field F and each record R present in both source and sink:
  mismatch(R, F) = 1  if sf.F != sink.F, else 0
  field_accuracy_pct(F) = (1 - SUM(mismatch) / total_compared) * 100
```

#### 2.2.1 Salesforce — Export Opportunity Sample

```sql
-- Run in Developer Console. Exports 200 most recently modified Opportunities.
-- Output is pipe-delimited for easy parsing.

List<Opportunity> opps = [
    SELECT Id, Name, Amount, StageName, CloseDate, OwnerId,
           Probability, ForecastCategoryName, LeadSource, NextStep,
           Type, IsClosed, IsWon, IsDeleted, CurrencyIsoCode,
           CreatedDate, LastModifiedDate, AccountId, Description,
           RecordType.Name
    FROM Opportunity
    WHERE IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT 200
];

System.debug('SF_Id|Name|Amount|StageName|CloseDate|OwnerId|Probability|ForecastCategory|LeadSource|NextStep|Type|IsClosed|IsWon|CurrencyIsoCode|CreatedDate|LastModifiedDate|AccountId|RecordType|Description');

for (Opportunity o : opps) {
    System.debug(
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
        o.IsClosed + '|' + o.IsWon + '|' +
        (o.CurrencyIsoCode != null ? o.CurrencyIsoCode : '') + '|' +
        o.CreatedDate + '|' + o.LastModifiedDate + '|' +
        (o.AccountId != null ? String.valueOf(o.AccountId) : '') + '|' +
        (o.RecordType != null ? o.RecordType.Name : '') + '|' +
        (o.Description != null ? o.Description.left(200) : '')
    );
}
```

#### 2.2.2 Salesforce — Export LineItem Sample

```sql
List<OpportunityLineItem> olis = [
    SELECT Id, Name, OpportunityId, UnitPrice, Quantity, TotalPrice,
           Discount, Description, Product2Id, ServiceDate,
           IsDeleted, CreatedDate, LastModifiedDate
    FROM OpportunityLineItem
    WHERE IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT 200
];

System.debug('SF_Id|Name|OpportunityId|UnitPrice|Quantity|TotalPrice|Discount|Description|Product2Id|ServiceDate|CreatedDate|LastModifiedDate');

for (OpportunityLineItem oli : olis) {
    System.debug(
        oli.Id + '|' +
        (oli.Name != null ? oli.Name : '') + '|' +
        (oli.OpportunityId != null ? String.valueOf(oli.OpportunityId) : '') + '|' +
        (oli.UnitPrice != null ? String.valueOf(oli.UnitPrice) : '') + '|' +
        (oli.Quantity != null ? String.valueOf(oli.Quantity) : '') + '|' +
        (oli.TotalPrice != null ? String.valueOf(oli.TotalPrice) : '') + '|' +
        (oli.Discount != null ? String.valueOf(oli.Discount) : '') + '|' +
        (oli.Description != null ? oli.Description.left(200) : '') + '|' +
        (oli.Product2Id != null ? String.valueOf(oli.Product2Id) : '') + '|' +
        (oli.ServiceDate != null ? String.valueOf(oli.ServiceDate) : '') + '|' +
        oli.CreatedDate + '|' + oli.LastModifiedDate
    );
}
```

#### 2.2.3 Flagship (MySQL) — Retrieve Same Records

Use the SF IDs from the Apex output above and paste them into the `IN` clause.

```sql
-- Opportunity field comparison
SELECT
    external_id         AS sf_id,
    name,
    amount_precise,
    stage_name,
    close_date,
    owner_id,
    probability,
    forecast_category,
    lead_source,
    next_step,
    opportunity_type,
    is_closed,
    is_won,
    currency_type,
    external_created_at,
    external_updated_at,
    account_id,
    record_type,
    description,
    is_deleted,
    updated_at          AS sink_updated_at
FROM opportunity
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...);

-- LineItem field comparison
SELECT
    external_id         AS sf_id,
    name,
    opportunity_id,
    unit_price,
    quantity,
    total_price,
    discount,
    line_description,
    external_product_id,
    close_date,
    currency_type,
    is_deleted,
    created_at,
    external_updated_at,
    updated_at          AS sink_updated_at
FROM opportunity_line_item
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...);
```

#### 2.2.4 OpportunityManager (Postgres) — Retrieve Same Records

```sql
-- Opportunity field comparison
SELECT
    external_id         AS sf_id,
    name,
    amount_precise,
    stage_name,
    close_date,
    owner_id,
    probability,
    forecast_category,
    lead_source,
    next_step,
    opportunity_type,
    is_closed,
    is_won,
    currency_type,
    external_created_at,
    external_updated_at,
    account_id,
    record_type,
    description,
    is_deleted,
    updated_at          AS sink_updated_at
FROM opportunity
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...)
ORDER BY external_id;

-- LineItem field comparison
SELECT
    external_id         AS sf_id,
    name,
    opportunity_id,
    unit_price,
    quantity,
    total_price,
    discount,
    line_description,
    external_product_id,
    close_date,
    currency_type,
    is_deleted,
    created_at,
    external_updated_at,
    updated_at          AS sink_updated_at
FROM opportunity_line_item
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...)
ORDER BY external_id;
```

#### 2.2.5 FRI (SingleStore) — Retrieve Same Records

```sql
-- Opportunity field comparison
SELECT
    external_id         AS sf_id,
    name,
    amount_precise,
    stage_name,
    close_date,
    owner_id,
    probability,
    forecast_category,
    lead_source,
    next_step,
    opportunity_type,
    is_closed,
    is_won,
    currency_type,
    external_created_at,
    external_updated_at,
    account_id,
    record_type,
    description,
    is_deleted,
    updated_at          AS sink_updated_at
FROM opportunity
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...);

-- LineItem field comparison
SELECT
    external_id         AS sf_id,
    name,
    opportunity_id,
    unit_price,
    quantity,
    total_price,
    discount,
    line_description,
    external_product_id,
    close_date,
    currency_type,
    is_deleted,
    created_at,
    external_updated_at,
    updated_at          AS sink_updated_at
FROM opportunity_line_item
WHERE external_id IN ('<sf_id_1>', '<sf_id_2>', ...);
```

#### 2.2.6 How to Compute Field Accuracy

After exporting data from SF and each sink:

1. Match records by `SF.Id = sink.external_id`
2. For each matched pair, compare each field
3. Count mismatches per field
4. Compute: `field_accuracy_pct(F) = (1 - mismatches(F) / total_compared) * 100`

**Result template:**

```
| Field              | SF vs Flagship | SF vs OM | SF vs FRI |
|--------------------|----------------|----------|-----------|
| name               | 100.0%         | 100.0%   | 100.0%    |
| amount_precise     | 99.95%         | 99.95%   | 99.90%    |
| stage_name         | 100.0%         | 100.0%   | 100.0%    |
| close_date         | 100.0%         | 99.98%   | 99.98%    |
| probability        | 100.0%         | 100.0%   | 100.0%    |
| forecast_category  | 100.0%         | 100.0%   | 100.0%    |
| is_deleted         | 100.0%         | 100.0%   | 100.0%    |
| ...                | ...            | ...      | ...       |
```

---

### 2.3 Missing Records Detection

**Goal:** Find records that exist in Salesforce but are absent from a downstream sink.

**Formula:**
```
missing_count    = sf_count - matched_count
missing_rate_pct = (missing_count / sf_count) * 100
```

#### 2.3.1 Salesforce — Export All IDs

```sql
-- Opportunity IDs (up to SOQL governor limit of 50,000)
List<Opportunity> allOpps = [
    SELECT Id FROM Opportunity
    WHERE IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT 50000
];

-- OpportunityLineItem IDs
List<OpportunityLineItem> allOlis = [
    SELECT Id FROM OpportunityLineItem
    WHERE IsDeleted = false
    ORDER BY LastModifiedDate DESC
    LIMIT 50000
];

-- Print IDs in batches of 200 for SQL IN clause
-- (see Script 05 for full implementation)
```

#### 2.3.2 Flagship (MySQL) — Find Missing Records

```sql
-- Missing Opportunities: SF IDs not found in Flagship
-- Paste exported IDs into the subquery
SELECT sf_id
FROM (
    SELECT '<sf_id_1>' AS sf_id UNION ALL
    SELECT '<sf_id_2>' UNION ALL
    SELECT '<sf_id_3>'
    -- ... paste all IDs
) t
LEFT JOIN opportunity o ON o.external_id = t.sf_id
WHERE o.id IS NULL;

-- Missing LineItems
SELECT sf_id
FROM (
    SELECT '<sf_id_1>' AS sf_id UNION ALL
    SELECT '<sf_id_2>'
    -- ... paste all IDs
) t
LEFT JOIN opportunity_line_item oli ON oli.external_id = t.sf_id
WHERE oli.id IS NULL;
```

#### 2.3.3 OpportunityManager (Postgres) — Find Missing Records

```sql
-- Missing Opportunities (using EXCEPT — cleaner for large ID lists)
SELECT unnest(ARRAY['<sf_id_1>','<sf_id_2>','<sf_id_3>']) AS sf_id
EXCEPT
SELECT external_id FROM opportunity WHERE external_id IS NOT NULL;

-- Missing LineItems
SELECT unnest(ARRAY['<sf_id_1>','<sf_id_2>','<sf_id_3>']) AS sf_id
EXCEPT
SELECT external_id FROM opportunity_line_item WHERE external_id IS NOT NULL;
```

#### 2.3.4 FRI (SingleStore) — Find Missing Records

```sql
-- Missing Opportunities
SELECT sf.sf_id
FROM (
    SELECT '<sf_id_1>' AS sf_id UNION ALL
    SELECT '<sf_id_2>' UNION ALL
    SELECT '<sf_id_3>'
) sf
LEFT JOIN opportunity o ON o.external_id = sf.sf_id
WHERE o.external_id IS NULL;

-- Missing LineItems
SELECT sf.sf_id
FROM (
    SELECT '<sf_id_1>' AS sf_id UNION ALL
    SELECT '<sf_id_2>'
) sf
LEFT JOIN opportunity_line_item oli ON oli.external_id = sf.sf_id
WHERE oli.external_id IS NULL;
```

---

### 2.4 Duplicate Detection

**Goal:** Ensure no `external_id` (SF Id) appears more than once per entity in any sink. Duplicates indicate a sync bug.

**Expected result:** Zero rows. Any row returned is a problem.

#### Flagship (MySQL)

```sql
SELECT external_id, COUNT(*) AS dupes
FROM opportunity
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;

SELECT external_id, COUNT(*) AS dupes
FROM opportunity_line_item
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;
```

#### OpportunityManager (Postgres)

```sql
SELECT external_id, COUNT(*) AS dupes
FROM opportunity
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;

SELECT external_id, COUNT(*) AS dupes
FROM opportunity_line_item
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;
```

#### FRI (SingleStore)

```sql
SELECT external_id, COUNT(*) AS dupes
FROM opportunity
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;

SELECT external_id, COUNT(*) AS dupes
FROM opportunity_line_item
WHERE external_id IS NOT NULL AND is_deleted = false
GROUP BY external_id
HAVING COUNT(*) > 1;
```

---

### 2.5 Soft-Delete Consistency

**Goal:** Verify that the `is_deleted` / `IsDeleted` flag is consistent between Salesforce and each downstream sink.

**Two failure modes:**
- **Ghost records:** Deleted in SF but still active in sink
- **Premature deletes:** Active in SF but marked deleted in sink

#### 2.5.1 Salesforce — Export Deleted Record IDs

```sql
-- Recently deleted Opportunities (requires ALL ROWS to see soft-deleted records)
List<Opportunity> deletedOpps = [
    SELECT Id, LastModifiedDate
    FROM Opportunity
    WHERE IsDeleted = true
      AND LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
    ALL ROWS
    LIMIT 50000
];

System.debug('Deleted Opportunity IDs: ' + deletedOpps.size());
-- Print IDs for downstream comparison

List<OpportunityLineItem> deletedOlis = [
    SELECT Id, LastModifiedDate
    FROM OpportunityLineItem
    WHERE IsDeleted = true
      AND LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
    ALL ROWS
    LIMIT 50000
];

System.debug('Deleted LineItem IDs: ' + deletedOlis.size());
```

#### 2.5.2 Ghost Records — Deleted in SF, Active in Sink

Use the deleted SF IDs from above and check if they are still active in each sink.

**Flagship (MySQL):**
```sql
-- Ghost Opportunities: deleted in SF but active in Flagship
SELECT external_id, name, is_deleted, updated_at
FROM opportunity
WHERE external_id IN ('<deleted_sf_id_1>', '<deleted_sf_id_2>', ...)
  AND is_deleted = false;

-- Ghost LineItems
SELECT external_id, name, is_deleted, updated_at
FROM opportunity_line_item
WHERE external_id IN ('<deleted_sf_id_1>', '<deleted_sf_id_2>', ...)
  AND is_deleted = false;
```

**OM (Postgres):**
```sql
-- Ghost Opportunities
SELECT external_id, name, is_deleted, updated_at
FROM opportunity
WHERE external_id IN ('<deleted_sf_id_1>', '<deleted_sf_id_2>', ...)
  AND is_deleted = false;

-- Ghost LineItems
SELECT external_id, name, is_deleted, updated_at
FROM opportunity_line_item
WHERE external_id IN ('<deleted_sf_id_1>', '<deleted_sf_id_2>', ...)
  AND is_deleted = false;
```

**FRI (SingleStore):**
```sql
-- Ghost Opportunities
SELECT external_id, name, is_deleted, updated_at
FROM opportunity
WHERE external_id IN ('<deleted_sf_id_1>', '<deleted_sf_id_2>', ...)
  AND is_deleted = false;

-- Ghost LineItems
SELECT external_id, name, is_deleted, updated_at
FROM opportunity_line_item
WHERE external_id IN ('<deleted_sf_id_1>', '<deleted_sf_id_2>', ...)
  AND is_deleted = false;
```

#### 2.5.3 Premature Deletes — Active in SF, Deleted in Sink

**OM (Postgres):**
```sql
-- Opportunities marked deleted in OM but should be active
-- Use active SF IDs from Script 05 / Section 2.3
SELECT external_id, name, is_deleted, updated_at, external_updated_at
FROM opportunity
WHERE external_id IN ('<active_sf_id_1>', '<active_sf_id_2>', ...)
  AND is_deleted = true;

-- LineItems
SELECT external_id, name, is_deleted, updated_at, external_updated_at
FROM opportunity_line_item
WHERE external_id IN ('<active_sf_id_1>', '<active_sf_id_2>', ...)
  AND is_deleted = true;
```

*(Same pattern for Flagship and FRI — replace table/syntax as needed.)*

---

## 3. Performance Metrics

### 3.1 Total Sync Time

**Goal:** Measure total wall-clock time for the sync to process records within a time window.

**Formula:**
```
total_sync_time = MAX(updated_at) - MIN(updated_at) within the time window
```

**Note:** This measures the spread of `updated_at` values in the sink — i.e., how long the sink took to process all records that arrived in the window.

#### Flagship (MySQL)

```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records_synced,
    MIN(updated_at) AS first_record_at,
    MAX(updated_at) AS last_record_at,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec
FROM opportunity
WHERE updated_at BETWEEN @from_ts AND @to_ts;

SELECT
    'opportunity_line_item' AS entity,
    COUNT(*) AS records_synced,
    MIN(updated_at) AS first_record_at,
    MAX(updated_at) AS last_record_at,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec
FROM opportunity_line_item
WHERE updated_at BETWEEN @from_ts AND @to_ts;
```

#### OpportunityManager (Postgres)

```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records_synced,
    MIN(updated_at) AS first_record_at,
    MAX(updated_at) AS last_record_at,
    EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS total_sync_sec
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts

UNION ALL

SELECT
    'opportunity_line_item',
    COUNT(*),
    MIN(updated_at),
    MAX(updated_at),
    EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at)))
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

#### FRI (SingleStore)

```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records_synced,
    MIN(updated_at) AS first_record_at,
    MAX(updated_at) AS last_record_at,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts;

SELECT
    'opportunity_line_item' AS entity,
    COUNT(*) AS records_synced,
    MIN(updated_at) AS first_record_at,
    MAX(updated_at) AS last_record_at,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

---

### 3.2 Average Time Per Record

**Formula:**
```
avg_time_per_record = total_sync_time / records_synced
```

#### OpportunityManager (Postgres)

```sql
WITH opp_perf AS (
    SELECT
        COUNT(*) AS records,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec
    FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
oli_perf AS (
    SELECT
        COUNT(*) AS records,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec
    FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
)
SELECT
    'opportunity' AS entity,
    o.records,
    o.duration_sec AS total_sync_sec,
    o.duration_sec / NULLIF(o.records, 0) AS avg_sec_per_record,
    o.records / NULLIF(o.duration_sec, 0) AS throughput_per_sec
FROM opp_perf o
UNION ALL
SELECT
    'opportunity_line_item',
    l.records,
    l.duration_sec,
    l.duration_sec / NULLIF(l.records, 0),
    l.records / NULLIF(l.duration_sec, 0)
FROM oli_perf l;
```

#### Flagship (MySQL)

```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) / NULLIF(COUNT(*), 0) AS avg_sec_per_record,
    COUNT(*) / NULLIF(TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)), 0) AS throughput_per_sec
FROM opportunity
WHERE updated_at BETWEEN @from_ts AND @to_ts;

SELECT
    'opportunity_line_item' AS entity,
    COUNT(*) AS records,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) / NULLIF(COUNT(*), 0) AS avg_sec_per_record,
    COUNT(*) / NULLIF(TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)), 0) AS throughput_per_sec
FROM opportunity_line_item
WHERE updated_at BETWEEN @from_ts AND @to_ts;
```

#### FRI (SingleStore)

```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) / NULLIF(COUNT(*), 0) AS avg_sec_per_record,
    COUNT(*) / NULLIF(TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)), 0) AS throughput_per_sec
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts;

SELECT
    'opportunity_line_item' AS entity,
    COUNT(*) AS records,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) AS total_sync_sec,
    TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)) / NULLIF(COUNT(*), 0) AS avg_sec_per_record,
    COUNT(*) / NULLIF(TIMESTAMPDIFF(SECOND, MIN(updated_at), MAX(updated_at)), 0) AS throughput_per_sec
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

---

### 3.3 Throughput (Records/sec)

**Formula:**
```
throughput_opp_sec = opp_count / window_seconds
throughput_oli_sec = oli_count / window_seconds
```

**Salesforce (upper bound — how fast SF produced changes):**

```sql
-- Apex
DateTime fromTs = DateTime.valueOf('2026-04-07 00:00:00');
DateTime toTs   = DateTime.valueOf('2026-04-08 23:59:59');

Integer oppCount = [SELECT COUNT() FROM Opportunity
                    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs];
Integer oliCount = [SELECT COUNT() FROM OpportunityLineItem
                    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs];

Long windowSec = (toTs.getTime() - fromTs.getTime()) / 1000;

Decimal oppPerSec = windowSec > 0 ? Decimal.valueOf(oppCount) / windowSec : 0;
Decimal oliPerSec = windowSec > 0 ? Decimal.valueOf(oliCount) / windowSec : 0;

System.debug('Opp throughput: ' + oppPerSec.setScale(4) + '/sec');
System.debug('OLI throughput: ' + oliPerSec.setScale(4) + '/sec');
```

**OM (Postgres) — sink-side throughput:**

```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records_synced,
    EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS total_sync_sec,
    COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))), 0) AS throughput_per_sec
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts

UNION ALL

SELECT
    'opportunity_line_item',
    COUNT(*),
    EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))),
    COUNT(*) / NULLIF(EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))), 0)
FROM opportunity_line_item
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

*(Flagship and FRI follow the same pattern — see Section 3.2 for their syntax.)*

---

### 3.4 Throughput Over Time (5-Minute Buckets)

**Goal:** Visualize how throughput varies over time. Useful for identifying bottlenecks and burst patterns.

#### OpportunityManager (Postgres)

```sql
SELECT
    date_trunc('minute', updated_at)
      - (EXTRACT(MINUTE FROM updated_at)::int % 5) * INTERVAL '1 minute' AS bucket_5min,
    SUM(CASE WHEN tbl = 'opp' THEN 1 ELSE 0 END) AS opportunities,
    SUM(CASE WHEN tbl = 'oli' THEN 1 ELSE 0 END) AS line_items,
    COUNT(*) AS total,
    COUNT(*) / 300.0 AS records_per_sec
FROM (
    SELECT 'opp' AS tbl, updated_at FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    UNION ALL
    SELECT 'oli', updated_at FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
) combined
GROUP BY 1
ORDER BY 1;
```

#### Flagship (MySQL)

```sql
SELECT
    DATE_FORMAT(updated_at, '%Y-%m-%d %H:%i') AS minute_bucket,
    SUM(CASE WHEN tbl = 'opp' THEN 1 ELSE 0 END) AS opportunities,
    SUM(CASE WHEN tbl = 'oli' THEN 1 ELSE 0 END) AS line_items,
    COUNT(*) AS total,
    COUNT(*) / 60.0 AS records_per_sec
FROM (
    SELECT 'opp' AS tbl, updated_at FROM opportunity
    WHERE updated_at BETWEEN @from_ts AND @to_ts
    UNION ALL
    SELECT 'oli' AS tbl, updated_at FROM opportunity_line_item
    WHERE updated_at BETWEEN @from_ts AND @to_ts
) combined
GROUP BY minute_bucket
ORDER BY minute_bucket;
```

#### FRI (SingleStore)

```sql
SELECT
    DATE_FORMAT(updated_at, '%Y-%m-%d %H:%i') AS minute_bucket,
    SUM(CASE WHEN tbl = 'opp' THEN 1 ELSE 0 END) AS opportunities,
    SUM(CASE WHEN tbl = 'oli' THEN 1 ELSE 0 END) AS line_items,
    COUNT(*) AS total,
    COUNT(*) / 60.0 AS records_per_sec
FROM (
    SELECT 'opp' AS tbl, updated_at FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    UNION ALL
    SELECT 'oli' AS tbl, updated_at FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
) combined
GROUP BY minute_bucket
ORDER BY minute_bucket;
```

---

### 3.5 Throughput vs Batch Size

**Goal:** Understand how throughput changes with different batch sizes. Uses `opportunity_all` CDC event density as a batch proxy.

#### OpportunityManager (Postgres)

```sql
WITH batches AS (
    SELECT
        date_trunc('second', updated_at) AS batch_ts,
        COUNT(*) AS batch_size
    FROM opportunity_all
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    GROUP BY 1
)
SELECT
    CASE
        WHEN batch_size <= 10  THEN '01-10'
        WHEN batch_size <= 50  THEN '11-50'
        WHEN batch_size <= 100 THEN '51-100'
        WHEN batch_size <= 500 THEN '101-500'
        ELSE '500+'
    END AS batch_size_bucket,
    COUNT(*) AS num_batches,
    AVG(batch_size)::int AS avg_batch_size,
    SUM(batch_size) AS total_records
FROM batches
GROUP BY 1
ORDER BY MIN(batch_size);
```

---

### 3.6 Sync Lag (End-to-End)

**Goal:** Measure the delay between when a record changed in Salesforce (`external_updated_at`) and when it was persisted in each downstream system (`updated_at`).

**Formula:**
```
sync_lag_sec = updated_at - external_updated_at
```

This is measured at each sink independently. The result tells you how stale each system is relative to Salesforce.

#### 3.6.1 Aggregate Sync Lag Stats — All Sinks

**Flagship (MySQL):**
```sql
-- Opportunity sync lag
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records,
    AVG(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS avg_lag_sec,
    MAX(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS max_lag_sec,
    MIN(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS min_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN @from_ts AND @to_ts;

-- LineItem sync lag
SELECT
    'opportunity_line_item' AS entity,
    COUNT(*) AS records,
    AVG(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS avg_lag_sec,
    MAX(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS max_lag_sec,
    MIN(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS min_lag_sec
FROM opportunity_line_item
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN @from_ts AND @to_ts;
```

**OpportunityManager (Postgres):**
```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records,
    AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at))) AS avg_lag_sec,
    PERCENTILE_CONT(0.50) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ) AS p50_lag_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ) AS p95_lag_sec,
    MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at))) AS max_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts

UNION ALL

SELECT
    'opportunity_line_item',
    COUNT(*),
    AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at))),
    PERCENTILE_CONT(0.50) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ),
    PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
    ),
    MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
FROM opportunity_line_item
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts;
```

**FRI (SingleStore):**
```sql
SELECT
    'opportunity' AS entity,
    COUNT(*) AS records,
    AVG(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS avg_lag_sec,
    MAX(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS max_lag_sec,
    MIN(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS min_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts;

SELECT
    'opportunity_line_item' AS entity,
    COUNT(*) AS records,
    AVG(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS avg_lag_sec,
    MAX(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS max_lag_sec,
    MIN(TIMESTAMPDIFF(SECOND, external_updated_at, updated_at)) AS min_lag_sec
FROM opportunity_line_item
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts;
```

#### 3.6.2 Per-Record Lag (Top 100 Worst Cases)

**OM (Postgres):**
```sql
SELECT
    external_id,
    external_updated_at AS sf_last_modified,
    updated_at          AS sink_persisted_at,
    EXTRACT(EPOCH FROM (updated_at - external_updated_at)) AS sync_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts
ORDER BY sync_lag_sec DESC
LIMIT 100;
```

**Flagship (MySQL):**
```sql
SELECT
    external_id,
    external_updated_at AS sf_last_modified,
    updated_at          AS sink_persisted_at,
    TIMESTAMPDIFF(SECOND, external_updated_at, updated_at) AS sync_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN @from_ts AND @to_ts
ORDER BY sync_lag_sec DESC
LIMIT 100;
```

#### 3.6.3 Sync Lag Distribution (Histogram Buckets)

**OM (Postgres):**
```sql
SELECT
    CASE
        WHEN lag_sec <= 10   THEN '00-10s'
        WHEN lag_sec <= 30   THEN '10-30s'
        WHEN lag_sec <= 60   THEN '30-60s'
        WHEN lag_sec <= 300  THEN '1-5min'
        WHEN lag_sec <= 600  THEN '5-10min'
        WHEN lag_sec <= 1800 THEN '10-30min'
        ELSE '30min+'
    END AS lag_bucket,
    COUNT(*) AS record_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM (
    SELECT EXTRACT(EPOCH FROM (updated_at - external_updated_at)) AS lag_sec
    FROM opportunity
    WHERE external_updated_at IS NOT NULL
      AND updated_at BETWEEN :from_ts AND :to_ts
) sub
GROUP BY 1
ORDER BY MIN(lag_sec);
```

---

### 3.7 Multi-Hop Sync Lag Decomposition

**Goal:** Break down end-to-end lag into individual hops to identify which stage introduces the most delay.

```
Total lag (SF -> FRI) = Hop1 (SF -> Flagship) + Hop2 (Flagship -> OM) + Hop3 (OM -> FRI)

Where:
  Hop1 = Flagship.updated_at - Flagship.external_updated_at
  Hop2 = OM.updated_at - Flagship.updated_at
         (approximated by: OM.updated_at - OM.external_updated_at) - (Flagship.updated_at - Flagship.external_updated_at)
         OR if Flagship.updated_at propagates through CDC, measure directly
  Hop3 = FRI.updated_at - OM.updated_at
         (same approximation approach)
```

**Practical approach:** Since all sinks store `external_updated_at` (SF timestamp) and `updated_at` (local persist time), the lag at each hop relative to the SF event is:

```
Flagship lag from SF = Flagship.updated_at - Flagship.external_updated_at
OM lag from SF       = OM.updated_at - OM.external_updated_at
FRI lag from SF      = FRI.updated_at - FRI.external_updated_at
```

**Compare per-record across sinks** (requires joining on `external_id` — run each query independently and compare by `external_id`):

**Step 1 — Flagship lag:**
```sql
-- Flagship (MySQL)
SELECT
    external_id,
    external_updated_at AS sf_event_ts,
    updated_at AS flagship_persisted_at,
    TIMESTAMPDIFF(SECOND, external_updated_at, updated_at) AS flagship_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN @from_ts AND @to_ts
ORDER BY external_id;
```

**Step 2 — OM lag:**
```sql
-- OM (Postgres)
SELECT
    external_id,
    external_updated_at AS sf_event_ts,
    updated_at AS om_persisted_at,
    EXTRACT(EPOCH FROM (updated_at - external_updated_at)) AS om_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts
ORDER BY external_id;
```

**Step 3 — FRI lag:**
```sql
-- FRI (SingleStore)
SELECT
    external_id,
    external_updated_at AS sf_event_ts,
    updated_at AS fri_persisted_at,
    TIMESTAMPDIFF(SECOND, external_updated_at, updated_at) AS fri_lag_sec
FROM opportunity
WHERE external_updated_at IS NOT NULL
  AND updated_at BETWEEN :from_ts AND :to_ts
ORDER BY external_id;
```

**Step 4 — Aggregate comparison:**

After collecting per-record lag from each sink, join by `external_id` to compute:

```
| external_id | sf_event_ts | flagship_lag_sec | om_lag_sec | fri_lag_sec |
|-------------|-------------|------------------|------------|-------------|
| 006xxxx     | 2026-04-07  | 5                | 12         | 45          |
| 006yyyy     | 2026-04-07  | 3                | 8          | 120         |

Hop breakdown (derived):
  SF -> Flagship = flagship_lag_sec
  Flagship -> OM = om_lag_sec - flagship_lag_sec
  OM -> FRI      = fri_lag_sec - om_lag_sec
```

---

## 4. Load & Scalability Metrics

> This section goes beyond SQL queries. It proposes monitoring, alerting, and dashboard designs using Datadog, application logs, and infrastructure metrics to evaluate system behavior under load.

### 4.1 CPU Usage (Service-Level)

**What to measure:** CPU utilization of each service in the sync pipeline during sync windows.

**Data source:** Datadog container metrics.

**Metrics to track:**

| Datadog Metric | Service | Description |
|---|---|---|
| `container.cpu.utilization{service:dsng}` | DSNG | Salesforce poller / sync workflow CPU |
| `container.cpu.utilization{service:flagship}` | Flagship | APIv2 processing CPU |
| `container.cpu.utilization{service:opportunitymanager}` | OM | Universal Consumer / CDC processing CPU |
| `container.cpu.utilization{service:fri}` | FRI | Geyser / SingleStore ingest CPU |

**Datadog query (example — OM service):**

```
avg:container.cpu.utilization{service:opportunitymanager} by {container_name}
```

**Design — Correlation Dashboard:**

Create a Datadog dashboard with two overlaid time series:
- **Y-axis left:** CPU utilization (%)
- **Y-axis right:** Records synced per minute (from SQL throughput queries piped into a Datadog custom metric, or from application-level instrumentation)
- **X-axis:** Time

This lets you visually answer: "When throughput spikes, does CPU saturate?"

**Alerting thresholds:**

| Threshold | Level | Action |
|---|---|---|
| CPU > 70% sustained for 10 min | Warning | Investigate — approaching saturation |
| CPU > 85% sustained for 5 min | Critical | Scale up / reduce batch size |
| CPU > 95% for any 1 min | Emergency | Likely causing sync lag degradation |

**Capacity planning approach:**
1. Run load tests at increasing record volumes (e.g., 100, 500, 1000, 5000, 10000 records/batch)
2. For each batch size, record: CPU peak, CPU avg, sync lag p95, throughput
3. Plot: batch_size (x) vs CPU_avg (y) — identify the inflection point where CPU growth becomes non-linear
4. That inflection point is your practical scaling limit for the current pod configuration

---

### 4.2 Memory Consumption

**What to measure:** Memory usage as a percentage of container memory limits, correlated with sync activity.

**Data source:** Datadog container metrics.

**Metrics to track:**

| Datadog Metric | Purpose |
|---|---|
| `container.memory.usage{service:opportunitymanager}` | Absolute memory used |
| `container.memory.limit{service:opportunitymanager}` | Container memory limit |
| `container.memory.usage / container.memory.limit * 100` | Memory utilization % |

**Datadog query:**

```
(avg:container.memory.usage{service:opportunitymanager} /
 avg:container.memory.limit{service:opportunitymanager}) * 100
```

**Design — Memory vs Batch Size Analysis:**

During load tests, correlate:
- **Memory usage** at the time of each batch
- **Batch size** (from `opportunity_all` event density — see Section 3.5)
- **Did any OOM kills occur?** Check via:
  ```
  events("service:opportunitymanager OOMKilled").count
  ```

**Alerting thresholds:**

| Threshold | Level | Action |
|---|---|---|
| Memory > 75% of limit for 5 min | Warning | Monitor for growth trend |
| Memory > 85% of limit for 3 min | Critical | Potential OOM risk — reduce batch size or scale |
| OOM kill event detected | Emergency | Immediate investigation — increase memory limit or fix leak |

**What to look for:**
- **Sawtooth pattern:** Normal GC behavior — memory climbs, drops, climbs. Healthy.
- **Monotonic growth:** Memory leak. Track across multiple sync windows — if baseline keeps rising, there is a leak.
- **Sudden spikes correlated with batch size:** The Universal Consumer may be loading too many records into memory at once. Consider streaming/chunking.

---

### 4.3 DB Write Latency

**What to measure:** How long individual DB write operations take (INSERT/UPDATE for opportunity and opportunity_line_item).

**Data sources:** Postgres `pg_stat_statements`, MySQL `performance_schema`, SingleStore `information_schema`, Datadog APM traces.

#### 4.3.1 OpportunityManager — Postgres (pg_stat_statements)

```sql
SELECT
    CASE
        WHEN query ILIKE '%INSERT INTO%opportunity_all%'       THEN 'opportunity_all_insert'
        WHEN query ILIKE '%INSERT INTO "opportunity"%'         THEN 'opportunity_insert'
        WHEN query ILIKE '%UPDATE "opportunity"%'              THEN 'opportunity_update'
        WHEN query ILIKE '%INSERT INTO%opportunity_line_item%' THEN 'line_item_insert'
        WHEN query ILIKE '%UPDATE%opportunity_line_item%'      THEN 'line_item_update'
        ELSE 'other'
    END AS operation,
    calls,
    total_exec_time / NULLIF(calls, 0)  AS avg_ms,
    min_exec_time                        AS min_ms,
    max_exec_time                        AS max_ms,
    stddev_exec_time                     AS stddev_ms
FROM pg_stat_statements
WHERE query ILIKE '%opportunity%'
  AND calls > 0
ORDER BY total_exec_time DESC
LIMIT 20;
```

#### 4.3.2 OpportunityManager — Table I/O Stats (Postgres)

```sql
SELECT
    relname AS table_name,
    n_tup_ins AS inserts,
    n_tup_upd AS updates,
    n_tup_del AS deletes,
    n_tup_ins + n_tup_upd + n_tup_del AS total_writes,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows
FROM pg_stat_user_tables
WHERE relname IN (
    'opportunity', 'opportunity_all',
    'opportunity_line_item', 'opportunity_line_item_all'
)
ORDER BY total_writes DESC;
```

#### 4.3.3 Flagship — MySQL (performance_schema)

```sql
SELECT
    DIGEST_TEXT AS query_pattern,
    COUNT_STAR AS calls,
    AVG_TIMER_WAIT / 1000000000 AS avg_ms,
    MIN_TIMER_WAIT / 1000000000 AS min_ms,
    MAX_TIMER_WAIT / 1000000000 AS max_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%opportunity%'
  AND COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

#### 4.3.4 FRI — SingleStore (mv_activities)

```sql
SELECT
    activity_name,
    activity_type,
    SUM(cpu_time_ms) / NULLIF(COUNT(*), 0) AS avg_cpu_ms,
    SUM(elapsed_time_ms) / NULLIF(COUNT(*), 0) AS avg_elapsed_ms,
    COUNT(*) AS executions
FROM information_schema.mv_activities
WHERE activity_name LIKE '%opportunity%'
  AND activity_type IN ('Insert', 'Update')
GROUP BY activity_name, activity_type
ORDER BY avg_elapsed_ms DESC
LIMIT 20;
```

#### 4.3.5 Datadog APM — DB Write Latency

**Datadog query (trace-based):**
```
avg:trace.postgres.query.duration{service:opportunitymanager,resource_name:INSERT opportunity} by {resource_name}
```

**Design — Latency Heatmap:**

Create a Datadog heatmap widget:
- **X-axis:** Time
- **Y-axis:** Latency (ms)
- **Color intensity:** Number of queries in that latency band

Group by `resource_name` to see INSERT vs UPDATE patterns separately.

**Alerting thresholds:**

| Metric | Target | Warning | Critical |
|---|---|---|---|
| avg write latency (opportunity) | < 20ms | > 50ms | > 100ms |
| avg write latency (line_item) | < 15ms | > 40ms | > 80ms |
| p95 write latency | < 50ms | > 100ms | > 250ms |
| dead_rows / live_rows ratio | < 10% | > 20% | > 40% (needs VACUUM) |

---

### 4.4 Error Rate vs Load

**Goal:** Determine if error rates increase as load (records/minute) increases — a sign of scalability limits.

#### 4.4.1 SQL-Based (OM — using orphaned events as error proxy)

```sql
WITH per_minute AS (
    SELECT
        date_trunc('minute', updated_at) AS minute_ts,
        COUNT(*) AS records_processed
    FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
    GROUP BY 1
),
orphans_per_minute AS (
    SELECT
        date_trunc('minute', oa.updated_at) AS minute_ts,
        COUNT(*) AS orphan_count
    FROM opportunity_all oa
    LEFT JOIN opportunity o ON o.id = oa.id
    WHERE oa.updated_at BETWEEN :from_ts AND :to_ts
      AND o.id IS NULL
    GROUP BY 1
)
SELECT
    p.minute_ts,
    p.records_processed AS load,
    COALESCE(e.orphan_count, 0) AS errors,
    100.0 * COALESCE(e.orphan_count, 0) / NULLIF(p.records_processed, 0) AS error_rate_pct
FROM per_minute p
LEFT JOIN orphans_per_minute e ON e.minute_ts = p.minute_ts
ORDER BY p.minute_ts;
```

#### 4.4.2 Datadog Log-Based

**Log query (error count per minute):**
```
service:(dsng OR flagship OR opportunitymanager) status:error @entity_type:opportunity
| count by 1m
```

**Overlay with throughput:**

Create a Datadog dashboard with:
- **Widget 1 (line chart):** `count of logs{service:opportunitymanager,status:error} by {1m}` — error count
- **Widget 2 (line chart):** `count of logs{service:opportunitymanager,status:info,message:"*synced*"} by {1m}` — sync count (adjust message filter to match actual log patterns)
- **Widget 3 (formula):** `error_count / (error_count + success_count) * 100` — error rate %

**What this reveals:**
- If error_rate stays flat as load increases: the system is stable
- If error_rate climbs with load: there is a scalability bottleneck (connection pool, memory, CPU)
- If error_rate spikes at specific load thresholds: you have found the system's practical capacity limit

---

### 4.5 Burst Detection & Peak Analysis

**Goal:** Identify when the highest volumes of changes occur in Salesforce and whether the pipeline handles those bursts.

#### 4.5.1 Salesforce — Peak Hour Analysis

```sql
-- Apex: Top 10 busiest hours in the sync window
List<AggregateResult> burstAnalysis = [
    SELECT COUNT(Id) cnt
    FROM Opportunity
    WHERE LastModifiedDate >= :fromTs AND LastModifiedDate <= :toTs
    GROUP BY HOUR_IN_DAY(LastModifiedDate), DAY_IN_MONTH(LastModifiedDate)
    ORDER BY COUNT(Id) DESC
    LIMIT 10
];

for (AggregateResult ar : burstAnalysis) {
    System.debug('Burst: ' + ar.get('cnt') + ' modifications/hour');
}
```

#### 4.5.2 OM — Records Per Minute (Peak Detection)

```sql
-- Postgres: find the minute with highest write volume
SELECT
    date_trunc('minute', updated_at) AS minute_ts,
    COUNT(*) AS records_this_minute
FROM opportunity
WHERE updated_at BETWEEN :from_ts AND :to_ts
GROUP BY 1
ORDER BY records_this_minute DESC
LIMIT 20;
```

#### 4.5.3 Datadog — Kafka/CDC Consumer Lag

If the pipeline uses Kafka (Clerk CDC), monitor consumer lag:

**Datadog metric:**
```
avg:kafka.consumer_lag{consumer_group:opportunity-consumer,topic:opportunity-cdc}
```

**Alerting:**

| Condition | Level | Action |
|---|---|---|
| Consumer lag > 1000 for 5 min | Warning | Pipeline falling behind — investigate |
| Consumer lag > 10000 for 5 min | Critical | Significant backlog — scale consumers |
| Consumer lag > 50000 | Emergency | Pipeline is stalled |

**Capacity planning matrix:**

Run load tests and fill out this table:

```
| Burst Size  | Peak Records/min | Consumer Lag (peak) | Sync Lag p95 | CPU Peak | Errors |
|-------------|------------------|---------------------|--------------|----------|--------|
| 100/batch   | ???              | ???                 | ???          | ???      | ???    |
| 500/batch   | ???              | ???                 | ???          | ???      | ???    |
| 1000/batch  | ???              | ???                 | ???          | ???      | ???    |
| 5000/batch  | ???              | ???                 | ???          | ???      | ???    |
| 10000/batch | ???              | ???                 | ???          | ???      | ???    |
```

The row where sync lag degrades non-linearly marks the practical capacity ceiling.

---

## 5. Reliability Metrics

### 5.1 Failure Rate

**Goal:** Measure what percentage of sync events fail to result in a persisted record.

**Formula:**
```
failure_rate_pct = (failed_events / total_events) * 100
```

**Proxy:** Events in `opportunity_all` that never made it to `opportunity` (orphaned events).

#### OM (Postgres) — Orphaned Events

```sql
-- Total orphaned events (potential failures)
SELECT COUNT(*) AS orphaned_events
FROM opportunity_all oa
LEFT JOIN opportunity o ON o.id = oa.id
WHERE oa.updated_at BETWEEN :from_ts AND :to_ts
  AND o.id IS NULL;

-- Failure rate
SELECT
    COUNT(*) AS total_events,
    COUNT(*) FILTER (WHERE o.id IS NULL) AS failed_events,
    100.0 * COUNT(*) FILTER (WHERE o.id IS NULL) / NULLIF(COUNT(*), 0) AS failure_rate_pct
FROM opportunity_all oa
LEFT JOIN opportunity o ON o.id = oa.id
WHERE oa.updated_at BETWEEN :from_ts AND :to_ts;
```

#### Datadog Log-Based — Failure Count

```
service:opportunitymanager status:error
| stats count by @error_type
```

---

### 5.2 Error Categorization

**Goal:** Classify errors into actionable categories to guide remediation.

#### 5.2.1 Salesforce-Side Validation Errors (SOQL)

Records with NULL required fields may fail during sync due to NOT NULL constraints in downstream tables.

```sql
-- Apex: potential validation failures

-- Opportunities with NULL required fields
Integer oppNullName      = [SELECT COUNT() FROM Opportunity
                            WHERE Name = null AND IsDeleted = false];
Integer oppNullStage     = [SELECT COUNT() FROM Opportunity
                            WHERE StageName = null AND IsDeleted = false];
Integer oppNullCloseDate = [SELECT COUNT() FROM Opportunity
                            WHERE CloseDate = null AND IsDeleted = false];

System.debug('Validation Errors:');
System.debug('  NULL Name:      ' + oppNullName);
System.debug('  NULL StageName: ' + oppNullStage);
System.debug('  NULL CloseDate: ' + oppNullCloseDate);
```

#### 5.2.2 Datadog Log-Based Error Categorization

**Proposed error categories and their log signatures:**

| Category | Log Pattern (Datadog filter) | Cause |
|---|---|---|
| `validation_error` | `"constraint violation" OR "NOT NULL" OR "data truncation"` | NULL fields, type mismatches, oversized values |
| `timeout_error` | `"timeout" OR "deadline exceeded" OR "context canceled"` | HTTP/gRPC timeouts between services |
| `connection_error` | `"connection refused" OR "connection pool" OR "too many connections"` | DB/service connection issues |
| `deserialization_error` | `"unmarshal" OR "deserialize" OR "invalid JSON" OR "schema"` | Malformed CDC events, schema drift |
| `duplicate_key_error` | `"unique constraint" OR "duplicate key" OR "conflict on"` | Duplicate external_id insertion |
| `rate_limit_error` | `"rate limit" OR "REQUEST_LIMIT_EXCEEDED" OR "429"` | SF API rate limit hits |

**Datadog log query for each category:**

```
-- Validation errors
service:(dsng OR flagship OR opportunitymanager) status:error
  ("constraint violation" OR "NOT NULL" OR "data truncation")

-- Timeout errors
service:(dsng OR flagship OR opportunitymanager) status:error
  ("timeout" OR "deadline exceeded" OR "context canceled")

-- Connection errors
service:(dsng OR flagship OR opportunitymanager) status:error
  ("connection refused" OR "connection pool" OR "too many connections")
```

**Design — Error Classification Pipeline:**

1. **Datadog Log Pipeline:** Create a Grok parser that extracts `error_type` from error messages
2. **Log-based custom metric:** `sync.errors.count` tagged by `error_type`, `entity_type`, `service`
3. **Dashboard widget:** Stacked bar chart of errors by category over time

**Datadog log pipeline (Grok parser example):**
```
sync_error_rule  %{data:message} %{regex("(?:constraint violation|NOT NULL|data truncation)"):error_type:validation_error}
sync_error_rule  %{data:message} %{regex("(?:timeout|deadline exceeded|context canceled)"):error_type:timeout_error}
sync_error_rule  %{data:message} %{regex("(?:connection refused|connection pool|too many connections)"):error_type:connection_error}
```

---

### 5.3 Retry Behavior

**Goal:** Detect and measure retry attempts — the same record being processed multiple times.

**Proxy:** Multiple events in `opportunity_all` for the same `(id, row_hash)` pair.

**Formula:**
```
retries = event_count_for_same_row_hash - 1
retry_rate = records_with_retries / total_synced
```

#### OM (Postgres) — Per-Record Retries

```sql
SELECT
    id,
    row_hash,
    COUNT(*) AS event_count,
    COUNT(*) - 1 AS retry_count
FROM opportunity_all
WHERE updated_at BETWEEN :from_ts AND :to_ts
  AND row_hash IS NOT NULL
GROUP BY id, row_hash
HAVING COUNT(*) > 1
ORDER BY retry_count DESC
LIMIT 50;
```

#### OM (Postgres) — Retry Summary

```sql
SELECT
    SUM(CASE WHEN cnt > 1 THEN cnt - 1 ELSE 0 END) AS total_retries,
    COUNT(CASE WHEN cnt > 1 THEN 1 END) AS records_with_retries,
    SUM(cnt) AS total_events,
    100.0 * COUNT(CASE WHEN cnt > 1 THEN 1 END) /
        NULLIF(COUNT(*), 0) AS retry_rate_pct
FROM (
    SELECT id, row_hash, COUNT(*) AS cnt
    FROM opportunity_all
    WHERE updated_at BETWEEN :from_ts AND :to_ts
      AND row_hash IS NOT NULL
    GROUP BY id, row_hash
) sub;
```

---

### 5.4 Redundant Events

**Goal:** Measure wasted work — CDC events that carry no new data (same `row_hash` repeated).

**Formula:**
```
redundant_events = total_events - distinct_events
redundancy_rate  = redundant_events / total_events * 100
```

#### OM (Postgres)

```sql
SELECT
    COUNT(*) AS total_events,
    COUNT(DISTINCT (id::text || ':' || COALESCE(row_hash, ''))) AS distinct_events,
    COUNT(*) - COUNT(DISTINCT (id::text || ':' || COALESCE(row_hash, ''))) AS redundant_events,
    100.0 * (COUNT(*) - COUNT(DISTINCT (id::text || ':' || COALESCE(row_hash, '')))) /
        NULLIF(COUNT(*), 0) AS redundancy_rate_pct
FROM opportunity_all
WHERE updated_at BETWEEN :from_ts AND :to_ts;
```

---

## 6. Summary & Executive Report

### 6.1 Composite Summary Query — OpportunityManager (Postgres)

A single query that produces all key metrics for a given time window.

```sql
WITH opp_stats AS (
    SELECT
        COUNT(*) AS total,
        MIN(updated_at) AS first_at,
        MAX(updated_at) AS last_at,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec,
        AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
            FILTER (WHERE external_updated_at IS NOT NULL) AS avg_lag_sec,
        PERCENTILE_CONT(0.50) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
        ) FILTER (WHERE external_updated_at IS NOT NULL) AS p50_lag_sec,
        PERCENTILE_CONT(0.95) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
        ) FILTER (WHERE external_updated_at IS NOT NULL) AS p95_lag_sec,
        MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
            FILTER (WHERE external_updated_at IS NOT NULL) AS max_lag_sec
    FROM opportunity
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
oli_stats AS (
    SELECT
        COUNT(*) AS total,
        MIN(updated_at) AS first_at,
        MAX(updated_at) AS last_at,
        EXTRACT(EPOCH FROM (MAX(updated_at) - MIN(updated_at))) AS duration_sec,
        AVG(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
            FILTER (WHERE external_updated_at IS NOT NULL) AS avg_lag_sec,
        PERCENTILE_CONT(0.50) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
        ) FILTER (WHERE external_updated_at IS NOT NULL) AS p50_lag_sec,
        PERCENTILE_CONT(0.95) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (updated_at - external_updated_at))
        ) FILTER (WHERE external_updated_at IS NOT NULL) AS p95_lag_sec,
        MAX(EXTRACT(EPOCH FROM (updated_at - external_updated_at)))
            FILTER (WHERE external_updated_at IS NOT NULL) AS max_lag_sec
    FROM opportunity_line_item
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
retry_stats AS (
    SELECT
        SUM(CASE WHEN cnt > 1 THEN cnt - 1 ELSE 0 END) AS total_retries,
        COUNT(CASE WHEN cnt > 1 THEN 1 END) AS records_with_retries
    FROM (
        SELECT id, row_hash, COUNT(*) AS cnt
        FROM opportunity_all
        WHERE updated_at BETWEEN :from_ts AND :to_ts
          AND row_hash IS NOT NULL
        GROUP BY id, row_hash
    ) sub
),
orphan_stats AS (
    SELECT COUNT(*) AS orphaned
    FROM opportunity_all oa
    LEFT JOIN opportunity o ON o.id = oa.id
    WHERE oa.updated_at BETWEEN :from_ts AND :to_ts
      AND o.id IS NULL
),
redundant_stats AS (
    SELECT
        COUNT(*) AS total_events,
        COUNT(*) - COUNT(DISTINCT (id::text || ':' || COALESCE(row_hash, ''))) AS redundant_events
    FROM opportunity_all
    WHERE updated_at BETWEEN :from_ts AND :to_ts
),
dup_stats AS (
    SELECT COUNT(*) AS opp_duplicates FROM (
        SELECT external_id FROM opportunity
        WHERE external_id IS NOT NULL AND is_deleted = false
        GROUP BY external_id HAVING COUNT(*) > 1
    ) d
)
SELECT
    -- Total Records Processed
    o.total                                                     AS opp_processed,
    l.total                                                     AS oli_processed,
    o.total + l.total                                           AS total_processed,

    -- Success Rate
    100.0 - (100.0 * orph.orphaned / NULLIF(o.total + l.total, 0))
                                                                AS success_rate_pct,

    -- Throughput
    o.total / NULLIF(o.duration_sec, 0)                         AS opp_per_sec,
    l.total / NULLIF(l.duration_sec, 0)                         AS oli_per_sec,

    -- Total Sync Time
    o.duration_sec                                              AS opp_sync_sec,
    l.duration_sec                                              AS oli_sync_sec,

    -- Avg Time Per Record
    o.duration_sec / NULLIF(o.total, 0)                         AS opp_avg_sec_per_record,
    l.duration_sec / NULLIF(l.total, 0)                         AS oli_avg_sec_per_record,

    -- Sync Lag
    o.avg_lag_sec                                               AS opp_avg_lag_sec,
    o.p50_lag_sec                                               AS opp_p50_lag_sec,
    o.p95_lag_sec                                               AS opp_p95_lag_sec,
    o.max_lag_sec                                               AS opp_max_lag_sec,
    l.avg_lag_sec                                               AS oli_avg_lag_sec,
    l.p50_lag_sec                                               AS oli_p50_lag_sec,
    l.p95_lag_sec                                               AS oli_p95_lag_sec,
    l.max_lag_sec                                               AS oli_max_lag_sec,

    -- Reliability
    orph.orphaned                                               AS failed_events,
    100.0 * orph.orphaned / NULLIF(o.total + l.total, 0)        AS failure_rate_pct,
    r.total_retries,
    r.records_with_retries,
    red.redundant_events,
    100.0 * red.redundant_events / NULLIF(red.total_events, 0)  AS redundancy_rate_pct,
    dup.opp_duplicates

FROM opp_stats o, oli_stats l, retry_stats r, orphan_stats orph,
     redundant_stats red, dup_stats dup;
```

### 6.2 Suggested SLA Thresholds

| Metric | Target | Warning | Critical |
|---|---|---|---|
| Record count parity | > 99.9% | < 99.5% | < 99.0% |
| Field accuracy (per field) | > 99.95% | < 99.9% | < 99.5% |
| Missing record rate | < 0.05% | > 0.1% | > 0.5% |
| Duplicate count | 0 | > 0 | > 10 |
| Sync lag (p50) | < 60s | > 120s | > 300s |
| Sync lag (p95) | < 300s | > 600s | > 1200s |
| Throughput (opp/sec) | > 50 | < 30 | < 10 |
| Throughput (oli/sec) | > 100 | < 50 | < 20 |
| Failure rate | < 0.1% | > 0.5% | > 1.0% |
| Retry rate | < 5% | > 10% | > 25% |
| Redundancy rate | < 10% | > 20% | > 40% |
| DB write latency (p95) | < 50ms | > 100ms | > 250ms |
| CPU utilization | < 60% | > 70% | > 85% |
| Memory utilization | < 70% | > 80% | > 90% |
| Kafka consumer lag | < 1000 | > 5000 | > 20000 |

---

## 7. Reporting & Visualization Guidance

### 7.1 Recommended Dashboards

#### Dashboard 1: Sync Health Overview

| Widget | Type | Data Source | Purpose |
|---|---|---|---|
| Total records processed (today) | Query Value | Section 6.1 summary query | At-a-glance volume |
| Success rate | Query Value (green/red) | Section 6.1 | Quick health check |
| Sync lag p95 | Query Value (with threshold colors) | Section 3.6 | Freshness indicator |
| Records processed over time | Time Series | Section 3.4 (5-min buckets) | Volume trend |
| Error rate over time | Time Series | Section 4.4 | Reliability trend |
| Lag distribution | Histogram | Section 3.6.3 | Lag shape |

#### Dashboard 2: Performance Deep Dive

| Widget | Type | Data Source | Purpose |
|---|---|---|---|
| Throughput over time (opp + oli) | Stacked Time Series | Section 3.4 | Volume decomposition |
| Throughput vs batch size | Grouped Bar | Section 3.5 | Batch size optimization |
| Avg time per record over time | Time Series | Section 3.2 | Per-record latency trend |
| Multi-hop lag comparison | Grouped Bar | Section 3.7 | Identify slowest hop |
| DB write latency (p50, p95, max) | Time Series | Section 4.3 | DB health |

#### Dashboard 3: Reliability & Errors

| Widget | Type | Data Source | Purpose |
|---|---|---|---|
| Error count by category | Stacked Bar | Section 5.2.2 | Error classification |
| Error rate vs load | Dual-Axis Line | Section 4.4 | Scalability limit detection |
| Retry rate over time | Time Series | Section 5.3 | Retry trend |
| Orphaned events count | Query Value | Section 5.1 | Failure count |
| Redundant events % | Query Value | Section 5.4 | Pipeline noise |

#### Dashboard 4: Scalability & Load

| Widget | Type | Data Source | Purpose |
|---|---|---|---|
| CPU utilization by service | Time Series | Section 4.1 | Resource usage |
| Memory utilization by service | Time Series | Section 4.2 | Memory pressure |
| Kafka consumer lag | Time Series | Section 4.5.3 | Pipeline backlog |
| Burst detection (peak hours) | Bar Chart | Section 4.5 | Peak identification |
| Capacity planning matrix | Table | Section 4.5.3 | Scaling decisions |

### 7.2 Chart Type Selection Guide

| Data Pattern | Recommended Chart | Example |
|---|---|---|
| Metric over time | Time series line | Throughput over time, error rate over time |
| Comparing categories | Grouped / stacked bar | Throughput vs batch size, errors by type |
| Distribution shape | Histogram / box plot | Sync lag distribution |
| Single KPI | Query value / gauge | Success rate, total processed |
| Correlation between 2 metrics | Dual-axis line / scatter | Error rate vs load, CPU vs throughput |
| Cross-system comparison | Table / heatmap | Count parity across SF/Flagship/OM/FRI |
| Multi-dimensional | Heatmap | DB write latency over time by operation |

### 7.3 Refresh Cadence

| Dashboard | Refresh Interval | Reason |
|---|---|---|
| Sync Health Overview | Every 5 minutes | Real-time operational awareness |
| Performance Deep Dive | Every 15 minutes | Trend analysis, not real-time |
| Reliability & Errors | Every 5 minutes | Errors need quick visibility |
| Scalability & Load | Every 1 minute during load tests, 15 min otherwise | High resolution during tests |

---

## Appendix A: Script Cross-Reference

| This Doc Section | Existing Script | Database |
|---|---|---|
| 2.1 Record Count Parity | `01_record_count_parity.apex` | Salesforce |
| 2.1 Record Count Parity | `09_companion_queries_outreach.sql` (lines 25-43) | Flagship (MySQL) |
| 2.1 Record Count Parity | `10_companion_queries_oppmanager.sql` (lines 27-37) | OM (Postgres) |
| 2.2 Field-Level Accuracy | `02_opportunity_field_accuracy.apex` | Salesforce |
| 2.2 Field-Level Accuracy | `03_lineitem_field_accuracy.apex` | Salesforce |
| 2.2 Field-Level Accuracy | `09_companion_queries_outreach.sql` (lines 71-119) | Flagship (MySQL) |
| 2.2 Field-Level Accuracy | `10_companion_queries_oppmanager.sql` (lines 221-275) | OM (Postgres) |
| 2.3 Missing Records | `05_missing_records_detection.apex` | Salesforce |
| 2.3 Missing Records | `09_companion_queries_outreach.sql` (lines 128-137) | Flagship (MySQL) |
| 2.3 Missing Records | `10_companion_queries_oppmanager.sql` (lines 284-292) | OM (Postgres) |
| 2.4 Duplicate Detection | `10_companion_queries_oppmanager.sql` (lines 300-310) | OM (Postgres) |
| 3.1-3.3 Performance | `10_companion_queries_oppmanager.sql` (lines 81-109) | OM (Postgres) |
| 3.4 Throughput Over Time | `10_companion_queries_oppmanager.sql` (lines 169-183) | OM (Postgres) |
| 3.5 Throughput vs Batch | `10_companion_queries_oppmanager.sql` (lines 191-212) | OM (Postgres) |
| 3.6 Sync Lag | `04_sync_lag_analysis.apex` | Salesforce |
| 3.6 Sync Lag | `09_companion_queries_outreach.sql` (lines 145-154) | Flagship (MySQL) |
| 3.6 Sync Lag | `10_companion_queries_oppmanager.sql` (lines 118-161) | OM (Postgres) |
| 4.3 DB Write Latency | `10_companion_queries_oppmanager.sql` (lines 408-446) | OM (Postgres) |
| 4.4 Error Rate vs Load | `10_companion_queries_oppmanager.sql` (lines 375-400) | OM (Postgres) |
| 4.5 Burst Detection | `06_data_distribution.apex` | Salesforce |
| 4.5 Burst Detection | `08_reliability_metrics.apex` | Salesforce |
| 5.1 Failure Rate | `10_companion_queries_oppmanager.sql` (lines 348-352) | OM (Postgres) |
| 5.3 Retry Behavior | `10_companion_queries_oppmanager.sql` (lines 319-340) | OM (Postgres) |
| 5.4 Redundant Events | `10_companion_queries_oppmanager.sql` (lines 360-365) | OM (Postgres) |
| 6.1 Summary Report | `10_companion_queries_oppmanager.sql` (lines 454-525) | OM (Postgres) |

---

## Appendix B: Quick-Start Checklist

1. **Set time window** — Choose the sync window you want to analyze
2. **Run Salesforce scripts** (01, 02, 03, 04, 05, 08) in Developer Console
3. **Copy SF IDs** from the Apex output
4. **Run Flagship queries** (Section 2-3) on MySQL, pasting SF IDs where needed
5. **Run OM queries** (Section 2-3, 5) on Postgres
6. **Run FRI queries** (Section 2-3) on SingleStore
7. **Run Summary Report** (Section 6.1) on OM for the composite view
8. **Check Datadog** for CPU, memory, consumer lag, and error logs (Section 4)
9. **Fill out the parity table** (Section 2.1.6) and capacity planning matrix (Section 4.5.3)
10. **Compare against SLA thresholds** (Section 6.2) and create action items for any breaches
