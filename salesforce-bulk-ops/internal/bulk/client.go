package bulk

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/sanketneema/salesforce-bulk-ops/internal/auth"
)

// Operation defines the Bulk API operation type.
type Operation string

const (
	OperationInsert     Operation = "insert"
	OperationUpdate     Operation = "update"
	OperationUpsert     Operation = "upsert"
	OperationDelete     Operation = "delete"
	OperationHardDelete Operation = "hardDelete"
)

// JobState represents the state of a Bulk API job.
type JobState string

const (
	JobStateOpen           JobState = "Open"
	JobStateUploadComplete JobState = "UploadComplete"
	JobStateInProgress     JobState = "InProgress"
	JobStateJobComplete    JobState = "JobComplete"
	JobStateFailed         JobState = "Failed"
	JobStateAborted        JobState = "Aborted"
)

// Job represents a Bulk API 2.0 ingest job.
type Job struct {
	ID                     string    `json:"id"`
	Operation              Operation `json:"operation"`
	Object                 string    `json:"object"`
	State                  JobState  `json:"state"`
	ContentType            string    `json:"contentType"`
	ExternalIDFieldName    string    `json:"externalIdFieldName,omitempty"`
	NumberRecordsProcessed int       `json:"numberRecordsProcessed"`
	NumberRecordsFailed    int       `json:"numberRecordsFailed"`
	ErrorMessage           string    `json:"errorMessage,omitempty"`
	TotalProcessingTime    int       `json:"totalProcessingTime"`
	APIActiveProcessTime   int       `json:"apiActiveProcessingTime"`
}

// CreateJobRequest is the request body for creating a new Bulk API job.
type CreateJobRequest struct {
	Operation           Operation `json:"operation"`
	Object              string    `json:"object"`
	ContentType         string    `json:"contentType"`
	ExternalIDFieldName string    `json:"externalIdFieldName,omitempty"`
	LineEnding          string    `json:"lineEnding,omitempty"`
}

// Client is the Salesforce Bulk API 2.0 client.
type Client struct {
	authClient *auth.Client
	httpClient *http.Client
	apiVersion string

	// Cached after first auth
	instanceURL string
	accessToken string
}

// NewClient creates a new Bulk API client.
func NewClient(authClient *auth.Client, apiVersion string) *Client {
	return &Client{
		authClient: authClient,
		httpClient: &http.Client{
			Timeout: 5 * time.Minute, // Bulk uploads can be large
		},
		apiVersion: apiVersion,
	}
}

// ensureAuth ensures we have valid auth credentials cached.
func (c *Client) ensureAuth() error {
	if c.accessToken != "" && c.instanceURL != "" {
		return nil
	}

	tok, err := c.authClient.Token()
	if err != nil {
		return fmt.Errorf("authenticating: %w", err)
	}

	c.accessToken = tok.AccessToken
	c.instanceURL = strings.TrimSuffix(tok.InstanceURL, "/")
	return nil
}

// baseURL returns the Bulk API 2.0 ingest base URL.
func (c *Client) baseURL() string {
	return fmt.Sprintf("%s/services/data/%s/jobs/ingest", c.instanceURL, c.apiVersion)
}

// doRequest performs an authenticated HTTP request.
func (c *Client) doRequest(method, url string, body io.Reader, contentType string) (*http.Response, error) {
	if err := c.ensureAuth(); err != nil {
		return nil, err
	}

	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+c.accessToken)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("executing request: %w", err)
	}

	// Handle 401 by re-authenticating once
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		c.authClient.Invalidate()
		c.accessToken = ""
		c.instanceURL = ""

		if err := c.ensureAuth(); err != nil {
			return nil, fmt.Errorf("re-authenticating: %w", err)
		}

		req.Header.Set("Authorization", "Bearer "+c.accessToken)
		return c.httpClient.Do(req)
	}

	return resp, nil
}

