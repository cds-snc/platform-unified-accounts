package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// env-var parsers
// ---------------------------------------------------------------------------

func TestParseInactiveDays_Valid(t *testing.T) {
	t.Setenv("INACTIVE_DAYS", "90")
	got, err := parseInactiveDays()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 90 {
		t.Errorf("got %d, want 90", got)
	}
}

func TestParseInactiveDays_NotInteger(t *testing.T) {
	t.Setenv("INACTIVE_DAYS", "ninety")
	if _, err := parseInactiveDays(); err == nil {
		t.Fatal("expected error for non-integer, got nil")
	}
}

func TestParseInactiveDays_Zero(t *testing.T) {
	t.Setenv("INACTIVE_DAYS", "0")
	if _, err := parseInactiveDays(); err == nil {
		t.Fatal("expected error for zero value, got nil")
	}
}

func TestParseInactiveDays_Negative(t *testing.T) {
	t.Setenv("INACTIVE_DAYS", "-1")
	if _, err := parseInactiveDays(); err == nil {
		t.Fatal("expected error for negative value, got nil")
	}
}

func TestParsePageLimit_Default(t *testing.T) {
	t.Setenv("PAGE_LIMIT", "")
	got, err := parsePageLimit()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != defaultPageLimit {
		t.Errorf("got %d, want %d", got, defaultPageLimit)
	}
}

func TestParsePageLimit_Valid(t *testing.T) {
	t.Setenv("PAGE_LIMIT", "250")
	got, err := parsePageLimit()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 250 {
		t.Errorf("got %d, want 250", got)
	}
}

func TestParsePageLimit_NotInteger(t *testing.T) {
	t.Setenv("PAGE_LIMIT", "big")
	if _, err := parsePageLimit(); err == nil {
		t.Fatal("expected error for non-integer, got nil")
	}
}

func TestParsePageLimit_OutOfRange(t *testing.T) {
	for _, v := range []string{"0", "-5", "5000"} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("PAGE_LIMIT", v)
			if _, err := parsePageLimit(); err == nil {
				t.Fatalf("expected error for %q, got nil", v)
			}
		})
	}
}

func TestParseDryRun_Default(t *testing.T) {
	t.Setenv("DRY_RUN", "")
	got, err := parseDryRun()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got {
		t.Errorf("got true, want false")
	}
}

func TestParseDryRun_TrueValues(t *testing.T) {
	for _, v := range []string{"true", "1", "TRUE", "True"} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("DRY_RUN", v)
			got, err := parseDryRun()
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !got {
				t.Errorf("got false, want true")
			}
		})
	}
}

func TestParseDryRun_FalseValues(t *testing.T) {
	for _, v := range []string{"false", "0", "FALSE"} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("DRY_RUN", v)
			got, err := parseDryRun()
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got {
				t.Errorf("got true, want false")
			}
		})
	}
}

