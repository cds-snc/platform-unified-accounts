package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"strings"
	"testing"
	"time"

	adminpb "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/admin"
	eventpb "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/event"
	"google.golang.org/grpc"

	"github.com/aws/aws-lambda-go/events"
)

// ---------------------------------------------------------------------------
// Mock adminService
// ---------------------------------------------------------------------------

type mockAdminService struct {
	// capturedReq holds the last ListEventsRequest received.
	capturedReq  *adminpb.ListEventsRequest
	capturedReqs []*adminpb.ListEventsRequest

	events     []*eventpb.Event
	eventPages [][]*eventpb.Event
	eventsErr  error
}

func (m *mockAdminService) ListEvents(_ context.Context, req *adminpb.ListEventsRequest, _ ...grpc.CallOption) (*adminpb.ListEventsResponse, error) {
	m.capturedReq = req
	m.capturedReqs = append(m.capturedReqs, req)
	if m.eventsErr != nil {
		return nil, m.eventsErr
	}
	pageIndex := len(m.capturedReqs) - 1
	if pageIndex < len(m.eventPages) {
		return &adminpb.ListEventsResponse{Events: m.eventPages[pageIndex]}, nil
	}
	return &adminpb.ListEventsResponse{Events: m.events}, nil
}

// ---------------------------------------------------------------------------
// computeWindow
// ---------------------------------------------------------------------------

func TestComputeWindow_AlignsTo15MinBoundary(t *testing.T) {
	now := time.Date(2026, 4, 21, 15, 22, 45, 0, time.UTC)
	start, end := computeWindow(now, 15)
	wantStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)
	if !start.Equal(wantStart) {
		t.Errorf("start: got %v, want %v", start, wantStart)
	}
	if !end.Equal(wantEnd) {
		t.Errorf("end: got %v, want %v", end, wantEnd)
	}
}

func TestComputeWindow_AlignsTo30MinBoundary(t *testing.T) {
	now := time.Date(2026, 4, 21, 15, 45, 0, 0, time.UTC)
	start, end := computeWindow(now, 30)
	wantStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 4, 21, 15, 30, 0, 0, time.UTC)
	if !start.Equal(wantStart) {
		t.Errorf("start: got %v, want %v", start, wantStart)
	}
	if !end.Equal(wantEnd) {
		t.Errorf("end: got %v, want %v", end, wantEnd)
	}
}

func TestComputeWindow_ExactlyOnBoundary(t *testing.T) {
	// At exactly 15:15:00 the completed window is 15:00–15:15.
	now := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)
	start, end := computeWindow(now, 15)
	wantStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)
	if !start.Equal(wantStart) {
		t.Errorf("start: got %v, want %v", start, wantStart)
	}
	if !end.Equal(wantEnd) {
		t.Errorf("end: got %v, want %v", end, wantEnd)
	}
}

func TestComputeWindow_DurationEqualsWindowMinutes(t *testing.T) {
	now := time.Date(2026, 4, 21, 9, 7, 0, 0, time.UTC)
	start, end := computeWindow(now, 15)
	if end.Sub(start) != 15*time.Minute {
		t.Errorf("duration: got %v, want 15m", end.Sub(start))
	}
}

// ---------------------------------------------------------------------------
// fetchEvents
// ---------------------------------------------------------------------------

func TestFetchEvents_EmptyResponse(t *testing.T) {
	svc := &mockAdminService{}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	windowEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)

	got, err := fetchEvents(t.Context(), svc, windowStart, windowEnd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d events, want 0", len(got))
	}
}

func TestFetchEvents_SingleEvent(t *testing.T) {
	svc := &mockAdminService{
		events: []*eventpb.Event{{}}, // one empty proto event
	}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	windowEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)

	got, err := fetchEvents(t.Context(), svc, windowStart, windowEnd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d events, want 1", len(got))
	}
	// Each element must be valid JSON.
	var v interface{}
	if err := json.Unmarshal(got[0], &v); err != nil {
		t.Errorf("event[0] is not valid JSON: %v (got %s)", err, got[0])
	}
}

