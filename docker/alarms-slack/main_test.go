package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

type fakeSSMClient struct {
	value string
	err   error
	name  string
	seen  bool
}

func (f *fakeSSMClient) GetParameter(
	ctx context.Context,
	params *ssm.GetParameterInput,
	optFns ...func(*ssm.Options),
) (*ssm.GetParameterOutput, error) {
	f.seen = true
	f.name = aws.ToString(params.Name)
	if f.err != nil {
		return nil, f.err
	}

	return &ssm.GetParameterOutput{
		Parameter: &ssmtypes.Parameter{Value: aws.String(f.value)},
	}, nil
}

// ---------------------------------------------------------------------------
// loadSlackWebhookURL
// ---------------------------------------------------------------------------

func TestLoadSlackWebhookURL_ReadsFromSSM(t *testing.T) {
	fakeClient := &fakeSSMClient{value: "https://hooks.slack.test/services/123"}
	restore := setHandlerGlobals(t, "/alerts/slack-webhook", fakeClient, http.DefaultClient, "")
	defer restore()

	got, err := loadSlackWebhookURL(t.Context())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !fakeClient.seen {
		t.Fatal("expected SSM GetParameter to be called")
	}
	if fakeClient.name != "/alerts/slack-webhook" {
		t.Fatalf("got parameter name %q, want %q", fakeClient.name, "/alerts/slack-webhook")
	}
	if got != "https://hooks.slack.test/services/123" {
		t.Fatalf("got webhook URL %q", got)
	}
}

func TestLoadSlackWebhookURL_UsesCachedValue(t *testing.T) {
	fakeClient := &fakeSSMClient{value: "https://hooks.slack.test/services/123"}
	restore := setHandlerGlobals(t, "/alerts/slack-webhook", fakeClient, http.DefaultClient, "https://hooks.slack.test/services/cached")
	defer restore()

	got, err := loadSlackWebhookURL(t.Context())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if fakeClient.seen {
		t.Fatal("expected cached webhook URL to avoid SSM call")
	}
	if got != "https://hooks.slack.test/services/cached" {
		t.Fatalf("got webhook URL %q", got)
	}
}

