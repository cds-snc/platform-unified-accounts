package main

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAuditEvents_MatchesPatterns(t *testing.T) {
	var logBuffer bytes.Buffer
	origOutput := log.Writer()
	origFlags := log.Flags()
	log.SetOutput(&logBuffer)
	log.SetFlags(0)
	defer log.SetOutput(origOutput)
	defer log.SetFlags(origFlags)

	events := []json.RawMessage{
		json.RawMessage(`{"type":{"type":"instance.member.added"},"editor":{"displayName":"alice"},"creationDate":"2026-04-21T15:05:00.000000Z"}`),
		json.RawMessage(`{"type":{"type":"project.application.added"},"editor":{"displayName":"bob"},"creationDate":"2026-04-21T15:05:00.000000Z"}`),
	}

	auditEvents(events, []string{`instance.member.*`})

	got := logBuffer.String()
	if !strings.Contains(got, "AEVT: `instance.member.added`") {
		t.Fatalf("expected matching audit event to be logged, got %q", got)
	}
	if strings.Contains(got, "AEVT: `project.application.added`") {
		t.Fatalf("expected non-matching audit event to be skipped, got %q", got)
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

func TestComputeWindow_5MinuteWindow(t *testing.T) {
	now := time.Date(2026, 4, 21, 15, 8, 30, 0, time.UTC)
	start, end := computeWindow(now, 5)
	wantStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, 4, 21, 15, 5, 0, 0, time.UTC)
	if !start.Equal(wantStart) {
		t.Errorf("start: got %v, want %v", start, wantStart)
	}
	if !end.Equal(wantEnd) {
		t.Errorf("end: got %v, want %v", end, wantEnd)
	}
}

// ---------------------------------------------------------------------------
// formatTimestamp
// ---------------------------------------------------------------------------

func TestFormatTimestamp_RFC3339(t *testing.T) {
	dt := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	got := formatTimestamp(dt)
	want := "2026-04-21T15:00:00.000000Z"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormatTimestamp_ZeroPadsSingleDigitFields(t *testing.T) {
	dt := time.Date(2026, 1, 5, 3, 4, 9, 0, time.UTC)
	got := formatTimestamp(dt)
	want := "2026-01-05T03:04:09.000000Z"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// ---------------------------------------------------------------------------
// fetchEvents
// ---------------------------------------------------------------------------

func TestFetchEvents_SinglePageResult(t *testing.T) {
	events := []map[string]any{
		{"sequence": 1, "creationDate": "2026-04-21T15:05:00.000000Z"},
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": events})
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	got, err := fetchEvents(t.Context(), srv.Client(), srv.URL, "test-token", windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 1 {
		t.Errorf("got %d events, want 1", len(got))
	}
}

func TestFetchEvents_EmptyResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	got, err := fetchEvents(t.Context(), srv.Client(), srv.URL, "test-token", windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d events, want 0", len(got))
	}
}

func TestFetchEvents_BearerTokenInHeader(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	_, err := fetchEvents(t.Context(), srv.Client(), srv.URL, "my-secret-token", windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotAuth != "Bearer my-secret-token" {
		t.Errorf("Authorization header: got %q, want %q", gotAuth, "Bearer my-secret-token")
	}
}

func TestFetchEvents_ContentTypeHeader(t *testing.T) {
	var gotCT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotCT = r.Header.Get("Content-Type")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	_, err := fetchEvents(t.Context(), srv.Client(), srv.URL, "token", windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotCT != "application/json" {
		t.Errorf("Content-Type: got %q, want %q", gotCT, "application/json")
	}
}

func TestFetchEvents_FromParamInRequestBody(t *testing.T) {
	var gotFrom string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		gotFrom, _ = body["from"].(string)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	_, err := fetchEvents(t.Context(), srv.Client(), srv.URL, "token", windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := "2026-04-21T15:00:00.000000Z"
	if gotFrom != want {
		t.Errorf("from param: got %q, want %q", gotFrom, want)
	}
}

func TestFetchEvents_TrailingSlashStripped(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	_, err := fetchEvents(t.Context(), srv.Client(), srv.URL+"/", "token", windowStart)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotPath != "/admin/v1/events/_search" {
		t.Errorf("path: got %q, want %q", gotPath, "/admin/v1/events/_search")
	}
}

func TestFetchEvents_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer srv.Close()

	windowStart := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	_, err := fetchEvents(t.Context(), srv.Client(), srv.URL, "bad-token", windowStart)
	if err == nil {
		t.Fatal("expected error for HTTP 401, got nil")
	}
}

// ---------------------------------------------------------------------------
// handler – no events → no S3 upload
// ---------------------------------------------------------------------------

// setHandlerGlobals overwrites the package-level globals used by handler and
// returns a restore function to be deferred by the caller.
func setHandlerGlobals(t *testing.T, zURL, bucket, token string) func() {
	t.Helper()
	origURL := zitadelURL
	origBucket := s3Bucket
	origS3 := s3Client
	origInitErr := initErr
	origWM := windowMinutes

	tokenMu.Lock()
	origToken := cachedToken
	cachedToken = token
	tokenMu.Unlock()

	zitadelURL = zURL
	s3Bucket = bucket
	s3Client = nil // will panic if saveToS3 is called, acting as an assertion
	initErr = nil
	windowMinutes = 15

	return func() {
		zitadelURL = origURL
		s3Bucket = origBucket
		s3Client = origS3
		initErr = origInitErr
		windowMinutes = origWM
		tokenMu.Lock()
		cachedToken = origToken
		tokenMu.Unlock()
	}
}

func TestHandler_NoEvents_SkipsS3Upload(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	restore := setHandlerGlobals(t, srv.URL, "test-bucket", "test-token")
	defer restore()

	resp, err := handler(t.Context())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.S3Key != "" {
		t.Errorf("S3Key: got %q, want empty (no upload expected when there are no events)", resp.S3Key)
	}
	if resp.EventsCount != 0 {
		t.Errorf("EventsCount: got %d, want 0", resp.EventsCount)
	}
	if resp.StatusCode != 200 {
		t.Errorf("StatusCode: got %d, want 200", resp.StatusCode)
	}
}

func TestHandler_NoEvents_WindowFieldsPopulated(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"events": []any{}})
	}))
	defer srv.Close()

	restore := setHandlerGlobals(t, srv.URL, "test-bucket", "test-token")
	defer restore()

	resp, err := handler(t.Context())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.WindowStart == "" {
		t.Error("WindowStart: got empty, want populated")
	}
	if resp.WindowEnd == "" {
		t.Error("WindowEnd: got empty, want populated")
	}
}