func TestFetchEvents_SetsCreationDateFilter(t *testing.T) {
	svc := &mockAdminService{}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	windowEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)

	_, err := fetchEvents(t.Context(), svc, windowStart, windowEnd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if svc.capturedReq == nil {
		t.Fatal("ListEvents was not called")
	}
	rangeFilter, ok := svc.capturedReq.GetCreationDateFilter().(*adminpb.ListEventsRequest_Range)
	if !ok || rangeFilter.Range == nil {
		t.Fatal("CreationDateFilter was not set to a Range in request")
	}
	if !rangeFilter.Range.Since.AsTime().Equal(windowStart) {
		t.Errorf("CreationDateFilter.Since: got %v, want %v", rangeFilter.Range.Since.AsTime(), windowStart)
	}
	if !rangeFilter.Range.Until.AsTime().Equal(windowEnd) {
		t.Errorf("CreationDateFilter.Until: got %v, want %v", rangeFilter.Range.Until.AsTime(), windowEnd)
	}
	if got, want := svc.capturedReq.GetLimit(), uint32(1000); got != want {
		t.Errorf("Limit: got %d, want %d", got, want)
	}
	if !svc.capturedReq.GetAsc() {
		t.Error("Asc: got false, want true")
	}
	if got := svc.capturedReq.GetSequence(); got != 0 {
		t.Errorf("Sequence: got %d, want 0", got)
	}
}

func TestFetchEvents_PaginatesUsingLastEventSequence(t *testing.T) {
	firstPage := make([]*eventpb.Event, 1000)
	for index := range firstPage {
		firstPage[index] = &eventpb.Event{Sequence: uint64(index + 1)}
	}
	secondPage := []*eventpb.Event{{Sequence: 1001}}
	svc := &mockAdminService{eventPages: [][]*eventpb.Event{firstPage, secondPage}}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	windowEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)

	got, err := fetchEvents(t.Context(), svc, windowStart, windowEnd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1001 {
		t.Fatalf("got %d events, want 1001", len(got))
	}
	if len(svc.capturedReqs) != 2 {
		t.Fatalf("got %d ListEvents calls, want 2", len(svc.capturedReqs))
	}
	if got, want := svc.capturedReqs[0].GetSequence(), uint64(0); got != want {
		t.Errorf("first request sequence: got %d, want %d", got, want)
	}
	if got, want := svc.capturedReqs[1].GetSequence(), uint64(1000); got != want {
		t.Errorf("second request sequence: got %d, want %d", got, want)
	}
	for index, req := range svc.capturedReqs {
		if !req.GetAsc() {
			t.Errorf("request %d: Asc got false, want true", index)
		}
		if got, want := req.GetLimit(), uint32(1000); got != want {
			t.Errorf("request %d: Limit got %d, want %d", index, got, want)
		}
		rangeFilter, ok := req.GetCreationDateFilter().(*adminpb.ListEventsRequest_Range)
		if !ok || rangeFilter.Range == nil {
			t.Fatalf("request %d: CreationDateFilter was not set to a Range", index)
		}
		if !rangeFilter.Range.Since.AsTime().Equal(windowStart) || !rangeFilter.Range.Until.AsTime().Equal(windowEnd) {
			t.Errorf("request %d: date range changed between pages", index)
		}
	}
}

func TestFetchEvents_FullPageWithoutSequenceProgressReturnsError(t *testing.T) {
	fullPage := make([]*eventpb.Event, 1000)
	for index := range fullPage {
		fullPage[index] = &eventpb.Event{}
	}
	svc := &mockAdminService{eventPages: [][]*eventpb.Event{fullPage}}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	windowEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)

	if _, err := fetchEvents(t.Context(), svc, windowStart, windowEnd); err == nil {
		t.Fatal("expected error when pagination sequence does not advance")
	}
}