func TestParseDryRun_Invalid(t *testing.T) {
	t.Setenv("DRY_RUN", "yes-please")
	if _, err := parseDryRun(); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// time helpers
// ---------------------------------------------------------------------------

func TestFormatTimestamp_RFC3339Microseconds(t *testing.T) {
	dt := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	if got, want := formatTimestamp(dt), "2026-04-21T15:00:00.000000Z"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormatTimestamp_ConvertsToUTC(t *testing.T) {
	loc, _ := time.LoadLocation("America/Toronto")
	dt := time.Date(2026, 4, 21, 11, 0, 0, 0, loc) // 15:00 UTC
	if got, want := formatTimestamp(dt), "2026-04-21T15:00:00.000000Z"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestParseZitadelTime_RFC3339Nano(t *testing.T) {
	got, err := parseZitadelTime("2026-04-21T15:00:00.123456Z")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := time.Date(2026, 4, 21, 15, 0, 0, 123456000, time.UTC)
	if !got.Equal(want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestParseZitadelTime_RFC3339(t *testing.T) {
	got, err := parseZitadelTime("2026-04-21T15:00:00Z")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := time.Date(2026, 4, 21, 15, 0, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestParseZitadelTime_Empty(t *testing.T) {
	if _, err := parseZitadelTime(""); err == nil {
		t.Fatal("expected error for empty string, got nil")
	}
}

func TestParseZitadelTime_Invalid(t *testing.T) {
	if _, err := parseZitadelTime("not-a-time"); err == nil {
		t.Fatal("expected error for invalid time, got nil")
	}
}

// ---------------------------------------------------------------------------
// doJSONRequest
// ---------------------------------------------------------------------------

func TestDoJSONRequest_SendsBodyAndParsesResponse(t *testing.T) {
	type reqT struct {
		Hello string `json:"hello"`
	}
	type respT struct {
		Echo string `json:"echo"`
	}

	var gotMethod, gotPath, gotCT, gotAuth string
	var gotBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotCT = r.Header.Get("Content-Type")
		gotAuth = r.Header.Get("Authorization")
		gotBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"echo": "world"})
	}))
	defer srv.Close()

	var out respT
	err := doJSONRequest(t.Context(), srv.Client(), srv.URL, "/api/test", "abc", http.MethodPost, reqT{Hello: "world"}, &out)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotMethod != http.MethodPost {
		t.Errorf("method: got %q, want POST", gotMethod)
	}
	if gotPath != "/api/test" {
		t.Errorf("path: got %q", gotPath)
	}
	if gotCT != "application/json" {
		t.Errorf("Content-Type: got %q", gotCT)
	}
	if gotAuth != "Bearer abc" {
		t.Errorf("Authorization: got %q", gotAuth)
	}
	if !strings.Contains(string(gotBody), `"hello":"world"`) {
		t.Errorf("body: got %q", gotBody)
	}
	if out.Echo != "world" {
		t.Errorf("decoded: got %q", out.Echo)
	}
}

func TestDoJSONRequest_NilBodyOmitsContentType(t *testing.T) {
	var gotCT string
	var gotLen int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotCT = r.Header.Get("Content-Type")
		gotLen = r.ContentLength
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := doJSONRequest(t.Context(), srv.Client(), srv.URL, "/", "tok", http.MethodPost, nil, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotCT != "" {
		t.Errorf("Content-Type: got %q, want empty", gotCT)
	}
	if gotLen != 0 {
		t.Errorf("ContentLength: got %d, want 0", gotLen)
	}
}

func TestDoJSONRequest_TrailingSlashStripped(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := doJSONRequest(t.Context(), srv.Client(), srv.URL+"/", "/v2/users", "tok", http.MethodPost, nil, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotPath != "/v2/users" {
		t.Errorf("path: got %q", gotPath)
	}
}

func TestDoJSONRequest_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "forbidden", http.StatusForbidden)
	}))
	defer srv.Close()

	err := doJSONRequest(t.Context(), srv.Client(), srv.URL, "/", "tok", http.MethodPost, nil, nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP 403") {
		t.Errorf("error should mention status: got %v", err)
	}
}

