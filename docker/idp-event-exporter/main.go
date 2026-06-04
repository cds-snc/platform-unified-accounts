// Lambda function that periodically exports Zitadel audit events to S3.
//
// Required environment variables:
//
//	ZITADEL_URL            - Base URL of the Zitadel instance
//	S3_BUCKET              - Destination S3 bucket name
//	ZITADEL_TOKEN_SSM_PATH - SSM Parameter Store path for the Zitadel Bearer token
//	ZITADEL_HOST           - Host header value for Zitadel API requests
//
// Optional environment variables:
//
//	WINDOW_MINUTES - Duration of the collection window in minutes (default: 15)
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
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

// List of event types that should alert the team when they occur
// `*` is replaced by `.*` when the regex is compiled
var eventsTypesToAudit = []string{
	"instance.member.*",
	"org.member.*",
	"instance.policy.*",
	"org.policy.*",
	"project.application.added",
	"project.application.removed",
	"project.application.config.*",
}

// ---------------------------------------------------------------------------
// Module-level configuration (read once at cold start)
// ---------------------------------------------------------------------------

var (
	zitadelURL          string
	s3Bucket            string
	zitadelTokenSSMPath string
	zitadelHost         string
	windowMinutes       int
)

// AWS clients initialised at cold start.
var (
	s3Client  *s3.Client
	ssmClient *ssm.Client
	initErr   error
)

// Bearer token cached after the first SSM read
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
	s3Bucket = os.Getenv("S3_BUCKET")
	if s3Bucket == "" {
		missing = append(missing, "S3_BUCKET")
	}
	zitadelTokenSSMPath = os.Getenv("ZITADEL_TOKEN_SSM_PATH")
	if zitadelTokenSSMPath == "" {
		missing = append(missing, "ZITADEL_TOKEN_SSM_PATH")
	}
	zitadelHost = os.Getenv("ZITADEL_HOST")
	if zitadelHost == "" {
		missing = append(missing, "ZITADEL_HOST")
	}
	if len(missing) > 0 {
		initErr = fmt.Errorf("required environment variables not set: %s", strings.Join(missing, ", "))
		return
	}

	wm, err := parseWindowMinutes()
	if err != nil {
		initErr = err
		return
	}
	windowMinutes = wm

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		initErr = fmt.Errorf("loading AWS config: %w", err)
		return
	}
	s3Client = s3.NewFromConfig(cfg)
	ssmClient = ssm.NewFromConfig(cfg)
}

func parseWindowMinutes() (int, error) {
	v := os.Getenv("WINDOW_MINUTES")
	if v == "" {
		return 15, nil
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("WINDOW_MINUTES must be an integer, got %q", v)
	}
	return i, nil
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// computeWindow returns the (windowStart, windowEnd) for the most recently
// completed window aligned to windowMins boundaries on the UTC clock.
//
// Example: now=15:22:45 with windowMins=15 → (15:00:00, 15:15:00)
func computeWindow(now time.Time, windowMins int) (time.Time, time.Time) {
	windowSecs := int64(windowMins * 60)
	epochSecs := now.Unix()
	windowEndEpoch := (epochSecs / windowSecs) * windowSecs
	windowEnd := time.Unix(windowEndEpoch, 0).UTC()
	windowStart := windowEnd.Add(-time.Duration(windowMins) * time.Minute)
	return windowStart, windowEnd
}

// formatTimestamp formats a UTC time as an RFC 3339 string with microsecond
// precision (all zeros), matching the Zitadel API expectation.
func formatTimestamp(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000Z")
}

// loadBearerToken reads the Zitadel Bearer token from SSM Parameter Store,
// caching it for subsequent warm invocations.
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
// Core logic
// ---------------------------------------------------------------------------

type eventSearchRequest struct {
	From string `json:"from"`
	Asc  bool   `json:"asc"`
}

type eventSearchResponse struct {
	Events []json.RawMessage `json:"events"`
}

type eventEnvelope struct {
	Editor struct {
		UserID      string `json:"userId"`
		DisplayName string `json:"displayName"`
		Service     string `json:"service"`
	} `json:"editor"`
	CreationDate string          `json:"creationDate"`
	Payload      json.RawMessage `json:"payload"`
	Type         struct {
		Type string `json:"type"`
	} `json:"type"`
}

// fetchEvents fetches all events from the Zitadel Admin API on or after windowStart.
func fetchEvents(ctx context.Context, client *http.Client, baseURL, token string, windowStart time.Time) ([]json.RawMessage, error) {
	url := strings.TrimRight(baseURL, "/") + "/admin/v1/events/_search"
	fromStr := formatTimestamp(windowStart)

	reqBody := eventSearchRequest{From: fromStr, Asc: true}
	reqBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshalling request body: %w", err)
	}

	log.Printf("Fetching events from %s starting at %s", url, fromStr)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(reqBytes))
	if err != nil {
		return nil, fmt.Errorf("building request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Host = zitadelHost

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("executing request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("HTTP %d from Zitadel: %s", resp.StatusCode, body)
	}

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading response body: %w", err)
	}

	var result eventSearchResponse
	if err := json.Unmarshal(respBytes, &result); err != nil {
		return nil, fmt.Errorf("parsing response: %w", err)
	}

	log.Printf("Fetched %d event(s)", len(result.Events))
	return result.Events, nil
}