// CreateJob creates a new Bulk API 2.0 ingest job.
func (c *Client) CreateJob(object string, operation Operation) (*Job, error) {
	reqBody := CreateJobRequest{
		Operation:   operation,
		Object:      object,
		ContentType: "CSV",
		LineEnding:  "LF",
	}

	jsonBody, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshaling job request: %w", err)
	}

	resp, err := c.doRequest(http.MethodPost, c.baseURL(), bytes.NewReader(jsonBody), "application/json")
	if err != nil {
		return nil, fmt.Errorf("creating job: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	var job Job
	if err := json.NewDecoder(resp.Body).Decode(&job); err != nil {
		return nil, fmt.Errorf("decoding job response: %w", err)
	}

	return &job, nil
}

// UploadCSV uploads CSV data to an open job.
func (c *Client) UploadCSV(jobID string, csvData []byte) error {
	url := fmt.Sprintf("%s/%s/batches", c.baseURL(), jobID)

	resp, err := c.doRequest(http.MethodPut, url, bytes.NewReader(csvData), "text/csv")
	if err != nil {
		return fmt.Errorf("uploading CSV: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return readAPIError(resp)
	}

	return nil
}

// CloseJob marks a job as UploadComplete, triggering processing.
func (c *Client) CloseJob(jobID string) (*Job, error) {
	body := []byte(`{"state": "UploadComplete"}`)
	url := fmt.Sprintf("%s/%s", c.baseURL(), jobID)

	resp, err := c.doRequest(http.MethodPatch, url, bytes.NewReader(body), "application/json")
	if err != nil {
		return nil, fmt.Errorf("closing job: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	var job Job
	if err := json.NewDecoder(resp.Body).Decode(&job); err != nil {
		return nil, fmt.Errorf("decoding close response: %w", err)
	}

	return &job, nil
}

// GetJobStatus retrieves the current status of a job.
func (c *Client) GetJobStatus(jobID string) (*Job, error) {
	url := fmt.Sprintf("%s/%s", c.baseURL(), jobID)

	resp, err := c.doRequest(http.MethodGet, url, nil, "")
	if err != nil {
		return nil, fmt.Errorf("getting job status: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	var job Job
	if err := json.NewDecoder(resp.Body).Decode(&job); err != nil {
		return nil, fmt.Errorf("decoding job status: %w", err)
	}

	return &job, nil
}

// PollJobCompletion polls a job until it completes or fails.
func (c *Client) PollJobCompletion(jobID string, interval time.Duration, timeout time.Duration) (*Job, error) {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		job, err := c.GetJobStatus(jobID)
		if err != nil {
			return nil, err
		}

		switch job.State {
		case JobStateJobComplete:
			return job, nil
		case JobStateFailed:
			return job, fmt.Errorf("job failed: %s", job.ErrorMessage)
		case JobStateAborted:
			return job, fmt.Errorf("job was aborted")
		}

		fmt.Printf("  Job %s: state=%s, processed=%d, failed=%d\n",
			jobID, job.State, job.NumberRecordsProcessed, job.NumberRecordsFailed)

		time.Sleep(interval)
	}

	return nil, fmt.Errorf("job %s did not complete within %v", jobID, timeout)
}

// GetSuccessfulResults retrieves the CSV of successful results.
func (c *Client) GetSuccessfulResults(jobID string) ([]byte, error) {
	url := fmt.Sprintf("%s/%s/successfulResults", c.baseURL(), jobID)

	resp, err := c.doRequest(http.MethodGet, url, nil, "")
	if err != nil {
		return nil, fmt.Errorf("getting successful results: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	return io.ReadAll(resp.Body)
}

// GetFailedResults retrieves the CSV of failed results.
func (c *Client) GetFailedResults(jobID string) ([]byte, error) {
	url := fmt.Sprintf("%s/%s/failedResults", c.baseURL(), jobID)

	resp, err := c.doRequest(http.MethodGet, url, nil, "")
	if err != nil {
		return nil, fmt.Errorf("getting failed results: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	return io.ReadAll(resp.Body)
}

// AbortJob aborts a running job.
func (c *Client) AbortJob(jobID string) (*Job, error) {
	body := []byte(`{"state": "Aborted"}`)
	url := fmt.Sprintf("%s/%s", c.baseURL(), jobID)

	resp, err := c.doRequest(http.MethodPatch, url, bytes.NewReader(body), "application/json")
	if err != nil {
		return nil, fmt.Errorf("aborting job: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	var job Job
	if err := json.NewDecoder(resp.Body).Decode(&job); err != nil {
		return nil, fmt.Errorf("decoding abort response: %w", err)
	}

	return &job, nil
}

// QuerySOQL executes a SOQL query and returns the raw JSON response.
func (c *Client) QuerySOQL(query string) ([]byte, error) {
	if err := c.ensureAuth(); err != nil {
		return nil, err
	}

	url := fmt.Sprintf("%s/services/data/%s/query?q=%s",
		c.instanceURL, c.apiVersion, strings.ReplaceAll(query, " ", "+"))

	resp, err := c.doRequest(http.MethodGet, url, nil, "")
	if err != nil {
		return nil, fmt.Errorf("executing SOQL query: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, readAPIError(resp)
	}

	return io.ReadAll(resp.Body)
}

// APIError represents a Salesforce API error response.
type APIError struct {
	StatusCode int
	Body       string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("salesforce API error (%d): %s", e.StatusCode, e.Body)
}

func readAPIError(resp *http.Response) error {
	body, _ := io.ReadAll(resp.Body)
	return &APIError{
		StatusCode: resp.StatusCode,
		Body:       string(body),
	}
}