func TestDoJSONRequest_SetsHostHeaderWhenConfigured(t *testing.T) {
	var gotHost string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost = r.Host
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	orig := zitadelHost
	zitadelHost = "zitadel.example.com"
	defer func() { zitadelHost = orig }()

	if err := doJSONRequest(t.Context(), srv.Client(), srv.URL, "/", "tok", http.MethodPost, nil, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotHost != "zitadel.example.com" {
		t.Errorf("Host: got %q, want zitadel.example.com", gotHost)
	}
}

func TestDoJSONRequest_DeleteMethodSucceeds(t *testing.T) {
	var gotMethod, gotPath, gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := doJSONRequest(t.Context(), srv.Client(), srv.URL, "/v2/users/u1", "tok", http.MethodDelete, nil, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotMethod != http.MethodDelete {
		t.Errorf("method: got %q, want DELETE", gotMethod)
	}
	if gotPath != "/v2/users/u1" {
		t.Errorf("path: got %q", gotPath)
	}
	if gotAuth != "Bearer tok" {
		t.Errorf("Authorization: got %q", gotAuth)
	}
}

func TestDoJSONRequest_DeleteHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer srv.Close()

	err := doJSONRequest(t.Context(), srv.Client(), srv.URL, "/v2/users/u1", "tok", http.MethodDelete, nil, nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("error should mention status: got %v", err)
	}
}

// ---------------------------------------------------------------------------
// listActiveUsers
// ---------------------------------------------------------------------------

func TestListActiveUsers_SinglePage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"result": []map[string]any{
				{"userId": "u1", "username": "a", "state": userStateActive},
				{"userId": "u2", "username": "b", "state": userStateActive},
			},
		})
	}))
	defer srv.Close()

	got, err := listActiveUsers(t.Context(), srv.Client(), srv.URL, "tok", 100)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d users, want 2", len(got))
	}
	if got[0].UserID != "u1" || got[1].UserID != "u2" {
		t.Errorf("unexpected users: %+v", got)
	}
}

func TestListActiveUsers_SendsCorrectQuery(t *testing.T) {
	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		json.NewDecoder(r.Body).Decode(&gotBody)
		json.NewEncoder(w).Encode(map[string]any{"result": []any{}})
	}))
	defer srv.Close()

	_, err := listActiveUsers(t.Context(), srv.Client(), srv.URL, "tok", 50)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotPath != "/v2/users" {
		t.Errorf("path: got %q", gotPath)
	}
	query, ok := gotBody["query"].(map[string]any)
	if !ok {
		t.Fatalf("body missing query: %+v", gotBody)
	}
	if query["limit"].(float64) != 50 {
		t.Errorf("limit: got %v", query["limit"])
	}
	if query["offset"].(string) != "0" {
		t.Errorf("offset: got %v", query["offset"])
	}
	queries, ok := gotBody["queries"].([]any)
	if !ok || len(queries) == 0 {
		t.Fatalf("body missing queries: %+v", gotBody)
	}
	stateQuery := queries[0].(map[string]any)["stateQuery"].(map[string]any)
	if stateQuery["state"] != userStateActive {
		t.Errorf("stateQuery: got %v", stateQuery)
	}
}

func TestListActiveUsers_PagesUntilShortResponse(t *testing.T) {
	var calls int
	var offsets []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		offsets = append(offsets, body["query"].(map[string]any)["offset"].(string))
		calls++
		var result []map[string]any
		switch calls {
		case 1:
			result = []map[string]any{{"userId": "u1"}, {"userId": "u2"}}
		case 2:
			result = []map[string]any{{"userId": "u3"}, {"userId": "u4"}}
		case 3:
			result = []map[string]any{{"userId": "u5"}}
		}
		json.NewEncoder(w).Encode(map[string]any{"result": result})
	}))
	defer srv.Close()

	got, err := listActiveUsers(t.Context(), srv.Client(), srv.URL, "tok", 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 5 {
		t.Errorf("got %d users, want 5", len(got))
	}
	if calls != 3 {
		t.Errorf("calls: got %d, want 3", calls)
	}
	wantOffsets := []string{"0", "2", "4"}
	for i, o := range wantOffsets {
		if offsets[i] != o {
			t.Errorf("offset[%d]: got %s, want %s", i, offsets[i], o)
		}
	}
}

func TestListActiveUsers_EmptyResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"result": []any{}})
	}))
	defer srv.Close()

	got, err := listActiveUsers(t.Context(), srv.Client(), srv.URL, "tok", 100)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d users, want 0", len(got))
	}
}

func TestListActiveUsers_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	if _, err := listActiveUsers(t.Context(), srv.Client(), srv.URL, "tok", 100); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// isEmailVerified
// ---------------------------------------------------------------------------

