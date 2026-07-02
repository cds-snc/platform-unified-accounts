// Lambda function that deactivates inactive Zitadel users.
//
// For every active user in the Zitadel instance, the function looks up the
// timestamp of the most recent `user.human.password.check.succeeded` event.
// If that timestamp — or the user's creation date when no such event has ever
// occurred — is older than INACTIVE_DAYS, the user is deactivated via the
// Zitadel User v2 API.
//
// Required environment variables:
//
//	ZITADEL_URL            - Base URL of the Zitadel instance
//	ZITADEL_TOKEN_SSM_PATH - SSM Parameter Store path for the Zitadel Bearer token
//	ZITADEL_HOST           - Host header value for Zitadel API requests
//	INACTIVE_DAYS          - Users idle longer than this are deactivated
//
// Optional environment variables:
//
//	DRY_RUN    - When "true", report what would be deactivated without making changes (default: false)
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

const (
	passwordCheckSucceededEventType = "user.human.password.check.succeeded"
	userStateActive                 = "USER_STATE_ACTIVE"
	defaultPageLimit                = 100
)

// ---------------------------------------------------------------------------
// Module-level configuration (read once at cold start)
// ---------------------------------------------------------------------------

var (
	zitadelURL          string
	zitadelTokenSSMPath string
	zitadelHost         string
	inactiveDays        int
	pageLimit           int
	dryRun              bool
)

var (
	ssmClient *ssm.Client
	initErr   error
)

var (
	tokenMu     sync.Mutex
	cachedToken string
)

func init() {
	var missing []string
	zitadelURL = os.Getenv("ZITADEL_URL")
	if zitadelURL == "" {
		missing = append(missing, "ZITADEL_URL")
	}
	zitadelTokenSSMPath = os.Getenv("ZITADEL_TOKEN_SSM_PATH")
	if zitadelTokenSSMPath == "" {
		missing = append(missing, "ZITADEL_TOKEN_SSM_PATH")
	}
	zitadelHost = os.Getenv("ZITADEL_HOST")
	if zitadelHost == "" {
		missing = append(missing, "ZITADEL_HOST")
	}
	if os.Getenv("INACTIVE_DAYS") == "" {
		missing = append(missing, "INACTIVE_DAYS")
	}
	if len(missing) > 0 {
		initErr = fmt.Errorf("required environment variables not set: %s", strings.Join(missing, ", "))
		return
	}

	id, err := parseInactiveDays()
	if err != nil {
		initErr = err
		return
	}
	inactiveDays = id

	pl, err := parsePageLimit()
	if err != nil {
		initErr = err
		return
	}
	pageLimit = pl

	dr, err := parseDryRun()
	if err != nil {
		initErr = err
		return
	}
	dryRun = dr

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		initErr = fmt.Errorf("loading AWS config: %w", err)
		return
	}
	ssmClient = ssm.NewFromConfig(cfg)
}

func parseInactiveDays() (int, error) {
	v := os.Getenv("INACTIVE_DAYS")
	i, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("INACTIVE_DAYS must be an integer, got %q", v)
	}
	if i <= 0 {
		return 0, fmt.Errorf("INACTIVE_DAYS must be greater than 0, got %d", i)
	}
	return i, nil
}

func parsePageLimit() (int, error) {
	v := os.Getenv("PAGE_LIMIT")
	if v == "" {
		return defaultPageLimit, nil
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("PAGE_LIMIT must be an integer, got %q", v)
	}
	if i <= 0 || i > 1000 {
		return 0, fmt.Errorf("PAGE_LIMIT must be between 1 and 1000, got %d", i)
	}
	return i, nil
}

func parseDryRun() (bool, error) {
	v := os.Getenv("DRY_RUN")
	if v == "" {
		return false, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return false, fmt.Errorf("DRY_RUN must be a boolean, got %q", v)
	}
	return b, nil
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

// formatTimestamp matches the precision the Zitadel API expects.
func formatTimestamp(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000Z")
}

// parseZitadelTime parses an RFC 3339 timestamp returned by Zitadel. The API
// is inconsistent about fractional-second precision so we try a few layouts.
func parseZitadelTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, fmt.Errorf("empty timestamp")
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t.UTC(), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("parsing timestamp %q", s)
}

// ---------------------------------------------------------------------------
// SSM
// ---------------------------------------------------------------------------