func TestFetchEvents_Error(t *testing.T) {
	svc := &mockAdminService{eventsErr: errors.New("api error")}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	windowEnd := time.Date(2026, 4, 21, 15, 15, 0, 0, time.UTC)

	if _, err := fetchEvents(t.Context(), svc, windowStart, windowEnd); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// auditEvents
// ---------------------------------------------------------------------------

func TestAuditEvents_MatchesPatterns(t *testing.T) {
	var logBuf strings.Builder
	origOutput := log.Writer()
	origFlags := log.Flags()
	log.SetOutput(&logBuf)
	log.SetFlags(0)
	defer log.SetOutput(origOutput)
	defer log.SetFlags(origFlags)

	events := []json.RawMessage{
		json.RawMessage(`{"type":{"type":"instance.member.added"},"editor":{"displayName":"alice"},"creationDate":"2026-04-21T15:05:00.000000Z"}`),
		json.RawMessage(`{"type":{"type":"project.application.added"},"editor":{"displayName":"bob"},"creationDate":"2026-04-21T15:05:00.000000Z"}`),
	}

	auditEvents(events, []string{`instance.member.*`})

	got := logBuf.String()
	if !strings.Contains(got, "AEVT: `instance.member.added`") {
		t.Fatalf("expected matching audit event to be logged, got %q", got)
	}
	if strings.Contains(got, "AEVT: `project.application.added`") {
		t.Fatalf("expected non-matching audit event to be skipped, got %q", got)
	}
}

func TestAuditEvents_NoMatchProducesNoAEVT(t *testing.T) {
	var logBuf strings.Builder
	log.SetOutput(&logBuf)
	log.SetFlags(0)
	defer log.SetOutput(io.Discard)

	events := []json.RawMessage{
		json.RawMessage(`{"type":{"type":"user.locked"},"editor":{"displayName":"x"}}`),
	}
	auditEvents(events, []string{`instance.member.*`})

	if strings.Contains(logBuf.String(), "AEVT:") {
		t.Errorf("expected no AEVT log, got: %s", logBuf.String())
	}
}

func TestEventEnvelope_ExtractsNestedType(t *testing.T) {
	var meta eventEnvelope
	input := []byte(`{"type":{"type":"instance.member.added"}}`)
	if err := json.Unmarshal(input, &meta); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got, want := meta.Type.Type, "instance.member.added"; got != want {
		t.Fatalf("type.type: got %q, want %q", got, want)
	}
}

// ---------------------------------------------------------------------------
// recordEventTime
// ---------------------------------------------------------------------------

func sqsMessageWithBody(body string) events.SQSMessage {
	return events.SQSMessage{Body: body}
}

func TestRecordEventTime_Valid(t *testing.T) {
	want := time.Date(2026, 9, 3, 0, 0, 0, 0, time.UTC)
	body, err := json.Marshal(eventBridgeEvent{Time: want})
	if err != nil {
		t.Fatalf("failed to marshal test event: %v", err)
	}

	got, err := recordEventTime(sqsMessageWithBody(string(body)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Equal(want) {
		t.Errorf("got %s, want %s", got, want)
	}
}

func TestRecordEventTime_MultipleRecords_ExtractsEach(t *testing.T) {
	first := time.Date(2026, 9, 3, 12, 0, 0, 0, time.UTC)
	second := first.Add(time.Hour)

	firstBody, err := json.Marshal(eventBridgeEvent{Time: first})
	if err != nil {
		t.Fatalf("failed to marshal test event: %v", err)
	}
	secondBody, err := json.Marshal(eventBridgeEvent{Time: second})
	if err != nil {
		t.Fatalf("failed to marshal test event: %v", err)
	}

	event := events.SQSEvent{Records: []events.SQSMessage{
		{Body: string(firstBody)},
		{Body: string(secondBody)},
	}}

	for i, want := range []time.Time{first, second} {
		got, err := recordEventTime(event.Records[i])
		if err != nil {
			t.Fatalf("unexpected error for record %d: %v", i, err)
		}
		if !got.Equal(want) {
			t.Errorf("record %d: got %s, want %s", i, got, want)
		}
	}
}

func TestRecordEventTime_InvalidJSON(t *testing.T) {
	if _, err := recordEventTime(sqsMessageWithBody("not-json")); err == nil {
		t.Fatal("expected error for invalid JSON body, got nil")
	}
}

func TestRecordEventTime_MissingTime(t *testing.T) {
	if _, err := recordEventTime(sqsMessageWithBody("{}")); err == nil {
		t.Fatal("expected error for missing time field, got nil")
	}
}

func TestRecordInvocation_ValidTypeAndTime(t *testing.T) {
	wantTime := time.Date(2026, 9, 3, 12, 0, 0, 0, time.FixedZone("offset", -4*60*60))
	body, err := json.Marshal(eventBridgeEvent{
		Time:           wantTime,
		InvocationType: string(invocationTypeHighAnomaly),
		WindowMinutes:  60,
	})
	if err != nil {
		t.Fatalf("failed to marshal test event: %v", err)
	}

	got, err := recordInvocation(sqsMessageWithBody(string(body)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Time.Equal(wantTime.UTC()) {
		t.Errorf("time: got %s, want %s", got.Time, wantTime.UTC())
	}
	if got.InvocationType != string(invocationTypeHighAnomaly) {
		t.Errorf("invocation: got %q, want %q", got.InvocationType, invocationTypeHighAnomaly)
	}
	if got.WindowMinutes != 60 {
		t.Errorf("window: got %d, want 60", got.WindowMinutes)
	}
}

func TestRecordInvocation_RejectsMissingTypeOrDuration(t *testing.T) {
	for _, body := range []string{
		`{"time":"2026-09-03T12:00:00Z"}`,
		`{"time":"2026-09-03T12:00:00Z","invocation_type":"unknown"}`,
		`{"time":"2026-09-03T12:00:00Z","invocation_type":"export"}`,
		`{"time":"2026-09-03T12:00:00Z","invocation_type":"export","window_minutes":0}`,
		`{"time":"2026-09-03T12:00:00Z","invocation_type":"high_anomaly"}`,
		`{"time":"2026-09-03T12:00:00Z","invocation_type":"high_anomaly","window_minutes":-1}`,
	} {
		if _, err := recordInvocation(sqsMessageWithBody(body)); err == nil {
			t.Errorf("expected an error for body %s", body)
		}
	}
}

func TestHighAnomalyEventThresholdsAreValid(t *testing.T) {
	seen := make(map[string]struct{}, len(eventsTypesHighAnomaly))
	for _, anomalyEvent := range eventsTypesHighAnomaly {
		if anomalyEvent.eventType == "" {
			t.Error("event type must not be empty")
		}
		if anomalyEvent.threshold < 0 {
			t.Errorf("threshold for %q must not be negative", anomalyEvent.eventType)
		}
		if _, ok := seen[anomalyEvent.eventType]; ok {
			t.Errorf("duplicate event type %q", anomalyEvent.eventType)
		}
		seen[anomalyEvent.eventType] = struct{}{}
	}
}

func TestCountHighAnomalyEvents_CountsOnlyConfiguredAnomalyTypes(t *testing.T) {
	input := []json.RawMessage{
		json.RawMessage(`{"type":{"type":"user.human.added"}}`),
		json.RawMessage(`{"type":{"type":"user.human.added"}}`),
		json.RawMessage(`{"type":{"type":"project.application.added"}}`),
	}

	got := countHighAnomalyEvents(input)
	if got["user.human.added"] != 2 {
		t.Errorf("user.human.added: got %d, want 2", got["user.human.added"])
	}
	if got["project.application.added"] != 0 {
		t.Errorf("project.application.added: got %d, want 0", got["project.application.added"])
	}
}

func TestAlertHighAnomalyEvents_AlertsOnlyAboveThreshold(t *testing.T) {
	var logBuf strings.Builder
	origOutput := log.Writer()
	origFlags := log.Flags()
	log.SetOutput(&logBuf)
	log.SetFlags(0)
	defer log.SetOutput(origOutput)
	defer log.SetFlags(origFlags)

	events := []json.RawMessage{
		json.RawMessage(`{"type":{"type":"user.human.added"}}`),
		json.RawMessage(`{"type":{"type":"user.human.added"}}`),
	}
	windowStart := time.Date(2026, 9, 3, 11, 0, 0, 0, time.UTC)
	windowEnd := windowStart.Add(time.Hour)

	anomalyTypes := []highAnomalyEvent{{eventType: "user.human.added", threshold: 2}}
	alertHighAnomalyEvents(events, anomalyTypes, windowStart, windowEnd)
	if strings.Contains(logBuf.String(), "High event count for") {
		t.Fatalf("threshold-equal count should not alert, got %q", logBuf.String())
	}

	anomalyTypes[0].threshold = 1
	alertHighAnomalyEvents(events, anomalyTypes, windowStart, windowEnd)
	if !strings.Contains(logBuf.String(), "AEVT: High event count for `user.human.added` → `2` counted with threshold `1`") {
		t.Fatalf("expected above-threshold AEVT alert, got %q", logBuf.String())
	}
}

// ---------------------------------------------------------------------------
// silence logs in test output
// ---------------------------------------------------------------------------

func TestMain(m *testing.M) {
	log.SetOutput(io.Discard)
	os.Exit(m.Run())
}