func TestIsEmailVerified_Verified(t *testing.T) {
	u := user{Human: &userHuman{Email: &userEmail{IsVerified: true}}}
	if !isEmailVerified(u) {
		t.Error("got false, want true")
	}
}

func TestIsEmailVerified_NotVerified(t *testing.T) {
	u := user{Human: &userHuman{Email: &userEmail{IsVerified: false}}}
	if isEmailVerified(u) {
		t.Error("got true, want false")
	}
}

func TestIsEmailVerified_NilHuman(t *testing.T) {
	u := user{Human: nil}
	if isEmailVerified(u) {
		t.Error("got true, want false for nil human")
	}
}

func TestIsEmailVerified_NilEmail(t *testing.T) {
	u := user{Human: &userHuman{Email: nil}}
	if isEmailVerified(u) {
		t.Error("got true, want false for nil email")
	}
}

// ---------------------------------------------------------------------------
// listAuthenticationFactors
// ---------------------------------------------------------------------------

func TestListAuthenticationFactors_ReturnsFactor(t *testing.T) {
	var gotPath string
	var gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotMethod = r.Method
		json.NewEncoder(w).Encode(map[string]any{
			"result": []map[string]any{
				{"state": "AUTH_FACTOR_STATE_READY"},
			},
		})
	}))
	defer srv.Close()

	factors, err := listAuthenticationFactors(t.Context(), srv.Client(), srv.URL, "tok", "user-123")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(factors) != 1 {
		t.Fatalf("got %d factors, want 1", len(factors))
	}
	if factors[0].State != "AUTH_FACTOR_STATE_READY" {
		t.Errorf("state: got %q", factors[0].State)
	}
	if gotPath != "/v2/users/user-123/authentication_factors/_search" {
		t.Errorf("path: got %q", gotPath)
	}
	if gotMethod != http.MethodPost {
		t.Errorf("method: got %q, want POST", gotMethod)
	}
}

func TestListAuthenticationFactors_Empty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"result": []any{}})
	}))
	defer srv.Close()

	factors, err := listAuthenticationFactors(t.Context(), srv.Client(), srv.URL, "tok", "u1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(factors) != 0 {
		t.Errorf("got %d factors, want 0", len(factors))
	}
}

func TestListAuthenticationFactors_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusInternalServerError)
	}))
	defer srv.Close()

	if _, err := listAuthenticationFactors(t.Context(), srv.Client(), srv.URL, "tok", "u1"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// hasCompletedRegistration
// ---------------------------------------------------------------------------

func TestHasCompletedRegistration_EmailNotVerified_SkipsFactorCheck(t *testing.T) {
	// Server should never be called when email is not verified.
	var called bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	u := user{
		UserID: "u1",
		Human:  &userHuman{Email: &userEmail{IsVerified: false}},
	}
	got, err := hasCompletedRegistration(t.Context(), srv.Client(), srv.URL, "tok", u)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got {
		t.Error("got true, want false")
	}
	if called {
		t.Error("auth factors endpoint should not be called when email is not verified")
	}
}

func TestHasCompletedRegistration_EmailVerifiedNoFactors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"result": []any{}})
	}))
	defer srv.Close()

	u := user{
		UserID: "u1",
		Human:  &userHuman{Email: &userEmail{IsVerified: true}},
	}
	got, err := hasCompletedRegistration(t.Context(), srv.Client(), srv.URL, "tok", u)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got {
		t.Error("got true, want false (no factors)")
	}
}

func TestHasCompletedRegistration_EmailVerifiedWithFactors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"result": []map[string]any{{"state": "AUTH_FACTOR_STATE_READY"}},
		})
	}))
	defer srv.Close()

	u := user{
		UserID: "u1",
		Human:  &userHuman{Email: &userEmail{IsVerified: true}},
	}
	got, err := hasCompletedRegistration(t.Context(), srv.Client(), srv.URL, "tok", u)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got {
		t.Error("got false, want true")
	}
}