func loadBearerToken(ctx context.Context) (string, error) {
	tokenMu.Lock()
	defer tokenMu.Unlock()
	if cachedToken != "" {
		log.Println("Using cached Bearer token")
		return cachedToken, nil
	}
	log.Printf("Loading Bearer token from SSM: %s", zitadelTokenSSMPath)
	out, err := ssmClient.GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(zitadelTokenSSMPath),
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return "", fmt.Errorf("getting SSM parameter: %w", err)
	}
	cachedToken = aws.ToString(out.Parameter.Value)
	log.Println("Bearer token loaded successfully from SSM")
	return cachedToken, nil
}

// ---------------------------------------------------------------------------
// Zitadel API types
// ---------------------------------------------------------------------------

type user struct {
	UserID   string `json:"userId"`
	Username string `json:"username"`
	State    string `json:"state"`
	Details  struct {
		CreationDate string `json:"creationDate"`
	} `json:"details"`
}

type listUsersRequest struct {
	Query   listUsersPageQuery `json:"query"`
	Queries []any              `json:"queries"`
}

type listUsersPageQuery struct {
	Offset string `json:"offset"`
	Limit  int    `json:"limit"`
	Asc    bool   `json:"asc"`
}

type listUsersResponse struct {
	Details struct {
		TotalResult string `json:"totalResult"`
	} `json:"details"`
	Result []user `json:"result"`
}

type listEventsRequest struct {
	AggregateID string   `json:"aggregateId"`
	EventTypes  []string `json:"eventTypes"`
	Asc         bool     `json:"asc"`
	Limit       int      `json:"limit"`
}

type event struct {
	CreationDate string `json:"creationDate"`
}

