package bulk

import (
	"bufio"
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// JobRunner orchestrates multi-step Bulk API operations.
type JobRunner struct {
	client    *Client
	csvGen    *CSVGenerator
	batchSize int
}

// NewJobRunner creates a new job runner.
func NewJobRunner(client *Client, batchSize int) *JobRunner {
	return &JobRunner{
		client:    client,
		csvGen:    NewCSVGenerator(),
		batchSize: batchSize,
	}
}

// RunCreateProducts creates Product2 records via Bulk API.
func (r *JobRunner) RunCreateProducts(count int) (*Job, error) {
	fmt.Printf("Generating CSV for %d products...\n", count)
	csvData, err := r.csvGen.GenerateProductCSV(count)
	if err != nil {
		return nil, fmt.Errorf("generating product CSV: %w", err)
	}

	return r.submitJob("Product2", OperationInsert, csvData)
}

// RunCreateOpportunities creates Opportunity records via Bulk API.
// Returns the completed job (use GetSuccessfulResults to get created IDs).
func (r *JobRunner) RunCreateOpportunities(count int) (*Job, error) {
	fmt.Printf("Generating CSV for %d opportunities...\n", count)
	csvData, err := r.csvGen.GenerateOpportunityCSV(count)
	if err != nil {
		return nil, fmt.Errorf("generating opportunity CSV: %w", err)
	}

	return r.submitJob("Opportunity", OperationInsert, csvData)
}

// RunCreateLineItems creates OpportunityLineItem records via Bulk API.
// It queries for existing Opportunity and PricebookEntry IDs first.
func (r *JobRunner) RunCreateLineItems(perOpp int) (*Job, error) {
	// Step 1: Query Opportunity IDs
	fmt.Println("Querying Opportunity IDs...")
	oppIDs, err := r.queryIDs("SELECT Id FROM Opportunity WHERE Name LIKE 'BulkTest_Opp_%' ORDER BY Name")
	if err != nil {
		return nil, fmt.Errorf("querying opportunity IDs: %w", err)
	}
	if len(oppIDs) == 0 {
		return nil, fmt.Errorf("no BulkTest opportunities found; run create-opps first")
	}
	fmt.Printf("Found %d opportunities\n", len(oppIDs))

	// Step 2: Query PricebookEntry IDs and prices
	fmt.Println("Querying PricebookEntry IDs...")
	pbeIDs, pbeUnitPrices, err := r.queryPricebookEntries()
	if err != nil {
		return nil, fmt.Errorf("querying pricebook entries: %w", err)
	}
	if len(pbeIDs) == 0 {
		return nil, fmt.Errorf("no BulkTest pricebook entries found; run create-products first")
	}
	fmt.Printf("Found %d pricebook entries\n", len(pbeIDs))

	// Step 3: Generate and submit CSV
	totalItems := len(oppIDs) * perOpp
	fmt.Printf("Generating CSV for %d line items (%d opps x %d per opp)...\n",
		totalItems, len(oppIDs), perOpp)

	csvData, err := r.csvGen.GenerateLineItemCSV(oppIDs, pbeIDs, pbeUnitPrices, perOpp)
	if err != nil {
		return nil, fmt.Errorf("generating line item CSV: %w", err)
	}

	return r.submitJob("OpportunityLineItem", OperationInsert, csvData)
}

// RunDeleteOpportunities deletes all BulkTest opportunities via Bulk API.
func (r *JobRunner) RunDeleteOpportunities(hardDelete bool) (*Job, error) {
	fmt.Println("Querying Opportunity IDs for deletion...")
	oppIDs, err := r.queryIDs("SELECT Id FROM Opportunity WHERE Name LIKE 'BulkTest_Opp_%'")
	if err != nil {
		return nil, fmt.Errorf("querying opportunity IDs: %w", err)
	}
	if len(oppIDs) == 0 {
		fmt.Println("No BulkTest opportunities found to delete.")
		return nil, nil
	}
	fmt.Printf("Found %d opportunities to delete\n", len(oppIDs))

	csvData, err := r.csvGen.GenerateDeleteCSV(oppIDs)
	if err != nil {
		return nil, fmt.Errorf("generating delete CSV: %w", err)
	}

	op := OperationDelete
	if hardDelete {
		op = OperationHardDelete
	}

	return r.submitJob("Opportunity", op, csvData)
}

// GetJobStatus returns the current status of a job.
func (r *JobRunner) GetJobStatus(jobID string) (*Job, error) {
	return r.client.GetJobStatus(jobID)
}

// submitJob handles the full lifecycle: create job, upload CSV (chunked), close, poll.
func (r *JobRunner) submitJob(object string, operation Operation, csvData []byte) (*Job, error) {
	// Chunk CSV if necessary
	chunks, err := ChunkCSV(csvData, r.batchSize)
	if err != nil {
		return nil, fmt.Errorf("chunking CSV: %w", err)
	}

	fmt.Printf("Creating %s %s job (%d chunk(s))...\n", object, operation, len(chunks))

	// Create job
	job, err := r.client.CreateJob(object, operation)
	if err != nil {
		return nil, fmt.Errorf("creating job: %w", err)
	}
	fmt.Printf("Job created: %s (state: %s)\n", job.ID, job.State)

	// Upload each chunk
	for i, chunk := range chunks {
		fmt.Printf("Uploading chunk %d/%d (%d bytes)...\n", i+1, len(chunks), len(chunk))
		if err := r.client.UploadCSV(job.ID, chunk); err != nil {
			// Try to abort the job on upload failure
			_, _ = r.client.AbortJob(job.ID)
			return nil, fmt.Errorf("uploading chunk %d: %w", i+1, err)
		}
	}

	// Close job to start processing
	fmt.Println("Closing job to start processing...")
	job, err = r.client.CloseJob(job.ID)
	if err != nil {
		return nil, fmt.Errorf("closing job: %w", err)
	}

	// Poll for completion
	fmt.Println("Polling for completion...")
	job, err = r.client.PollJobCompletion(job.ID, 5*time.Second, 30*time.Minute)
	if err != nil {
		return nil, fmt.Errorf("polling job: %w", err)
	}

	fmt.Printf("\nJob complete: %s\n", job.ID)
	fmt.Printf("  Records processed: %d\n", job.NumberRecordsProcessed)
	fmt.Printf("  Records failed:    %d\n", job.NumberRecordsFailed)
	fmt.Printf("  Processing time:   %d ms\n", job.TotalProcessingTime)

	// Show failed results if any
	if job.NumberRecordsFailed > 0 {
		failedCSV, err := r.client.GetFailedResults(job.ID)
		if err != nil {
			fmt.Printf("  Warning: could not retrieve failed results: %v\n", err)
		} else {
			fmt.Printf("  Failed results:\n%s\n", string(failedCSV))
		}
	}

	return job, nil
}

// SOQLQueryResult represents the JSON response from a SOQL query.
type SOQLQueryResult struct {
	TotalSize int              `json:"totalSize"`
	Done      bool             `json:"done"`
	Records   []map[string]any `json:"records"`
}

// queryIDs executes a SOQL query and extracts the Id field from all results.
func (r *JobRunner) queryIDs(soql string) ([]string, error) {
	body, err := r.client.QuerySOQL(soql)
	if err != nil {
		return nil, err
	}

	var result SOQLQueryResult
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parsing query result: %w", err)
	}

	ids := make([]string, 0, result.TotalSize)
	for _, record := range result.Records {
		if id, ok := record["Id"].(string); ok {
			ids = append(ids, id)
		}
	}

	return ids, nil
}

