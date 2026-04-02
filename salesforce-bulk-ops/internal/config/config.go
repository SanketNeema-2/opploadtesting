package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
)

// Config holds all Salesforce connection and operation parameters.
type Config struct {
	// Salesforce OAuth credentials
	Username     string
	Password     string // Password + Security Token concatenated
	ClientID     string // Connected App Consumer Key
	ClientSecret string // Connected App Consumer Secret
	LoginURL     string // https://login.salesforce.com or https://test.salesforce.com

	// API version
	APIVersion string

	// Operation parameters
	ProductCount    int
	OppCount        int
	LineItemsPerOpp int
	BatchSize       int
}

// DefaultConfig returns a Config populated from environment variables with sensible defaults.
func DefaultConfig() *Config {
	return &Config{
		Username:     os.Getenv("SF_USERNAME"),
		Password:     os.Getenv("SF_PASSWORD") + os.Getenv("SF_SECURITY_TOKEN"),
		ClientID:     os.Getenv("SF_CLIENT_ID"),
		ClientSecret: os.Getenv("SF_CLIENT_SECRET"),
		LoginURL:     envOrDefault("SF_LOGIN_URL", "https://login.salesforce.com"),
		APIVersion:   envOrDefault("SF_API_VERSION", "v62.0"),

		ProductCount:    envIntOrDefault("SF_PRODUCT_COUNT", 10),
		OppCount:        envIntOrDefault("SF_OPP_COUNT", 500),
		LineItemsPerOpp: envIntOrDefault("SF_LINEITEMS_PER_OPP", 3),
		BatchSize:       envIntOrDefault("SF_BATCH_SIZE", 10000),
	}
}

// Validate checks that all required configuration fields are set.
func (c *Config) Validate() error {
	var errs []error

	if c.Username == "" {
		errs = append(errs, fmt.Errorf("SF_USERNAME is required"))
	}
	if c.Password == "" {
		errs = append(errs, fmt.Errorf("SF_PASSWORD is required (SF_SECURITY_TOKEN is also used if set)"))
	}
	if c.ClientID == "" {
		errs = append(errs, fmt.Errorf("SF_CLIENT_ID is required (Connected App Consumer Key)"))
	}
	if c.ClientSecret == "" {
		errs = append(errs, fmt.Errorf("SF_CLIENT_SECRET is required (Connected App Consumer Secret)"))
	}
	if c.LoginURL == "" {
		errs = append(errs, fmt.Errorf("SF_LOGIN_URL is required"))
	}
	if c.BatchSize < 1 || c.BatchSize > 10000000 {
		errs = append(errs, fmt.Errorf("batch size must be between 1 and 10,000,000 (got %d)", c.BatchSize))
	}

	return errors.Join(errs...)
}

func envOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func envIntOrDefault(key string, defaultVal int) int {
	v := os.Getenv(key)
	if v == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return defaultVal
	}
	return n
}