type listEventsResponse struct {
	Events []event `json:"events"`
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

// doJSONRequest performs a JSON POST to the Zitadel API. If body is nil the
// request is sent without a payload. If out is nil the response body is
// discarded.
func doJSONRequest(ctx context.Context, client *http.Client, baseURL, path, token string, body, out any) error {
	url := strings.TrimRight(baseURL, "/") + path

	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshalling request body: %w", err)
		}
		reader = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, reader)
	if err != nil {
		return fmt.Errorf("building request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if zitadelHost != "" {
		req.Host = zitadelHost
	}

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("executing request: %w", err)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading response body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d from %s: %s", resp.StatusCode, path, respBytes)
	}

	if out != nil && len(respBytes) > 0 {
		if err := json.Unmarshal(respBytes, out); err != nil {
			return fmt.Errorf("parsing response: %w", err)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Zitadel operations
// ---------------------------------------------------------------------------

// listActiveUsers fetches every human user in state USER_STATE_ACTIVE, paging
// through the result set until fewer than `limit` records are returned.
func listActiveUsers(ctx context.Context, client *http.Client, baseURL, token string, limit int) ([]user, error) {
	var all []user
	offset := 0
	for {
		req := listUsersRequest{
			Query: listUsersPageQuery{
				Offset: strconv.Itoa(offset),
				Limit:  limit,
				Asc:    true,
			},
			Queries: []any{
				map[string]any{"stateQuery": map[string]any{"state": "USER_STATE_ACTIVE"}},
				map[string]any{"typeQuery": map[string]any{"type": "TYPE_HUMAN"}},
			},
		}
		var resp listUsersResponse
		log.Printf("Listing active users offset=%d limit=%d", offset, limit)
		if err := doJSONRequest(ctx, client, baseURL, "/v2/users", token, req, &resp); err != nil {
			return nil, fmt.Errorf("listing users: %w", err)
		}
		all = append(all, resp.Result...)
		if len(resp.Result) < limit {
			break
		}
		offset += len(resp.Result)
	}
	log.Printf("Fetched %d active user(s)", len(all))
	return all, nil
}

// lastPasswordCheckSucceeded returns the timestamp of the most recent
// `user.human.password.check.succeeded` event for the given user. The second return value is
// false when no such event exists. This event is being used as a proxy for user activity since it is consistenly
// emitted when a user logs into Zitadel or a Relying Party.
func lastPasswordCheckSucceeded(ctx context.Context, client *http.Client, baseURL, token, userID string) (time.Time, bool, error) {
	req := listEventsRequest{
		AggregateID: userID,
		EventTypes:  []string{passwordCheckSucceededEventType},
		Asc:         false,
		Limit:       1,
	}
	var resp listEventsResponse
	if err := doJSONRequest(ctx, client, baseURL, "/admin/v1/events/_search", token, req, &resp); err != nil {
		return time.Time{}, false, fmt.Errorf("listing events for user %s: %w", userID, err)
	}
	if len(resp.Events) == 0 {
		log.Printf("No events found for %s", userID)
		return time.Time{}, false, nil
	}
	t, err := parseZitadelTime(resp.Events[0].CreationDate)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("user %s: %w", userID, err)
	}
	return t, true, nil
}

func deactivateUser(ctx context.Context, client *http.Client, baseURL, token, userID string) error {
	path := "/v2/users/" + userID + "/deactivate"
	if err := doJSONRequest(ctx, client, baseURL, path, token, nil, nil); err != nil {
		return fmt.Errorf("deactivating user %s: %w", userID, err)
	}
	return nil
}

// lastActivity returns the user's last activity timestamp. It uses the most
// recent `user.human.password.check.succeeded` event when present, otherwise falls back to
// the user's creation date so accounts that have never logged in are still eligible for deactivation.
func lastActivity(ctx context.Context, client *http.Client, baseURL, token string, u user) (time.Time, string, error) {
	t, found, err := lastPasswordCheckSucceeded(ctx, client, baseURL, token, u.UserID)
	if err != nil {
		return time.Time{}, "", err
	}
	if found {
		return t, "password_check", nil
	}
	created, err := parseZitadelTime(u.Details.CreationDate)
	if err != nil {
		return time.Time{}, "", fmt.Errorf("user %s has no password check events and unparseable creation date: %w", u.UserID, err)
	}
	return created, "creation", nil
}

// ---------------------------------------------------------------------------
// Lambda entry point
// ---------------------------------------------------------------------------

type response struct {
	StatusCode       int      `json:"statusCode"`
	UsersChecked     int      `json:"users_checked"`
	UsersDeactivated int      `json:"users_deactivated"`
	UsersSkipped     int      `json:"users_skipped"`
	DeactivatedUsers []string `json:"deactivated_users,omitempty"`
	InactiveDays     int      `json:"inactive_days"`
	DryRun           bool     `json:"dry_run"`
	Threshold        string   `json:"threshold"`
}

func processUsers(ctx context.Context, client *http.Client, baseURL, token string, users []user, now time.Time, threshold time.Time, dryRun bool) (response, error) {
	resp := response{
		StatusCode:   200,
		UsersChecked: len(users),
		InactiveDays: inactiveDays,
		DryRun:       dryRun,
		Threshold:    threshold.Format(time.RFC3339),
	}

	for _, u := range users {
		activity, source, err := lastActivity(ctx, client, baseURL, token, u)
		if err != nil {
			log.Printf("Skipping user %s (%s): %v", u.UserID, u.Username, err)
			resp.UsersSkipped++
			continue
		}
		if !activity.Before(threshold) {
			log.Printf("Keeping user %s (%s): last activity %s (%s) is within window",
				u.UserID, u.Username, activity.Format(time.RFC3339), source)
			continue
		}
		log.Printf("Deactivating user %s (%s): last activity %s (%s) is older than %s",
			u.UserID, u.Username, activity.Format(time.RFC3339), source, threshold.Format(time.RFC3339))
		if !dryRun {
			if err := deactivateUser(ctx, client, baseURL, token, u.UserID); err != nil {
				log.Printf("Failed to deactivate user %s (%s): %v", u.UserID, u.Username, err)
				resp.UsersSkipped++
				continue
			}
		}
		resp.UsersDeactivated++
		resp.DeactivatedUsers = append(resp.DeactivatedUsers, u.Username)
	}
	return resp, nil
}

func handler(ctx context.Context) (response, error) {
	if initErr != nil {
		return response{}, initErr
	}

	now := time.Now().UTC()
	threshold := now.AddDate(0, 0, -inactiveDays)
	log.Printf("Starting inactive user sweep: inactive_days=%d threshold=%s dry_run=%t",
		inactiveDays, threshold.Format(time.RFC3339), dryRun)

	token, err := loadBearerToken(ctx)
	if err != nil {
		return response{}, fmt.Errorf("loading bearer token: %w", err)
	}

	users, err := listActiveUsers(ctx, http.DefaultClient, zitadelURL, token, pageLimit)
	if err != nil {
		return response{}, fmt.Errorf("listing active users: %w", err)
	}

	result, err := processUsers(ctx, http.DefaultClient, zitadelURL, token, users, now, threshold, dryRun)
	if err != nil {
		return response{}, err
	}
	log.Printf("User deactivate finished: checked=%d deactivated=%d skipped=%d dry_run=%t",
		result.UsersChecked, result.UsersDeactivated, result.UsersSkipped, result.DryRun)
	return result, nil
}

func main() {
	lambda.Start(handler)
}