func TestHasCompletedRegistration_FactorAPIError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	u := user{
		UserID: "u1",
		Human:  &userHuman{Email: &userEmail{IsVerified: true}},
	}
	if _, err := hasCompletedRegistration(t.Context(), srv.Client(), srv.URL, "tok", u); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// deleteUser
// ---------------------------------------------------------------------------

func TestDeleteUser_Success(t *testing.T) {
	var gotPath, gotMethod, gotAuth string
	var gotBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotMethod = r.Method
		gotAuth = r.Header.Get("Authorization")
		gotBody, _ = io.ReadAll(r.Body)
		json.NewEncoder(w).Encode(map[string]any{"details": map[string]any{}})
	}))
	defer srv.Close()

	if err := deleteUser(t.Context(), srv.Client(), srv.URL, "tok", "user-abc"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotPath != "/v2/users/user-abc" {
		t.Errorf("path: got %q", gotPath)
	}
	if gotMethod != http.MethodDelete {
		t.Errorf("method: got %q, want DELETE", gotMethod)
	}
	if gotAuth != "Bearer tok" {
		t.Errorf("auth: got %q", gotAuth)
	}
	if len(gotBody) != 0 {
		t.Errorf("body: got %q, want empty", gotBody)
	}
}

func TestDeleteUser_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer srv.Close()

	err := deleteUser(t.Context(), srv.Client(), srv.URL, "tok", "user-abc")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "user-abc") {
		t.Errorf("error should include user id: %v", err)
	}
}

// ---------------------------------------------------------------------------
// processUsers
// ---------------------------------------------------------------------------

// fakeZitadel handles authentication_factors and delete requests for a
// controlled set of users.
type fakeZitadel struct {
	mu sync.Mutex
	// per-user: auth factors to return (nil or empty = no factors)
	authFactors map[string][]string
	// per-user: HTTP status to return on delete (0 = success)
	deleteErrFor map[string]int
	deleted      []string
}

func (f *fakeZitadel) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		path := r.URL.Path
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(path, "/authentication_factors/_search"):
			// /v2/users/{userID}/authentication_factors/_search
			trimmed := strings.TrimPrefix(path, "/v2/users/")
			userID := strings.TrimSuffix(trimmed, "/authentication_factors/_search")
			var result []map[string]any
			for _, s := range f.authFactors[userID] {
				result = append(result, map[string]any{"state": s})
			}
			if result == nil {
				result = []map[string]any{}
			}
			json.NewEncoder(w).Encode(map[string]any{"result": result})
		case r.Method == http.MethodDelete && strings.HasPrefix(path, "/v2/users/"):
			userID := strings.TrimPrefix(path, "/v2/users/")
			if status := f.deleteErrFor[userID]; status != 0 {
				http.Error(w, "no", status)
				return
			}
			f.deleted = append(f.deleted, userID)
			json.NewEncoder(w).Encode(map[string]any{"details": map[string]any{}})
		default:
			http.NotFound(w, r)
		}
	})
}

// mkUser builds a user with the given id, creation date, and email verification state.
func mkUser(id, created string, emailVerified bool) user {
	u := user{UserID: id, Username: id}
	u.Details.CreationDate = created
	u.Human = &userHuman{Email: &userEmail{IsVerified: emailVerified}}
	return u
}

func TestProcessUsers_DeletesUsersWithIncompleteRegistration(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	fz := &fakeZitadel{
		authFactors: map[string][]string{
			// email-verified-with-factors: registration complete → keep
			"complete": {"AUTH_FACTOR_STATE_READY"},
			// email-verified-no-factors: incomplete → delete
			// email-not-verified: no authFactors entry, incomplete → delete
		},
	}
	srv := httptest.NewServer(fz.handler())
	defer srv.Close()

	old := "2026-01-01T00:00:00.000000Z"
	users := []user{
		mkUser("complete", old, true),
		mkUser("verified-no-factors", old, true),
		mkUser("unverified", old, false),
	}

	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok", users, threshold, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersChecked != 3 {
		t.Errorf("checked: got %d, want 3", resp.UsersChecked)
	}
	if resp.UsersDeleted != 2 {
		t.Errorf("deleted: got %d, want 2", resp.UsersDeleted)
	}
	if len(fz.deleted) != 2 {
		t.Errorf("server-side deleted: got %v", fz.deleted)
	}
}