func auditEvents(events []json.RawMessage, patterns []string) {
	log.Printf("Auditing %d event(s) for events of interest", len(events))

	// Pre-compile regex patterns
	patternsCompiled := make([]*regexp.Regexp, len(patterns))
	for i, pattern := range patterns {
		regexPattern := "^" + strings.ReplaceAll(pattern, "*", ".*") + "$"
		compiledPattern, err := regexp.Compile(regexPattern)
		if err != nil {
			log.Printf("Error compiling regex for pattern %q: %v", pattern, err)
			continue
		}
		patternsCompiled[i] = compiledPattern
	}

	// Loop through events and log those that match any of the patterns we're auditting
	for _, e := range events {
		var envelope eventEnvelope
		if err := json.Unmarshal(e, &envelope); err != nil {
			log.Printf("Error parsing event metadata: %v", err)
			continue
		}
		for _, pattern := range patternsCompiled {
			if pattern.MatchString(envelope.Type.Type) {
				log.Printf(
					"AEVT: %s by %s change=%s",
					envelope.Type.Type,
					envelope.Editor.DisplayName,
					string(envelope.Payload),
				)
				break
			}
		}
	}
}

// saveToS3 serialises events as newline-delimited JSON and writes it to the
// given key in bucket.
func saveToS3(ctx context.Context, bucket, key string, events []json.RawMessage) error {
	log.Printf("Saving %d event(s) to s3://%s/%s", len(events), bucket, key)

	var buf bytes.Buffer
	for _, e := range events {
		b, err := json.Marshal(json.RawMessage(e))
		if err != nil {
			return fmt.Errorf("marshalling event: %w", err)
		}
		buf.Write(b)
		buf.WriteByte('\n')
	}

	_, err := s3Client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(buf.Bytes()),
		ContentType: aws.String("application/json"),
	})
	if err != nil {
		return fmt.Errorf("putting S3 object: %w", err)
	}

	log.Printf("Successfully saved %d event(s) to s3://%s/%s", len(events), bucket, key)
	return nil
}

// ---------------------------------------------------------------------------
// Lambda entry point
// ---------------------------------------------------------------------------

type response struct {
	StatusCode  int    `json:"statusCode"`
	EventsCount int    `json:"events_count"`
	S3Key       string `json:"s3_key"`
	WindowStart string `json:"window_start"`
	WindowEnd   string `json:"window_end"`
}

func handler(ctx context.Context) (response, error) {
	if initErr != nil {
		return response{}, initErr
	}

	now := time.Now().UTC()
	windowStart, windowEnd := computeWindow(now, windowMinutes)
	log.Printf("Starting event export: window=[%s, %s) window_minutes=%d",
		windowStart.Format(time.RFC3339), windowEnd.Format(time.RFC3339), windowMinutes)

	token, err := loadBearerToken(ctx)
	if err != nil {
		return response{}, fmt.Errorf("loading bearer token: %w", err)
	}

	events, err := fetchEvents(ctx, http.DefaultClient, zitadelURL, token, windowStart)
	if err != nil {
		return response{}, fmt.Errorf("fetching events: %w", err)
	}

	result := response{
		StatusCode:  200,
		EventsCount: len(events),
		WindowStart: windowStart.Format(time.RFC3339),
		WindowEnd:   windowEnd.Format(time.RFC3339),
	}

	if len(events) == 0 {
		log.Println("No events in window, skipping S3 upload")
		log.Printf("Event export complete: %+v", result)
		return result, nil
	}

	auditEvents(events, eventsTypesToAudit)

	s3Key := fmt.Sprintf("events/%s.json", windowStart.Format("2006/01/02/15-04-05"))
	if err := saveToS3(ctx, s3Bucket, s3Key, events); err != nil {
		return response{}, fmt.Errorf("saving to S3: %w", err)
	}
	result.S3Key = s3Key
	log.Printf("Event export complete: %+v", result)
	return result, nil
}

func main() {
	lambda.Start(handler)
}