func TestLoadSlackWebhookURL_PropagatesSSMError(t *testing.T) {
	fakeClient := &fakeSSMClient{err: errors.New("boom")}
	restore := setHandlerGlobals(t, "/alerts/slack-webhook", fakeClient, http.DefaultClient, "")
	defer restore()

	_, err := loadSlackWebhookURL(t.Context())
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// decodeCloudWatchLogsData
// ---------------------------------------------------------------------------

func TestDecodeCloudWatchLogsData(t *testing.T) {
	encodedData := encodeLogsPayload(t, cloudWatchLogsPayload{
		MessageType:         "DATA_MESSAGE",
		LogGroup:            "/aws/lambda/example",
		LogStream:           "stream-1",
		SubscriptionFilters: []string{"audit-event-logged"},
		LogEvents: []cloudWatchLogRecord{
			{ID: "1", Message: "something failed"},
		},
	})

	payload, err := decodeCloudWatchLogsData(encodedData)
	if err != nil {
		t.Fatalf("decodeCloudWatchLogsData returned error: %v", err)
	}

	if payload.LogGroup != "/aws/lambda/example" {
		t.Fatalf("got log group %q", payload.LogGroup)
	}
	if len(payload.LogEvents) != 1 || payload.LogEvents[0].Message != "something failed" {
		t.Fatalf("unexpected payload: %+v", payload.LogEvents)
	}
	if len(payload.SubscriptionFilters) != 1 || payload.SubscriptionFilters[0] != "audit-event-logged" {
		t.Fatalf("unexpected subscription filters: %+v", payload.SubscriptionFilters)
	}
}

// ---------------------------------------------------------------------------
// handler
// ---------------------------------------------------------------------------

func TestHandler_PostsSingleSlackMessageForAllLogEvents(t *testing.T) {
	var requests []slackMessage
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()

		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read request body: %v", err)
		}

		var message slackMessage
		if err := json.Unmarshal(body, &message); err != nil {
			t.Fatalf("unmarshal request body: %v", err)
		}

		requests = append(requests, message)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	fakeClient := &fakeSSMClient{value: server.URL}
	restore := setHandlerGlobals(t, "/alerts/slack-webhook", fakeClient, server.Client(), "")
	defer restore()

	err := handler(t.Context(), cloudWatchLogsEvent{
		AWSLogs: struct {
			Data string `json:"data"`
		}{
			Data: encodeLogsPayload(t, cloudWatchLogsPayload{
				MessageType:         "DATA_MESSAGE",
				LogGroup:            "/aws/lambda/example",
				LogStream:           "stream-1",
				SubscriptionFilters: []string{"error-alerts"},
				LogEvents: []cloudWatchLogRecord{
					{ID: "1", Message: "first failure"},
					{ID: "2", Message: "second failure"},
				},
			}),
		},
	})
	if err != nil {
		t.Fatalf("handle returned error: %v", err)
	}

	if len(requests) != 1 {
		t.Fatalf("got %d Slack requests, want 1", len(requests))
	}

	attachment := requests[0].Attachments[0]
	if attachment.Color != "#eb1607" {
		t.Fatalf("unexpected attachment color: %q", attachment.Color)
	}

	headerText := attachment.Blocks[0].Text.Text
	if !strings.Contains(headerText, "/aws/lambda/example") {
		t.Fatalf("unexpected Slack message header: %q", headerText)
	}

	if attachment.Blocks[1].Type != "divider" {
		t.Fatalf("expected divider block, got %q", attachment.Blocks[1].Type)
	}

	bodyText := attachment.Blocks[2].Text.Text
	if !strings.Contains(bodyText, "first failure") {
		t.Fatalf("unexpected Slack message body: %q", bodyText)
	}
	if !strings.Contains(bodyText, "second failure") {
		t.Fatalf("unexpected Slack message body: %q", bodyText)
	}
}

func TestHandler_FormatsAuditEventsAsWarnings(t *testing.T) {
	for _, tc := range []struct {
		name   string
		filter string
	}{
		{name: "audit-event-logged", filter: "audit-event-logged"},
		{name: "database-pgaudit", filter: "database-pgaudit"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var requests []slackMessage
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer r.Body.Close()

				body, err := io.ReadAll(r.Body)
				if err != nil {
					t.Fatalf("read request body: %v", err)
				}

				var message slackMessage
				if err := json.Unmarshal(body, &message); err != nil {
					t.Fatalf("unmarshal request body: %v", err)
				}

				requests = append(requests, message)
				w.WriteHeader(http.StatusOK)
			}))
			defer server.Close()

			fakeClient := &fakeSSMClient{value: server.URL}
			restore := setHandlerGlobals(t, "/alerts/slack-webhook", fakeClient, server.Client(), "")
			defer restore()

			err := handler(t.Context(), cloudWatchLogsEvent{
				AWSLogs: struct {
					Data string `json:"data"`
				}{
					Data: encodeLogsPayload(t, cloudWatchLogsPayload{
						MessageType:         "DATA_MESSAGE",
						LogGroup:            "/aws/lambda/audit-example",
						LogStream:           "stream-1",
						SubscriptionFilters: []string{tc.filter},
						LogEvents: []cloudWatchLogRecord{
							{ID: "1", Message: "audit event recorded"},
						},
					}),
				},
			})
			if err != nil {
				t.Fatalf("handle returned error: %v", err)
			}

			if len(requests) != 1 {
				t.Fatalf("got %d Slack requests, want 1", len(requests))
			}

			attachment := requests[0].Attachments[0]
			if attachment.Color != "#e3b505" {
				t.Fatalf("unexpected attachment color: %q", attachment.Color)
			}

			headerText := attachment.Blocks[0].Text.Text
			if !strings.Contains(headerText, ":warning:") {
				t.Fatalf("unexpected Slack message header: %q", headerText)
			}
			if !strings.Contains(headerText, "/aws/lambda/audit-example") {
				t.Fatalf("unexpected Slack message header: %q", headerText)
			}
		})
	}
}