func TestProcessUsers_DryRunSkipsDeleteCall(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	fz := &fakeZitadel{authFactors: map[string][]string{}}
	srv := httptest.NewServer(fz.handler())
	defer srv.Close()

	users := []user{mkUser("old-unverified", "2026-01-01T00:00:00.000000Z", false)}

	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok", users, threshold, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 1 {
		t.Errorf("deleted count: got %d, want 1", resp.UsersDeleted)
	}
	if !resp.DryRun {
		t.Error("DryRun: got false, want true")
	}
	if len(fz.deleted) != 0 {
		t.Errorf("server-side deleted under dry-run: got %v, want none", fz.deleted)
	}
}

func TestProcessUsers_KeepsUsersWithinGracePeriod(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	fz := &fakeZitadel{authFactors: map[string][]string{}}
	srv := httptest.NewServer(fz.handler())
	defer srv.Close()

	// User created after threshold (within grace period) with incomplete registration.
	users := []user{mkUser("new-unverified", "2026-05-30T00:00:00.000000Z", false)}

	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok", users, threshold, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 0 {
		t.Errorf("deleted: got %d, want 0 (within grace period)", resp.UsersDeleted)
	}
	if len(fz.deleted) != 0 {
		t.Errorf("server-side deleted: got %v", fz.deleted)
	}
}

func TestProcessUsers_DeleteFailureIsSkippedNotFatal(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	fz := &fakeZitadel{
		authFactors:  map[string][]string{},
		deleteErrFor: map[string]int{"u1": http.StatusInternalServerError},
	}
	srv := httptest.NewServer(fz.handler())
	defer srv.Close()

	old := "2026-01-01T00:00:00.000000Z"
	users := []user{
		mkUser("u1", old, false),
		mkUser("u2", old, false),
	}
	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok", users, threshold, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 1 {
		t.Errorf("deleted: got %d, want 1", resp.UsersDeleted)
	}
	if resp.UsersSkipped != 1 {
		t.Errorf("skipped: got %d, want 1", resp.UsersSkipped)
	}
	if len(fz.deleted) != 1 || fz.deleted[0] != "u2" {
		t.Errorf("server-side deleted: got %v", fz.deleted)
	}
}

func TestProcessUsers_FactorLookupErrorIsSkipped(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	// Server returns 500 on every request.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	// Email is verified so the auth factors endpoint will be called and fail.
	users := []user{mkUser("u1", "2026-01-01T00:00:00.000000Z", true)}
	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok", users, threshold, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 0 {
		t.Errorf("deleted: got %d, want 0", resp.UsersDeleted)
	}
	if resp.UsersSkipped != 1 {
		t.Errorf("skipped: got %d, want 1", resp.UsersSkipped)
	}
}

func TestProcessUsers_ExactlyAtThresholdIsKept(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	fz := &fakeZitadel{authFactors: map[string][]string{}}
	srv := httptest.NewServer(fz.handler())
	defer srv.Close()

	// Created exactly at threshold.
	created := threshold.Format("2006-01-02T15:04:05.000000Z")
	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok",
		[]user{mkUser("boundary", created, false)},
		threshold, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 0 {
		t.Errorf("deleted: got %d, want 0 (exactly at threshold should be kept)", resp.UsersDeleted)
	}
}

