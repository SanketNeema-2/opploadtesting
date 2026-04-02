# Salesforce Bulk Data Operations - Technical Design Document

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Salesforce Developer Edition Limits](#3-salesforce-developer-edition-limits)
4. [Entity Dependency Chain](#4-entity-dependency-chain)
5. [Approach A: Apex Batch Scripts (Developer Console)](#5-approach-a-apex-batch-scripts-developer-console)
6. [Approach B: Go Bulk API 2.0 Client (External)](#6-approach-b-go-bulk-api-20-client-external)
7. [Scalability Analysis](#7-scalability-analysis)
8. [Runbook](#8-runbook)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Overview

### Purpose

On-demand creation and deletion of Opportunities and Opportunity Line Items in a
Salesforce Developer Edition org. Supports two execution paths:

- **Apex Batch Classes** - Run directly in Developer Console (primary approach)
- **Go CLI (Bulk API 2.0)** - External client for high-volume operations

### Use Cases

- Seed test/demo environments with realistic Opportunity data
- Load test CRM integrations that consume Salesforce CDC events
- Validate data pipeline throughput (e.g., opportunitymanager CDC processing)
- Clean up test data via bulk deletion

### Record Counts Are Configurable

All scripts accept record counts as parameters. Start small and scale up based on
your org's storage capacity.

---

## 2. Architecture

### Data Flow

```
Developer Console (Apex)          Go CLI (Bulk API 2.0)
        |                                  |
        v                                  v
  Apex Batch Jobs                   REST API Calls
        |                                  |
        v                                  v
  +-------------------------------------------------+
  |           Salesforce Developer Edition           |
  |                                                  |
  |  Product2 --> PricebookEntry --> Opportunity      |
  |                                  |               |
  |                          OpportunityLineItem     |
  +-------------------------------------------------+
                      |
                      v (CDC events downstream)
              Clerk/Kafka Pipeline
                      |
                      v
             opportunitymanager
```

### Two Execution Paths

| Aspect | Apex Batch (Developer Console) | Go Bulk API 2.0 Client |
|--------|-------------------------------|----------------------|
| Runs where | Inside Salesforce | External machine |
| Best for | < 5,000 records | 5,000 - 500,000+ records |
| Setup required | None (just paste & run) | Go runtime, Connected App |
| Monitoring | Setup > Apex Jobs | CLI output + job polling |
| Error handling | `Database.SaveResult[]` | CSV error results |
| Rate limiting | Governor limits | API rate limits |

---

## 3. Salesforce Developer Edition Limits

### Storage Limits (The Real Bottleneck)

| Resource | Developer Edition | Developer Pro / Partner Dev |
|----------|------------------|-----------------------------|
| Data storage | **5 MB** | **20 MB - 120 MB** |
| File storage | **20 MB** | **100 MB** |

### Storage Calculator

Each Salesforce record consumes approximately **2 KB** base storage. With custom
fields and relationships, budget **3-4 KB per record**.

```
Estimated storage per Opportunity + 3 LineItems:
  Opportunity:       ~3 KB
  3 x LineItem:      ~2 KB each = 6 KB
  Total per Opp:     ~9 KB

Developer Edition (5 MB = 5,120 KB):
  Max Opportunities: ~500 (with 3 line items each)
  Without LineItems: ~1,500 Opportunities

Developer Pro (20 MB = 20,480 KB):
  Max Opportunities: ~2,000 (with 3 line items each)
  Without LineItems: ~6,000 Opportunities
```

**Recommendation**: For volumes > 5,000 Opportunities, use a Partner Developer
Edition or Sandbox org.

### Governor Limits

| Resource | Synchronous | Asynchronous (Batch) |
|----------|------------|---------------------|
| DML rows per transaction | 10,000 | 10,000 |
| DML statements per transaction | 150 | 150 |
| SOQL queries per transaction | 100 | 200 |
| CPU time | 10,000 ms | 60,000 ms |
| Heap size | 6 MB | 12 MB |
| Callout timeout | 10 sec (per callout) | 120 sec |

### Batch Apex Limits

| Resource | Limit |
|----------|-------|
| Max batch size (`scope`) | 2,000 records |
| Max queued/active batch jobs | 5 concurrent |
| Max batches per 24-hour period | 250,000 |
| `Database.Batchable` max records returned by `start()` | 50,000,000 |
| `Database.QueryLocator` max records | 50,000,000 |

### Bulk API 2.0 Limits

| Resource | Limit |
|----------|-------|
| Concurrent Bulk API jobs | 5 |
| Max records per job | 150,000,000 |
| Max record size | 10 MB (per batch upload) |
| Max CSV file size per upload | 150 MB |
| API requests per 24 hours (Dev Ed) | 15,000 |
| Bulk API batches per 24 hours | 15,000 |

---

## 4. Entity Dependency Chain

Records must be created in this order due to foreign key dependencies:

```
Step 1: Product2
    |
    v
Step 2: PricebookEntry (references Product2 + standard Pricebook2)
    |
    v
Step 3: Opportunity (references Account, optional)
    |
    v
Step 4: OpportunityLineItem (references Opportunity + PricebookEntry)
```

### Deletion Order (Reverse)

Deleting an Opportunity **automatically cascade-deletes** its OpportunityLineItems.
No need to delete LineItems separately.

```
Step 1: Delete Opportunities (LineItems cascade-deleted automatically)
Step 2: Delete PricebookEntries (optional cleanup)
Step 3: Delete Products (optional cleanup)
```

---

## 5. Approach A: Apex Batch Scripts (Developer Console)

### Overview

Four Apex scripts designed to run in Developer Console's Anonymous Apex window.
All record counts are configurable via constants at the top of each script.

### Script Inventory

| Script | Purpose | Execution Mode |
|--------|---------|---------------|
| `01_create_products.apex` | Create Product2 + PricebookEntry records | Synchronous (small count) |
| `02_create_opportunities.apex` | Batch create Opportunities | Asynchronous (Database.Batchable) |
| `03_create_lineitems.apex` | Batch create OpportunityLineItems | Asynchronous (Database.Batchable) |
| `04_delete_opportunities.apex` | Batch delete Opportunities (cascades to LineItems) | Asynchronous (Database.Batchable) |

### Batch Design Pattern

All batch classes follow this pattern:

```apex
public class OpportunityCreatorBatch implements Database.Batchable<Integer>,
                                                 Database.Stateful {
    // Configuration
    private Integer totalRecords;
    private Integer batchSize;

    // Stateful counters (survive across batches)
    private Integer successCount = 0;
    private Integer failureCount = 0;

    public Iterable<Integer> start(Database.BatchableContext bc) {
        // Return a list of integers as "work units"
        // Each integer represents one record to create
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        // Create records for this batch
        // Use Database.insert(records, false) for partial success
    }

    public void finish(Database.BatchableContext bc) {
        // Log results
        System.debug('Success: ' + successCount + ', Failed: ' + failureCount);
    }
}
```

Key design decisions:
- `Database.Stateful` preserves counters across batches
- `Database.insert(records, false)` allows partial success (allOrNone=false)
- Batch size defaults to 200 (safe margin under the 10,000 DML row limit)
- Uses `Iterable<Integer>` instead of `QueryLocator` since we're generating data, not querying

### Chaining Strategy

OpportunityLineItems depend on Opportunity IDs existing first. Two options:

1. **Manual chaining**: Run script 02, wait for completion, then run script 03
2. **Auto-chaining**: Script 02's `finish()` method invokes script 03 via `Database.executeBatch()`

The scripts support both. Auto-chaining is disabled by default to give you
control over each step.

### Monitoring Batch Jobs

```
Setup > Environments > Jobs > Apex Jobs
```

Or query in Developer Console:

```sql
SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors,
       CreatedDate, CompletedDate
FROM AsyncApexJob
WHERE JobType = 'BatchApex'
ORDER BY CreatedDate DESC
LIMIT 10
```

---

## 6. Approach B: Go Bulk API 2.0 Client (External)

### Prerequisites

1. **Connected App** in Salesforce with OAuth 2.0 enabled
2. **Go 1.25+** installed on your machine
3. **Environment variables** configured (see config section)

### Connected App Setup

1. Setup > App Manager > New Connected App
2. Enable OAuth Settings:
   - Callback URL: `https://login.salesforce.com/services/oauth2/callback`
   - OAuth Scopes: `full`, `api`, `bulk`
3. Note the **Consumer Key** and **Consumer Secret**
4. Under "OAuth Policies": Set "Permitted Users" to "All users may self-authorize"

### Authentication Flow

The Go client uses the **OAuth 2.0 Username-Password** flow:

```
POST https://login.salesforce.com/services/oauth2/token
  grant_type=password
  client_id=<consumer_key>
  client_secret=<consumer_secret>
  username=<sf_username>
  password=<sf_password + security_token>
```

Response contains `access_token` and `instance_url` used for all subsequent API calls.

### Bulk API 2.0 Job Lifecycle

```
1. Create Job    POST /services/data/v62.0/jobs/ingest
                 Body: { "object": "Opportunity", "operation": "insert",
                         "contentType": "CSV" }
                 Response: { "id": "750xx000000001AAA", "state": "Open" }

2. Upload Data   PUT /services/data/v62.0/jobs/ingest/<jobId>/batches
                 Content-Type: text/csv
                 Body: <CSV data>

3. Close Job     PATCH /services/data/v62.0/jobs/ingest/<jobId>
                 Body: { "state": "UploadComplete" }

4. Poll Status   GET /services/data/v62.0/jobs/ingest/<jobId>
                 Poll until state = "JobComplete" or "Failed"

5. Get Results   GET /services/data/v62.0/jobs/ingest/<jobId>/successfulResults
                 GET /services/data/v62.0/jobs/ingest/<jobId>/failedResults
```

### Two-Phase Insert Strategy

**Phase 1: Opportunities**
1. Generate CSV: `Name,StageName,CloseDate,Amount`
2. Submit Bulk API insert job
3. Poll until complete
4. Download `successfulResults` CSV -> extract `sf__Id` column (created Opportunity IDs)

**Phase 2: OpportunityLineItems**
1. Query PricebookEntry IDs: `SELECT Id FROM PricebookEntry WHERE IsActive = true`
2. Generate CSV: `OpportunityId,PricebookEntryId,Quantity,UnitPrice`
3. Submit Bulk API insert job
4. Poll until complete

### Deletion via Bulk API 2.0

```
1. Query Opp IDs:  SELECT Id FROM Opportunity (via SOQL or previous job results)
2. Create Job:     POST /jobs/ingest { "object": "Opportunity",
                                        "operation": "hardDelete" }
3. Upload CSV:     PUT  /jobs/ingest/<id>/batches
                   Body: Id\n001xx000003ABC\n001xx000003ABD\n...
4. Close + Poll
```

Note: `hardDelete` requires the "Bulk API Hard Delete" permission. Use `delete`
for soft delete (records go to Recycle Bin).

### CLI Commands

```bash
# Set environment variables
export SF_USERNAME="your-username@example.com"
export SF_PASSWORD="your-password"
export SF_SECURITY_TOKEN="your-token"
export SF_CLIENT_ID="your-consumer-key"
export SF_CLIENT_SECRET="your-consumer-secret"
export SF_LOGIN_URL="https://login.salesforce.com"  # or test.salesforce.com

# Create records
sfbulk create-products --count 10
sfbulk create-opps --count 5000 --batch-size 10000
sfbulk create-lineitems --per-opp 3
sfbulk delete-opps --all
sfbulk delete-opps --created-after 2025-01-01
sfbulk status --job-id 750xx000000001AAA
```

---

## 7. Scalability Analysis

### Capacity by Org Type

| Org Type | Data Storage | Max Opps (est.) | Max Opps + 3 LI each |
|----------|-------------|-----------------|----------------------|
| Developer Edition | 5 MB | ~1,500 | ~500 |
| Developer Pro | 20 MB | ~6,000 | ~2,000 |
| Partner Developer | 120 MB | ~40,000 | ~13,000 |
| Sandbox (Full) | Matches prod | Depends | Depends |
| Production (EE) | 10 GB base | 3,000,000+ | 1,000,000+ |

### Throughput Comparison

| Metric | Apex Batch | Bulk API 2.0 |
|--------|-----------|-------------|
| Records per batch | 200 (recommended) | 10,000 (auto-chunked) |
| Effective throughput | ~1,000-5,000 records/min | ~5,000-50,000 records/min |
| Parallelism | 1 batch at a time per job | SF processes chunks in parallel |
| Max concurrent jobs | 5 | 5 |
| External tooling needed | No | Yes (Go client) |

### Scaling Strategies

#### 1. Horizontal: Increase Batch Count

```
Total records = batch_count x batch_size

Apex:     1,000 opps = 5 batches of 200
Bulk API: 50,000 opps = 5 batches of 10,000
```

#### 2. Vertical: Optimize Batch Size

Apex batch size sweet spot:
- **200** for complex records with many fields/triggers
- **500** for simple records with minimal automation
- **2,000** maximum (governor limit) for bare-minimum field records

Bulk API handles chunking internally. The 150 MB CSV limit is the practical ceiling.

#### 3. Org Scaling: When to Move Up

| Indicator | Action |
|-----------|--------|
| "STORAGE_LIMIT_EXCEEDED" errors | Upgrade to Partner Dev or Sandbox |
| API rate limit (15K/day) hit | Use Bulk API (counts as fewer API calls) |
| Batch queue full (5 concurrent) | Serialize jobs, add retry/wait logic |
| Need > 500K records | Full Sandbox or Production org |

#### 4. Performance Optimizations

- **Disable triggers/flows** during bulk load (Setup > Process Automation > Process Builder)
- **Disable validation rules** temporarily
- **Use `Database.insert(records, false)`** for partial success
- **Minimize field count** in bulk-generated records
- **Avoid workflow rules firing** on bulk-inserted records

### Bottleneck Analysis

```
Developer Edition - Priority-ordered bottlenecks:

1. DATA STORAGE (5 MB)          ← Primary constraint
   Mitigation: Reduce record count, upgrade org

2. API RATE LIMITS (15K/day)    ← Only affects Go Bulk API client
   Mitigation: Use Apex Batch instead, or batch operations efficiently

3. CONCURRENT JOB LIMIT (5)    ← Affects both approaches
   Mitigation: Serialize jobs, implement queue + wait logic

4. GOVERNOR LIMITS (DML rows)  ← Only affects Apex
   Mitigation: Keep batch size <= 200, use allOrNone=false

5. CPU TIME (60s async)        ← Only affects complex Apex logic
   Mitigation: Simplify record creation, reduce batch size
```

---

## 8. Runbook

### Prerequisites Checklist

- [ ] Salesforce Developer Edition org with admin access
- [ ] Developer Console accessible (Setup > Developer Console)
- [ ] Standard Price Book exists and is active
- [ ] (For Go CLI) Go 1.25+ installed
- [ ] (For Go CLI) Connected App created with OAuth credentials

### Phase 1: Verify Standard Price Book

In Developer Console, run this Anonymous Apex to verify:

```apex
Pricebook2 stdPb = [SELECT Id, Name, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
System.debug('Standard Pricebook: ' + stdPb.Name + ' (Id: ' + stdPb.Id + ', Active: ' + stdPb.IsActive + ')');
```

If `IsActive = false`, activate it:

```apex
Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
stdPb.IsActive = true;
update stdPb;
System.debug('Standard Pricebook activated');
```

### Phase 2: Create Products (Script 01)

1. Open Developer Console > Debug > Open Execute Anonymous Window
2. Paste contents of `apex/01_create_products.apex`
3. Adjust `NUM_PRODUCTS` at the top (default: 10)
4. Click **Execute**
5. Check debug log for success/failure count

### Phase 3: Create Opportunities (Script 02)

1. Paste contents of `apex/02_create_opportunities.apex`
2. Adjust `TOTAL_OPPORTUNITIES` and `BATCH_SIZE` at the top
3. Click **Execute** - this submits a batch job
4. Monitor: Setup > Apex Jobs (or query `AsyncApexJob`)
5. Wait for job status = "Completed"

### Phase 4: Create Line Items (Script 03)

1. **Wait for Phase 3 to complete** (Opportunities must exist)
2. Paste contents of `apex/03_create_lineitems.apex`
3. Adjust `LINE_ITEMS_PER_OPP` at the top (default: 3)
4. Click **Execute**
5. Monitor batch job completion

### Phase 5: Verify Data

```sql
SELECT COUNT() FROM Product2
SELECT COUNT() FROM PricebookEntry
SELECT COUNT() FROM Opportunity
SELECT COUNT() FROM OpportunityLineItem
```

### Phase 6: Delete (When Needed)

1. Paste contents of `apex/04_delete_opportunities.apex`
2. Choose deletion scope (all, by date, by name pattern)
3. Click **Execute**
4. Monitor batch job - LineItems are cascade-deleted with Opportunities

### Using the Go CLI (Alternative)

```bash
# Build
cd salesforce-bulk-ops
go build -o sfbulk ./cmd/sfbulk

# Configure
export SF_USERNAME="admin@mydevorg.com"
export SF_PASSWORD="MyPassword123"
export SF_SECURITY_TOKEN="XXXXXXXXXXXXX"
export SF_CLIENT_ID="3MVG9..."
export SF_CLIENT_SECRET="ABCDEF..."

# Execute
./sfbulk create-products --count 10
./sfbulk create-opps --count 1000
./sfbulk create-lineitems --per-opp 3
./sfbulk delete-opps --all
```

---

## 9. Troubleshooting

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `STORAGE_LIMIT_EXCEEDED` | Org data storage full | Delete records or upgrade org |
| `System.LimitException: Too many DML rows` | Batch size too large | Reduce `BATCH_SIZE` to 200 or less |
| `System.LimitException: Too many SOQL queries` | Too many queries in execute() | Consolidate queries, use collections |
| `UNABLE_TO_LOCK_ROW` | Concurrent DML on same records | Reduce parallelism, add retry |
| `INVALID_CROSS_REFERENCE_KEY` | Wrong PricebookEntry or Pricebook | Verify standard Pricebook is active |
| `REQUEST_LIMIT_EXCEEDED` | Daily API limit hit | Wait 24 hours, use Apex Batch instead |
| `FIELD_CUSTOM_VALIDATION_EXCEPTION` | Validation rule blocking insert | Temporarily deactivate validation rules |
| `Bulk API job state: Failed` | CSV format error or field mismatch | Check `failedResults` endpoint for details |

### Checking Org Storage

```
Setup > Company Information > Data Space / File Space
```

Or via API:
```
GET /services/data/v62.0/limits/
```

### Resetting Test Data

To delete ALL test data created by these scripts:

```apex
// Delete all opportunities (cascades to line items)
Database.executeBatch(new OpportunityDeletionBatch('ALL'), 200);

// Then delete products and pricebook entries
delete [SELECT Id FROM PricebookEntry WHERE Product2.Name LIKE 'BulkTest_%'];
delete [SELECT Id FROM Product2 WHERE Name LIKE 'BulkTest_%'];
```

All records created by these scripts use the `BulkTest_` prefix for easy
identification and cleanup.
