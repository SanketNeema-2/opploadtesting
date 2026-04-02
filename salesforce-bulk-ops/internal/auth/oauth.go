package auth

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// TokenResponse holds the OAuth token response from Salesforce.
type TokenResponse struct {
	AccessToken string `json:"access_token"`
	InstanceURL string `json:"instance_url"`
	ID          string `json:"id"`
	TokenType   string `json:"token_type"`
	IssuedAt    string `json:"issued_at"`
	Signature   string `json:"signature"`
}

// OAuthError is returned when authentication fails.
type OAuthError struct {
	Error       string `json:"error"`
	Description string `json:"error_description"`
}

// Client handles Salesforce OAuth authentication.
type Client struct {
	httpClient   *http.Client
	loginURL     string
	clientID     string
	clientSecret string
	username     string
	password     string // password + security token

	// Cached token
	token *TokenResponse
}

// NewClient creates a new OAuth client.
func NewClient(loginURL, clientID, clientSecret, username, password string) *Client {
	return &Client{
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		loginURL:     strings.TrimSuffix(loginURL, "/"),
		clientID:     clientID,
		clientSecret: clientSecret,
		username:     username,
		password:     password,
	}
}

// Authenticate performs the OAuth 2.0 Username-Password flow and caches the token.
func (c *Client) Authenticate() (*TokenResponse, error) {
	tokenURL := c.loginURL + "/services/oauth2/token"

	data := url.Values{
		"grant_type":    {"password"},
		"client_id":     {c.clientID},
		"client_secret": {c.clientSecret},
		"username":      {c.username},
		"password":      {c.password},
	}

	resp, err := c.httpClient.PostForm(tokenURL, data)
	if err != nil {
		return nil, fmt.Errorf("oauth request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading oauth response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		var oauthErr OAuthError
		if jsonErr := json.Unmarshal(body, &oauthErr); jsonErr == nil {
			return nil, fmt.Errorf("oauth error (%d): %s - %s", resp.StatusCode, oauthErr.Error, oauthErr.Description)
		}
		return nil, fmt.Errorf("oauth error (%d): %s", resp.StatusCode, string(body))
	}

	var token TokenResponse
	if err := json.Unmarshal(body, &token); err != nil {
		return nil, fmt.Errorf("parsing oauth response: %w", err)
	}

	c.token = &token
	return &token, nil
}

// Token returns the cached token, authenticating if necessary.
func (c *Client) Token() (*TokenResponse, error) {
	if c.token != nil {
		return c.token, nil
	}
	return c.Authenticate()
}

// AccessToken returns just the access token string.
func (c *Client) AccessToken() (string, error) {
	tok, err := c.Token()
	if err != nil {
		return "", err
	}
	return tok.AccessToken, nil
}

// InstanceURL returns the Salesforce instance URL.
func (c *Client) InstanceURL() (string, error) {
	tok, err := c.Token()
	if err != nil {
		return "", err
	}
	return tok.InstanceURL, nil
}

// Invalidate clears the cached token, forcing re-authentication on next call.
func (c *Client) Invalidate() {
	c.token = nil
}
