// Lambda function that periodically exports Zitadel audit events to S3.
//
// Required environment variables:
//
//	ZITADEL_URL                  - Base URL of the Zitadel instance
//	S3_BUCKET                    - Destination S3 bucket name
//	ZITADEL_PRIVATE_KEY_SSM_PATH - SSM Parameter Store path for the Zitadel service account JSON key
//
// Optional environment variables:
//
//	WINDOW_MINUTES - Duration of the collection window in minutes (default: 5)
//	LOCAL          - When "true", run the handler directly instead of starting the Lambda (default: false)
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/zitadel/oidc/v3/pkg/oidc"
	zitadelclient "github.com/zitadel/zitadel-go/v3/pkg/client"
	adminpb "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/admin"
	"github.com/zitadel/zitadel-go/v3/pkg/zitadel"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// List of event types that should alert the team when they occur.
// `*` is replaced by `.*` when the regex is compiled.
var eventsTypesToAudit = []string{
	"instance.member.*",
	"org.member.*",
	"instance.policy.*",
	"org.policy.*",
	"project.application.added",
	"project.application.removed",
	"project.application.config.*",
	"user.locked",
}

// ---------------------------------------------------------------------------
// Module-level configuration (read once at cold start)
// ---------------------------------------------------------------------------

var (
	zitadelURL               string
	s3Bucket                 string
	zitadelPrivateKeySSMPath string
	windowMinutes            int
)

// AWS clients and the parsed Zitadel key are initialised at cold start.
var (
	s3Client       *s3.Client
	ssmClient      *ssm.Client
	zitadelKeyFile *zitadelclient.KeyFile
	initErr        error
)

// adminService is the subset of the Zitadel AdminService gRPC client used by
// this function.
type adminService interface {
	ListEvents(context.Context, *adminpb.ListEventsRequest, ...grpc.CallOption) (*adminpb.ListEventsResponse, error)
}

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
	zitadelPrivateKeySSMPath = os.Getenv("ZITADEL_PRIVATE_KEY_SSM_PATH")
	if zitadelPrivateKeySSMPath == "" {
		missing = append(missing, "ZITADEL_PRIVATE_KEY_SSM_PATH")
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

	// Load private key from SSM
	keyJSON, err := loadSSMParameter(context.Background(), zitadelPrivateKeySSMPath)
	if err != nil {
		initErr = fmt.Errorf("loading Zitadel private key from SSM: %w", err)
		return
	}
	keyFile, err := zitadelclient.ConfigFromKeyFileData([]byte(keyJSON))
	if err != nil {
		initErr = fmt.Errorf("parsing Zitadel private key: %w", err)
		return
	}
	zitadelKeyFile = keyFile
}

func parseWindowMinutes() (int, error) {
	v := os.Getenv("WINDOW_MINUTES")
	if v == "" {
		return 5, nil
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("WINDOW_MINUTES must be an integer, got %q", v)
	}
	return i, nil
}

// ---------------------------------------------------------------------------
// SSM
// ---------------------------------------------------------------------------

