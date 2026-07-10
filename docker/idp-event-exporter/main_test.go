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
	"google.golang.org/protobuf/types/known/timestamppb"
)

// ---------------------------------------------------------------------------
// Mock adminService
// ---------------------------------------------------------------------------

type mockAdminService struct {
	// capturedReq holds the last ListEventsRequest received.
	capturedReq *adminpb.ListEventsRequest

	events    []*eventpb.Event
	eventsErr error
}

func (m *mockAdminService) ListEvents(_ context.Context, req *adminpb.ListEventsRequest, _ ...grpc.CallOption) (*adminpb.ListEventsResponse, error) {
	m.capturedReq = req
	if m.eventsErr != nil {
		return nil, m.eventsErr
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

	got, err := fetchEvents(t.Context(), svc, windowStart)
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

	got, err := fetchEvents(t.Context(), svc, windowStart)
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

	_, err := fetchEvents(t.Context(), svc, windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if svc.capturedReq == nil {
		t.Fatal("ListEvents was not called")
	}
	got := svc.capturedReq.GetCreationDate()
	if got == nil {
		t.Fatal("CreationDate was not set in request")
	}
	want := timestamppb.New(windowStart)
	if !got.AsTime().Equal(want.AsTime()) {
		t.Errorf("CreationDate: got %v, want %v", got.AsTime(), want.AsTime())
	}
}

func TestFetchEvents_Error(t *testing.T) {
	svc := &mockAdminService{eventsErr: errors.New("api error")}
	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)

	if _, err := fetchEvents(t.Context(), svc, windowStart); err == nil {
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
// silence logs in test output
// ---------------------------------------------------------------------------

func TestMain(m *testing.M) {
	log.SetOutput(io.Discard)
	os.Exit(m.Run())
}
