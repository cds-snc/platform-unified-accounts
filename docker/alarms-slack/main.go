// Lambda function that forwards CloudWatch alarm log events to Slack.
//
// Required environment variables:
//
//	SLACK_WEBHOOK_SSM_PARAMETER_NAME - SSM Parameter Store path for the Slack webhook URL
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

const slackWebhookParameterNameEnvVar = "SLACK_WEBHOOK_SSM_PARAMETER_NAME"

type ssmAPI interface {
	GetParameter(
		ctx context.Context,
		params *ssm.GetParameterInput,
		optFns ...func(*ssm.Options),
	) (*ssm.GetParameterOutput, error)
}

// ---------------------------------------------------------------------------
// Module-level configuration (read once at cold start)
// ---------------------------------------------------------------------------

var slackWebhookParameterName string

// AWS clients initialised at cold start.
var (
	ssmClient  ssmAPI
	httpClient *http.Client
	initErr    error
)

// Slack webhook URL cached after the first SSM read.
var (
	webhookMu        sync.Mutex
	cachedWebhookURL string
)

func init() {
	slackWebhookParameterName = strings.TrimSpace(os.Getenv(slackWebhookParameterNameEnvVar))
	if slackWebhookParameterName == "" {
		initErr = fmt.Errorf("%s environment variable is required", slackWebhookParameterNameEnvVar)
		return
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		initErr = fmt.Errorf("load AWS config: %w", err)
		return
	}

	ssmClient = ssm.NewFromConfig(cfg)
	httpClient = &http.Client{Timeout: 10 * time.Second}
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

type cloudWatchLogsEvent struct {
	AWSLogs struct {
		Data string `json:"data"`
	} `json:"awslogs"`
}

type cloudWatchLogsPayload struct {
	MessageType         string                `json:"messageType"`
	LogGroup            string                `json:"logGroup"`
	LogStream           string                `json:"logStream"`
	LogEvents           []cloudWatchLogRecord `json:"logEvents"`
	SubscriptionFilters []string              `json:"subscriptionFilters"`
}

type cloudWatchLogRecord struct {
	ID        string `json:"id"`
	Timestamp int64  `json:"timestamp"`
	Message   string `json:"message"`
}

type slackBlockText struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type slackBlock struct {
	Type string          `json:"type"`
	Text *slackBlockText `json:"text,omitempty"`
}

type slackAttachment struct {
	Color  string       `json:"color"`
	Blocks []slackBlock `json:"blocks"`
}

type slackMessage struct {
	Attachments []slackAttachment `json:"attachments"`
}

// loadSlackWebhookURL reads the Slack webhook URL from SSM Parameter Store,
// caching it for subsequent warm invocations.
func loadSlackWebhookURL(ctx context.Context) (string, error) {
	webhookMu.Lock()
	defer webhookMu.Unlock()
	if cachedWebhookURL != "" {
		log.Println("Using cached Slack webhook URL")
		return cachedWebhookURL, nil
	}

	log.Printf("Loading Slack webhook URL from SSM: %s", slackWebhookParameterName)
	out, err := ssmClient.GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(slackWebhookParameterName),
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return "", fmt.Errorf("load Slack webhook URL from SSM parameter %q: %w", slackWebhookParameterName, err)
	}

	webhookURL := strings.TrimSpace(aws.ToString(out.Parameter.Value))
	if webhookURL == "" {
		return "", fmt.Errorf("SSM parameter %q did not contain a Slack webhook URL", slackWebhookParameterName)
	}

	cachedWebhookURL = webhookURL
	log.Println("Slack webhook URL loaded successfully from SSM")
	return cachedWebhookURL, nil
}

func decodeCloudWatchLogsData(encodedData string) (*cloudWatchLogsPayload, error) {
	compressedData, err := base64.StdEncoding.DecodeString(encodedData)
	if err != nil {
		return nil, fmt.Errorf("decode CloudWatch logs payload: %w", err)
	}

	gzipReader, err := gzip.NewReader(bytes.NewReader(compressedData))
	if err != nil {
		return nil, fmt.Errorf("open gzip CloudWatch logs payload: %w", err)
	}
	defer gzipReader.Close()

	payloadBytes, err := io.ReadAll(gzipReader)
	if err != nil {
		return nil, fmt.Errorf("read CloudWatch logs payload: %w", err)
	}

	var payload cloudWatchLogsPayload
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal CloudWatch logs payload: %w", err)
	}

	return &payload, nil
}

func postToSlack(ctx context.Context, webhookURL string, payload cloudWatchLogsPayload) error {
	messageBody, err := json.Marshal(formatSlackMessage(payload.SubscriptionFilters, payload.LogGroup, payload.LogEvents))
	if err != nil {
		return fmt.Errorf("marshal Slack payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhookURL, bytes.NewReader(messageBody))
	if err != nil {
		return fmt.Errorf("create Slack request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("post message to Slack: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		responseBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("Slack webhook returned %d: %s", resp.StatusCode, strings.TrimSpace(string(responseBody)))
	}

	return nil
}

func formatSlackMessage(subscriptionFilters []string, logGroup string, logEvents []cloudWatchLogRecord) slackMessage {

	header := fmt.Sprintf(":fire: *Error %s*", logGroup)
	colour := "#eb1607"
	for _, filter := range subscriptionFilters {
		if filter == "audit-event-logged" {
			header = fmt.Sprintf(":warning: *Audit %s*", logGroup)
			colour = "#e3b505"
			break
		}
	}

	var msgBuilder strings.Builder
	for i, logEvent := range logEvents {
		if i > 0 {
			msgBuilder.WriteString("\n")
		}
		msgBuilder.WriteString(normalizeLogMessage(logEvent.Message))
	}

	return slackMessage{
		Attachments: []slackAttachment{
			{
				Color: colour,
				Blocks: []slackBlock{
					{
						Type: "section",
						Text: &slackBlockText{Type: "mrkdwn", Text: header},
					},
					{
						Type: "divider",
					},
					{
						Type: "section",
						Text: &slackBlockText{Type: "plain_text", Text: msgBuilder.String()},
					},
				},
			},
		},
	}
}

func normalizeLogMessage(logMessage string) string {
	message := strings.TrimSpace(logMessage)
	if message == "" {
		return "<empty log message>"
	}

	return message
}

// ---------------------------------------------------------------------------
// Lambda entry point
// ---------------------------------------------------------------------------

func handler(ctx context.Context, event cloudWatchLogsEvent) error {
	if initErr != nil {
		return initErr
	}

	if strings.TrimSpace(event.AWSLogs.Data) == "" {
		return fmt.Errorf("event did not contain awslogs data")
	}

	payload, err := decodeCloudWatchLogsData(event.AWSLogs.Data)
	if err != nil {
		return err
	}

	if payload.MessageType != "DATA_MESSAGE" {
		log.Printf("ignoring CloudWatch message type %q", payload.MessageType)
		return nil
	}

	if len(payload.LogEvents) == 0 {
		log.Printf("CloudWatch DATA_MESSAGE for log group %q did not contain any log events", payload.LogGroup)
		return nil
	}

	webhookURL, err := loadSlackWebhookURL(ctx)
	if err != nil {
		return err
	}

	return postToSlack(ctx, webhookURL, *payload)
}

func main() {
	lambda.Start(handler)
}