func loadSSMParameter(ctx context.Context, path string) (string, error) {
	out, err := ssmClient.GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(path),
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return "", fmt.Errorf("getting SSM parameter %s: %w", path, err)
	}
	return aws.ToString(out.Parameter.Value), nil
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// computeWindow returns the (windowStart, windowEnd) for the most recently
// completed window aligned to windowMins boundaries on the UTC clock.
//
// Example: now=15:22:45 with windowMins=5 → (15:15:00, 15:20:00)
func computeWindow(now time.Time, windowMins int) (time.Time, time.Time) {
	windowSecs := int64(windowMins * 60)
	epochSecs := now.Unix()
	windowEndEpoch := (epochSecs / windowSecs) * windowSecs
	windowEnd := time.Unix(windowEndEpoch, 0).UTC()
	windowStart := windowEnd.Add(-time.Duration(windowMins) * time.Minute)
	return windowStart, windowEnd
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

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

// fetchEvents fetches all events from the Zitadel Admin API between windowStart and
// windowEnd and returns them serialised as JSON.
func fetchEvents(ctx context.Context, svc adminService, windowStart, windowEnd time.Time) ([]json.RawMessage, error) {
	log.Printf("Fetching events from Zitadel starting at %s and ending at %s", windowStart.Format(time.RFC3339), windowEnd.Format(time.RFC3339))

	resp, err := svc.ListEvents(ctx, &adminpb.ListEventsRequest{
		CreationDateFilter: &adminpb.ListEventsRequest_Range{
			Range: &adminpb.ListEventsRequestCreationDateRange{
				Since: timestamppb.New(windowStart),
				Until: timestamppb.New(windowEnd),
			},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("fetching events: %w", err)
	}

	result := make([]json.RawMessage, 0, len(resp.GetEvents()))
	for _, event := range resp.GetEvents() {
		b, err := protojson.Marshal(event)
		if err != nil {
			return nil, fmt.Errorf("marshalling event: %w", err)
		}
		result = append(result, json.RawMessage(b))
	}

	log.Printf("Fetched %d event(s)", len(result))
	return result, nil
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

	// Loop through events and log those that match any of the patterns we're auditing.
	for _, e := range events {
		var envelope eventEnvelope
		if err := json.Unmarshal(e, &envelope); err != nil {
			log.Printf("Error parsing event metadata: %v", err)
			continue
		}
		for _, pattern := range patternsCompiled {
			if pattern.MatchString(envelope.Type.Type) {
				log.Printf(
					"AEVT: `%s` by `%s` change %s",
					envelope.Type.Type,
					envelope.Editor.DisplayName,
					string(envelope.Payload),
				)
				break
			}
		}
	}
}

// saveToS3 serialises events as newline-delimited JSON and writes them to the
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

type scheduledEvent struct {
    Time time.Time `json:"time"`
}

type sqsRedriveRecord struct {
    Body string `json:"body"`
}

type sqsRedriveEvent struct {
    Records []sqsRedriveRecord `json:"Records"`
}

type lambdaFailureRecord struct {
    RequestPayload json.RawMessage `json:"requestPayload"`
}

func extractTriggerTime(payload json.RawMessage) time.Time {
    var sqsEvent sqsRedriveEvent
    if err := json.Unmarshal(payload, &sqsEvent); err == nil && len(sqsEvent.Records) > 0 {
        var record lambdaFailureRecord
        if err := json.Unmarshal([]byte(sqsEvent.Records[0].Body), &record); err == nil {
            var scheduled scheduledEvent
            if err := json.Unmarshal(record.RequestPayload, &scheduled); err == nil && !scheduled.Time.IsZero() {
                log.Printf("SQS redrive: using original trigger time %s", scheduled.Time.Format(time.RFC3339))
                return scheduled.Time.UTC()
            }
        }
    }

    var scheduled scheduledEvent
    if err := json.Unmarshal(payload, &scheduled); err == nil && !scheduled.Time.IsZero() {
        return scheduled.Time.UTC()
    }

    return time.Now().UTC()
}

func handler(ctx context.Context, payload json.RawMessage) (response, error) {
	if initErr != nil {
		return response{}, initErr
	}

	zitadelAPIClient, err := zitadelclient.New(
		ctx,
		zitadel.New(zitadelURL),
		zitadelclient.WithAuth(zitadelclient.AuthenticationJWTProfile(
			zitadelKeyFile,
			oidc.ScopeOpenID,
			zitadelclient.ScopeZitadelAPI(),
		)),
	)
	if err != nil {
		return response{}, fmt.Errorf("creating Zitadel client: %w", err)
	}
	defer zitadelAPIClient.Close()

	// Fetch the token once so all gRPC calls reuse the same OIDC session
	token, err := zitadelAPIClient.GetValidToken()
	if err != nil {
		return response{}, fmt.Errorf("getting Zitadel token: %w", err)
	}
	ctx = zitadelclient.BearerTokenCtx(ctx, token)

	windowStart, windowEnd := computeWindow(extractTriggerTime(payload), windowMinutes)
	log.Printf("Starting event export: window=[%s, %s) window_minutes=%d",
		windowStart.Format(time.RFC3339), windowEnd.Format(time.RFC3339), windowMinutes)

	svc := zitadelAPIClient.AdminService()

	events, err := fetchEvents(ctx, svc, windowStart, windowEnd)
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
	isLocal := os.Getenv("LOCAL") == "true"
	if isLocal {
		log.Println("Running locally, invoking handler directly")
		response, err := handler(context.Background())
		if err != nil {
			log.Fatalf("Handler error: %v", err)
		}
		log.Printf("Handler response: %+v", response)
	} else {
		log.Println("Running in Lambda")
		lambda.Start(handler)
	}
}