// queryPricebookEntries queries PricebookEntry IDs and their UnitPrices.
func (r *JobRunner) queryPricebookEntries() ([]string, []float64, error) {
	soql := "SELECT Id, UnitPrice FROM PricebookEntry WHERE Pricebook2.IsStandard = true AND IsActive = true AND Product2.Name LIKE 'BulkTest_%'"
	body, err := r.client.QuerySOQL(soql)
	if err != nil {
		return nil, nil, err
	}

	var result SOQLQueryResult
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, nil, fmt.Errorf("parsing query result: %w", err)
	}

	ids := make([]string, 0, result.TotalSize)
	prices := make([]float64, 0, result.TotalSize)

	for _, record := range result.Records {
		if id, ok := record["Id"].(string); ok {
			ids = append(ids, id)
		}
		if price, ok := record["UnitPrice"].(float64); ok {
			prices = append(prices, price)
		}
	}

	return ids, prices, nil
}

// ParseSuccessIDs parses the successful results CSV and extracts the sf__Id column.
func ParseSuccessIDs(csvData []byte) ([]string, error) {
	reader := csv.NewReader(bytes.NewReader(csvData))
	records, err := reader.ReadAll()
	if err != nil {
		return nil, fmt.Errorf("parsing success CSV: %w", err)
	}

	if len(records) < 1 {
		return nil, nil
	}

	// Find the sf__Id column index
	header := records[0]
	idIdx := -1
	for i, col := range header {
		if strings.EqualFold(col, "sf__Id") {
			idIdx = i
			break
		}
	}

	if idIdx == -1 {
		return nil, fmt.Errorf("sf__Id column not found in success results")
	}

	ids := make([]string, 0, len(records)-1)
	for _, row := range records[1:] {
		if idIdx < len(row) && row[idIdx] != "" {
			ids = append(ids, row[idIdx])
		}
	}

	return ids, nil
}

// CountCSVRows counts the number of data rows in a CSV (excluding header).
func CountCSVRows(csvData []byte) int {
	scanner := bufio.NewScanner(bytes.NewReader(csvData))
	count := 0
	for scanner.Scan() {
		count++
	}
	if count > 0 {
		count-- // Subtract header
	}
	return count
}