func TestHandler_IgnoresControlMessages(t *testing.T) {
	restore := setHandlerGlobals(t, "/alerts/slack-webhook", &fakeSSMClient{}, http.DefaultClient, "https://hooks.slack.test/services/123")
	defer restore()

	err := handler(t.Context(), cloudWatchLogsEvent{
		AWSLogs: struct {
			Data string `json:"data"`
		}{
			Data: encodeLogsPayload(t, cloudWatchLogsPayload{MessageType: "CONTROL_MESSAGE"}),
		},
	})
	if err != nil {
		t.Fatalf("control message should be ignored, got error: %v", err)
	}
}

func TestHandler_RequiresAWSLogsData(t *testing.T) {
	restore := setHandlerGlobals(t, "/alerts/slack-webhook", &fakeSSMClient{}, http.DefaultClient, "https://hooks.slack.test/services/123")
	defer restore()

	err := handler(t.Context(), cloudWatchLogsEvent{})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "awslogs data") {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// formatSlackMessage
// ---------------------------------------------------------------------------

func TestFormatSlackMessageHandlesEmptyMessage(t *testing.T) {
	msg := formatSlackMessage(nil, "/aws/lambda/example", []cloudWatchLogRecord{{Message: "   "}})
	bodyText := msg.Attachments[0].Blocks[2].Text.Text
	if !strings.Contains(bodyText, "<empty log message>") {
		t.Fatalf("unexpected message: %q", bodyText)
	}
}

func TestFormatSlackMessageMarksAuditEvents(t *testing.T) {
	for _, filter := range []string{"audit-event-logged", "database-pgaudit"} {
		t.Run(filter, func(t *testing.T) {
			msg := formatSlackMessage([]string{filter}, "/aws/lambda/example", []cloudWatchLogRecord{{Message: "audit entry"}})
			attachment := msg.Attachments[0]
			if attachment.Color != "#e3b505" {
				t.Fatalf("unexpected attachment color: %q", attachment.Color)
			}

			headerText := attachment.Blocks[0].Text.Text
			if !strings.Contains(headerText, ":warning:") {
				t.Fatalf("unexpected Slack message header: %q", headerText)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// setHandlerGlobals overwrites the package-level globals used by handler and
// returns a restore function to be deferred by the caller.
func setHandlerGlobals(t *testing.T, parameterName string, client ssmAPI, httpClientValue *http.Client, webhookURL string) func() {
	t.Helper()
	origParameterName := slackWebhookParameterName
	origSSMClient := ssmClient
	origHTTPClient := httpClient
	origInitErr := initErr

	webhookMu.Lock()
	origWebhookURL := cachedWebhookURL
	cachedWebhookURL = webhookURL
	webhookMu.Unlock()

	slackWebhookParameterName = parameterName
	ssmClient = client
	httpClient = httpClientValue
	initErr = nil

	return func() {
		slackWebhookParameterName = origParameterName
		ssmClient = origSSMClient
		httpClient = origHTTPClient
		initErr = origInitErr
		webhookMu.Lock()
		cachedWebhookURL = origWebhookURL
		webhookMu.Unlock()
	}
}

func encodeLogsPayload(t *testing.T, payload cloudWatchLogsPayload) string {
	t.Helper()

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	var buffer bytes.Buffer
	gzipWriter := gzip.NewWriter(&buffer)
	if _, err := gzipWriter.Write(payloadBytes); err != nil {
		t.Fatalf("gzip payload: %v", err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatalf("close gzip writer: %v", err)
	}

	return base64.StdEncoding.EncodeToString(buffer.Bytes())
}

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}