func TestProcessUsers_BadCreationDateIsSkipped(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	threshold := now.AddDate(0, 0, -7)

	fz := &fakeZitadel{authFactors: map[string][]string{}}
	srv := httptest.NewServer(fz.handler())
	defer srv.Close()

	u := user{UserID: "u1", Username: "u1"}
	u.Details.CreationDate = "not-a-date"
	u.Human = &userHuman{Email: &userEmail{IsVerified: false}}

	resp, err := processUsers(t.Context(), srv.Client(), srv.URL, "tok", []user{u}, threshold, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 0 {
		t.Errorf("deleted: got %d, want 0", resp.UsersDeleted)
	}
	if resp.UsersSkipped != 1 {
		t.Errorf("skipped: got %d, want 1", resp.UsersSkipped)
	}
}

// ---------------------------------------------------------------------------
// handler – integration via globals
// ---------------------------------------------------------------------------

func setHandlerGlobals(t *testing.T, zURL, token string, days, page int, dry bool) func() {
	t.Helper()
	origURL := zitadelURL
	origInitErr := initErr
	origDays := inactiveDays
	origPage := pageLimit
	origDry := dryRun

	tokenMu.Lock()
	origToken := cachedToken
	cachedToken = token
	tokenMu.Unlock()

	zitadelURL = zURL
	initErr = nil
	inactiveDays = days
	pageLimit = page
	dryRun = dry

	return func() {
		zitadelURL = origURL
		initErr = origInitErr
		inactiveDays = origDays
		pageLimit = origPage
		dryRun = origDry
		tokenMu.Lock()
		cachedToken = origToken
		tokenMu.Unlock()
	}
}

// fullFakeZitadel responds to ListUsers + auth factors + delete.
func fullFakeZitadel(users []map[string]any, fz *fakeZitadel) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v2/users":
			json.NewEncoder(w).Encode(map[string]any{"result": users})
		default:
			fz.handler().ServeHTTP(w, r)
		}
	})
}

func TestHandler_DeletesUsersWithIncompleteRegistration(t *testing.T) {
	fz := &fakeZitadel{
		authFactors: map[string][]string{
			// u2 has email verified AND a factor → complete registration
			"u2": {"AUTH_FACTOR_STATE_READY"},
		},
	}
	users := []map[string]any{
		{
			"userId": "u1", "username": "a", "state": userStateActive,
			"details": map[string]any{"creationDate": "2020-01-01T00:00:00.000000Z"},
			"human":   map[string]any{"email": map[string]any{"isVerified": false}},
		},
		{
			"userId": "u2", "username": "b", "state": userStateActive,
			"details": map[string]any{"creationDate": "2020-01-01T00:00:00.000000Z"},
			"human":   map[string]any{"email": map[string]any{"isVerified": true}},
		},
	}
	srv := httptest.NewServer(fullFakeZitadel(users, fz))
	defer srv.Close()

	restore := setHandlerGlobals(t, srv.URL, "tok", 30, 100, false)
	defer restore()

	resp, err := handler(t.Context())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersChecked != 2 {
		t.Errorf("checked: got %d, want 2", resp.UsersChecked)
	}
	if resp.UsersDeleted != 1 {
		t.Errorf("deleted: got %d, want 1", resp.UsersDeleted)
	}
	if len(fz.deleted) != 1 || fz.deleted[0] != "u1" {
		t.Errorf("server-side deleted: got %v", fz.deleted)
	}
}

func TestHandler_RespectsInitErr(t *testing.T) {
	origErr := initErr
	initErr = fmt.Errorf("bad config")
	defer func() { initErr = origErr }()

	if _, err := handler(t.Context()); err == nil {
		t.Fatal("expected init error, got nil")
	}
}

// ---------------------------------------------------------------------------
// silence logs in test output to keep things clean
// ---------------------------------------------------------------------------

func TestMain(m *testing.M) {
	log.SetOutput(&bytes.Buffer{})
	m.Run()
}

// Sanity check to ensure context.Context import is used even if tests evolve.
var _ context.Context = context.Background()
