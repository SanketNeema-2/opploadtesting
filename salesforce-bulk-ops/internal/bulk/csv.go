package bulk

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"math"
	"strconv"
	"time"
)

// CSVGenerator handles generating CSV data for Bulk API uploads.
type CSVGenerator struct{}

// NewCSVGenerator creates a new CSV generator.
func NewCSVGenerator() *CSVGenerator {
	return &CSVGenerator{}
}

// GenerateProductCSV generates CSV data for Product2 records.
func (g *CSVGenerator) GenerateProductCSV(count int) ([]byte, error) {
	var buf bytes.Buffer
	w := csv.NewWriter(&buf)

	// Header
	if err := w.Write([]string{"Name", "ProductCode", "Description", "IsActive"}); err != nil {
		return nil, fmt.Errorf("writing CSV header: %w", err)
	}

	for i := 1; i <= count; i++ {
		record := []string{
			fmt.Sprintf("BulkTest_Product_%04d", i),
			fmt.Sprintf("BT-%04d", i),
			fmt.Sprintf("Bulk test product #%d created via Go Bulk API client", i),
			"true",
		}
		if err := w.Write(record); err != nil {
			return nil, fmt.Errorf("writing CSV record %d: %w", i, err)
		}
	}

	w.Flush()
	if err := w.Error(); err != nil {
		return nil, fmt.Errorf("flushing CSV: %w", err)
	}

	return buf.Bytes(), nil
}

// GenerateOpportunityCSV generates CSV data for Opportunity records.
func (g *CSVGenerator) GenerateOpportunityCSV(count int) ([]byte, error) {
	var buf bytes.Buffer
	w := csv.NewWriter(&buf)

	stageNames := []string{
		"Prospecting", "Qualification", "Needs Analysis",
		"Value Proposition", "Perception Analysis",
		"Proposal/Price Quote", "Negotiation/Review",
		"Closed Won", "Closed Lost",
	}

	leadSources := []string{
		"Web", "Phone Inquiry", "Partner Referral",
		"Purchased List", "Other",
	}

	types := []string{
		"Existing Customer - Upgrade", "Existing Customer - Replacement",
		"Existing Customer - Downgrade", "New Customer",
	}

	// Header
	if err := w.Write([]string{
		"Name", "StageName", "CloseDate", "Amount",
		"Probability", "LeadSource", "Type", "Description",
	}); err != nil {
		return nil, fmt.Errorf("writing CSV header: %w", err)
	}

	baseDate := time.Now()
	for i := 1; i <= count; i++ {
		stageIdx := i % len(stageNames)
		sourceIdx := i % len(leadSources)
		typeIdx := i % len(types)

		daysOffset := (i * 7) % 365
		closeDate := baseDate.AddDate(0, 0, daysOffset).Format("2006-01-02")

		amount := 1000 + (i*1337)%499000
		probability := (i * 13) % 101

		record := []string{
			fmt.Sprintf("BulkTest_Opp_%06d", i),
			stageNames[stageIdx],
			closeDate,
			strconv.Itoa(amount),
			strconv.Itoa(probability),
			leadSources[sourceIdx],
			types[typeIdx],
			fmt.Sprintf("Bulk test opportunity #%d created via Go Bulk API client", i),
		}
		if err := w.Write(record); err != nil {
			return nil, fmt.Errorf("writing CSV record %d: %w", i, err)
		}
	}

	w.Flush()
	if err := w.Error(); err != nil {
		return nil, fmt.Errorf("flushing CSV: %w", err)
	}

	return buf.Bytes(), nil
}

// GenerateLineItemCSV generates CSV data for OpportunityLineItem records.
// oppIDs are the Salesforce IDs of Opportunities to create line items for.
// pbeIDs are the PricebookEntry IDs to reference.
// perOpp is the number of line items per opportunity.
func (g *CSVGenerator) GenerateLineItemCSV(oppIDs []string, pbeIDs []string, pbeUnitPrices []float64, perOpp int) ([]byte, error) {
	if len(pbeIDs) == 0 {
		return nil, fmt.Errorf("no PricebookEntry IDs provided")
	}
	if len(oppIDs) == 0 {
		return nil, fmt.Errorf("no Opportunity IDs provided")
	}

	var buf bytes.Buffer
	w := csv.NewWriter(&buf)

	// Header
	if err := w.Write([]string{
		"OpportunityId", "PricebookEntryId", "Quantity", "UnitPrice", "Description",
	}); err != nil {
		return nil, fmt.Errorf("writing CSV header: %w", err)
	}

	for oppIdx, oppID := range oppIDs {
		for i := 0; i < perOpp; i++ {
			pbeIdx := i % len(pbeIDs)
			quantity := 1 + (i*3+oppIdx)%20
			unitPrice := pbeUnitPrices[pbeIdx]

			record := []string{
				oppID,
				pbeIDs[pbeIdx],
				strconv.Itoa(quantity),
				strconv.FormatFloat(unitPrice, 'f', 2, 64),
				fmt.Sprintf("BulkTest LineItem #%d for opp %s", i+1, oppID),
			}
			if err := w.Write(record); err != nil {
				return nil, fmt.Errorf("writing CSV record: %w", err)
			}
		}
	}

	w.Flush()
	if err := w.Error(); err != nil {
		return nil, fmt.Errorf("flushing CSV: %w", err)
	}

	return buf.Bytes(), nil
}

// GenerateDeleteCSV generates CSV data for delete operations (just IDs).
func (g *CSVGenerator) GenerateDeleteCSV(ids []string) ([]byte, error) {
	var buf bytes.Buffer
	w := csv.NewWriter(&buf)

	// Header
	if err := w.Write([]string{"Id"}); err != nil {
		return nil, fmt.Errorf("writing CSV header: %w", err)
	}

	for _, id := range ids {
		if err := w.Write([]string{id}); err != nil {
			return nil, fmt.Errorf("writing CSV record: %w", err)
		}
	}

	w.Flush()
	if err := w.Error(); err != nil {
		return nil, fmt.Errorf("flushing CSV: %w", err)
	}

	return buf.Bytes(), nil
}

// ChunkCSV splits CSV data into chunks of maxRecords each.
// Each chunk includes the header row.
func ChunkCSV(csvData []byte, maxRecords int) ([][]byte, error) {
	reader := csv.NewReader(bytes.NewReader(csvData))
	records, err := reader.ReadAll()
	if err != nil {
		return nil, fmt.Errorf("reading CSV: %w", err)
	}

	if len(records) < 2 {
		return [][]byte{csvData}, nil // Only header or empty
	}

	header := records[0]
	dataRows := records[1:]
	numChunks := int(math.Ceil(float64(len(dataRows)) / float64(maxRecords)))
	chunks := make([][]byte, 0, numChunks)

	for i := 0; i < len(dataRows); i += maxRecords {
		end := i + maxRecords
		if end > len(dataRows) {
			end = len(dataRows)
		}

		var buf bytes.Buffer
		w := csv.NewWriter(&buf)

		if err := w.Write(header); err != nil {
			return nil, fmt.Errorf("writing chunk header: %w", err)
		}

		for _, row := range dataRows[i:end] {
			if err := w.Write(row); err != nil {
				return nil, fmt.Errorf("writing chunk row: %w", err)
			}
		}

		w.Flush()
		if err := w.Error(); err != nil {
			return nil, fmt.Errorf("flushing chunk: %w", err)
		}

		chunks = append(chunks, buf.Bytes())
	}

	return chunks, nil
}
