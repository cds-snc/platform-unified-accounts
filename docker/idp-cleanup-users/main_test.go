package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"sync"
	"testing"
	"time"

	objectv2 "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/object/v2"
	userv2 "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/user/v2"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// ---------------------------------------------------------------------------
// Mock userService
// ---------------------------------------------------------------------------

type mockUserService struct {
	mu sync.Mutex

	// ListUsers: each call returns the next page sequentially.
	listUsersPages [][]*userv2.User
	listUsersCall  int
	listUsersErr   error

	// ListAuthenticationFactors: keyed by userID.
	authFactors    map[string][]*userv2.AuthFactor
	authFactorsErr map[string]error

	// DeleteUser: optional per-user error; records deleted IDs.
	deleteErr map[string]error
	deleted   []string
}

func (m *mockUserService) ListUsers(_ context.Context, _ *userv2.ListUsersRequest, _ ...grpc.CallOption) (*userv2.ListUsersResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.listUsersErr != nil {
		return nil, m.listUsersErr
	}
	idx := m.listUsersCall
	m.listUsersCall++
	if idx < len(m.listUsersPages) {
		return &userv2.ListUsersResponse{Result: m.listUsersPages[idx]}, nil
	}
	return &userv2.ListUsersResponse{}, nil
}

func (m *mockUserService) ListAuthenticationFactors(_ context.Context, req *userv2.ListAuthenticationFactorsRequest, _ ...grpc.CallOption) (*userv2.ListAuthenticationFactorsResponse, error) {
	if m.authFactorsErr != nil {
		if err, ok := m.authFactorsErr[req.GetUserId()]; ok {
			return nil, err
		}
	}
	return &userv2.ListAuthenticationFactorsResponse{
		Result: m.authFactors[req.GetUserId()],
	}, nil
}

func (m *mockUserService) DeleteUser(_ context.Context, req *userv2.DeleteUserRequest, _ ...grpc.CallOption) (*userv2.DeleteUserResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.deleteErr != nil {
		if err, ok := m.deleteErr[req.GetUserId()]; ok {
			return nil, err
		}
	}
	m.deleted = append(m.deleted, req.GetUserId())
	return &userv2.DeleteUserResponse{}, nil
}

// mkUser builds a *userv2.User for tests.
func mkUser(id, username string, emailVerified bool, createdAt time.Time) *userv2.User {
	return &userv2.User{
		UserId:   id,
		Username: username,
		Details: &objectv2.Details{
			CreationDate: timestamppb.New(createdAt),
		},
		Type: &userv2.User_Human{
			Human: &userv2.HumanUser{
				Email: &userv2.HumanEmail{IsVerified: emailVerified},
			},
		},
	}
}

// mkFactor builds a ready *userv2.AuthFactor.
func mkFactor() *userv2.AuthFactor {
	return &userv2.AuthFactor{
		State: userv2.AuthFactorState_AUTH_FACTOR_STATE_READY,
		Type:  &userv2.AuthFactor_Otp{},
	}
}

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
// isEmailVerified
// ---------------------------------------------------------------------------

func TestIsEmailVerified_Verified(t *testing.T) {
	u := mkUser("u1", "u1", true, time.Now())
	if !isEmailVerified(u) {
		t.Error("got false, want true")
	}
}

func TestIsEmailVerified_NotVerified(t *testing.T) {
	u := mkUser("u1", "u1", false, time.Now())
	if isEmailVerified(u) {
		t.Error("got true, want false")
	}
}

func TestIsEmailVerified_NilHuman(t *testing.T) {
	u := &userv2.User{UserId: "u1"} // no Type set → GetHuman() returns nil
	if isEmailVerified(u) {
		t.Error("got true, want false for user with no human type")
	}
}

func TestIsEmailVerified_NilEmail(t *testing.T) {
	u := &userv2.User{
		Type: &userv2.User_Human{Human: &userv2.HumanUser{}},
	}
	if isEmailVerified(u) {
		t.Error("got true, want false for human with no email set")
	}
}

// ---------------------------------------------------------------------------
// listActiveUsers
// ---------------------------------------------------------------------------

func TestListActiveUsers_SinglePage(t *testing.T) {
	now := time.Now()
	svc := &mockUserService{
		listUsersPages: [][]*userv2.User{
			{mkUser("u1", "a", true, now), mkUser("u2", "b", true, now)},
		},
	}
	got, err := listActiveUsers(t.Context(), svc, 100)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d users, want 2", len(got))
	}
	if got[0].GetUserId() != "u1" || got[1].GetUserId() != "u2" {
		t.Errorf("unexpected users: %v %v", got[0].GetUserId(), got[1].GetUserId())
	}
}

func TestListActiveUsers_PaginatesUntilShortPage(t *testing.T) {
	now := time.Now()
	svc := &mockUserService{
		listUsersPages: [][]*userv2.User{
			{mkUser("u1", "u1", true, now), mkUser("u2", "u2", true, now)},
			{mkUser("u3", "u3", true, now), mkUser("u4", "u4", true, now)},
			{mkUser("u5", "u5", true, now)}, // short page → stop
		},
	}
	got, err := listActiveUsers(t.Context(), svc, 2)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 5 {
		t.Errorf("got %d users, want 5", len(got))
	}
	if svc.listUsersCall != 3 {
		t.Errorf("ListUsers called %d times, want 3", svc.listUsersCall)
	}
}

func TestListActiveUsers_EmptyResponse(t *testing.T) {
	svc := &mockUserService{listUsersPages: [][]*userv2.User{{}}}
	got, err := listActiveUsers(t.Context(), svc, 100)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d users, want 0", len(got))
	}
}

func TestListActiveUsers_Error(t *testing.T) {
	svc := &mockUserService{listUsersErr: errors.New("api error")}
	if _, err := listActiveUsers(t.Context(), svc, 100); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// listAuthenticationFactors
// ---------------------------------------------------------------------------

func TestListAuthenticationFactors_ReturnsFactor(t *testing.T) {
	svc := &mockUserService{
		authFactors: map[string][]*userv2.AuthFactor{"user-123": {mkFactor()}},
	}
	factors, err := listAuthenticationFactors(t.Context(), svc, "user-123")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(factors) != 1 {
		t.Fatalf("got %d factors, want 1", len(factors))
	}
	if factors[0].GetState() != userv2.AuthFactorState_AUTH_FACTOR_STATE_READY {
		t.Errorf("state: got %v", factors[0].GetState())
	}
}

func TestListAuthenticationFactors_Empty(t *testing.T) {
	svc := &mockUserService{authFactors: map[string][]*userv2.AuthFactor{}}
	factors, err := listAuthenticationFactors(t.Context(), svc, "u1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(factors) != 0 {
		t.Errorf("got %d factors, want 0", len(factors))
	}
}

func TestListAuthenticationFactors_Error(t *testing.T) {
	svc := &mockUserService{
		authFactorsErr: map[string]error{"u1": errors.New("api error")},
	}
	if _, err := listAuthenticationFactors(t.Context(), svc, "u1"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// hasCompletedRegistration
// ---------------------------------------------------------------------------

func TestHasCompletedRegistration_EmailNotVerified_SkipsFactorCheck(t *testing.T) {
	// Any auth-factors call would return an error; it must not be reached.
	svc := &mockUserService{
		authFactorsErr: map[string]error{"u1": errors.New("should not be called")},
	}
	u := mkUser("u1", "u1", false, time.Now())
	got, err := hasCompletedRegistration(t.Context(), svc, u)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got {
		t.Error("got true, want false")
	}
}

func TestHasCompletedRegistration_EmailVerifiedNoFactors(t *testing.T) {
	svc := &mockUserService{authFactors: map[string][]*userv2.AuthFactor{}}
	u := mkUser("u1", "u1", true, time.Now())
	got, err := hasCompletedRegistration(t.Context(), svc, u)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got {
		t.Error("got true, want false (no factors)")
	}
}

func TestHasCompletedRegistration_EmailVerifiedWithFactors(t *testing.T) {
	svc := &mockUserService{
		authFactors: map[string][]*userv2.AuthFactor{"u1": {mkFactor()}},
	}
	u := mkUser("u1", "u1", true, time.Now())
	got, err := hasCompletedRegistration(t.Context(), svc, u)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got {
		t.Error("got false, want true")
	}
}

func TestHasCompletedRegistration_FactorAPIError(t *testing.T) {
	svc := &mockUserService{
		authFactorsErr: map[string]error{"u1": errors.New("api error")},
	}
	u := mkUser("u1", "u1", true, time.Now())
	if _, err := hasCompletedRegistration(t.Context(), svc, u); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// deleteUser
// ---------------------------------------------------------------------------

func TestDeleteUser_Success(t *testing.T) {
	svc := &mockUserService{}
	if err := deleteUser(t.Context(), svc, "user-abc"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(svc.deleted) != 1 || svc.deleted[0] != "user-abc" {
		t.Errorf("deleted: got %v, want [user-abc]", svc.deleted)
	}
}

func TestDeleteUser_Error(t *testing.T) {
	svc := &mockUserService{
		deleteErr: map[string]error{"user-abc": errors.New("not found")},
	}
	if err := deleteUser(t.Context(), svc, "user-abc"); err == nil {
		t.Fatal("expected error, got nil")
	}
	if len(svc.deleted) != 0 {
		t.Errorf("should not record deletion on error")
	}
}

// ---------------------------------------------------------------------------
// processUsers
// ---------------------------------------------------------------------------

var (
	testOld = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	testNow = time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
)

func testThreshold() time.Time { return testNow.AddDate(0, 0, -7) }

func TestProcessUsers_DeletesIncompleteRegistration(t *testing.T) {
	svc := &mockUserService{
		// "complete" has email verified + a factor → keep
		authFactors: map[string][]*userv2.AuthFactor{
			"complete": {mkFactor()},
		},
	}
	users := []*userv2.User{
		mkUser("complete", "complete", true, testOld),
		mkUser("verified-no-factors", "b", true, testOld),
		mkUser("unverified", "c", false, testOld),
	}

	resp, err := processUsers(t.Context(), svc, users, testThreshold(), false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersChecked != 3 {
		t.Errorf("checked: got %d, want 3", resp.UsersChecked)
	}
	if resp.UsersDeleted != 2 {
		t.Errorf("deleted: got %d, want 2", resp.UsersDeleted)
	}
	if len(svc.deleted) != 2 {
		t.Errorf("recorded deletions: got %v", svc.deleted)
	}
}

func TestProcessUsers_DryRunSkipsDeleteCall(t *testing.T) {
	svc := &mockUserService{authFactors: map[string][]*userv2.AuthFactor{}}
	users := []*userv2.User{mkUser("u1", "u1", false, testOld)}

	resp, err := processUsers(t.Context(), svc, users, testThreshold(), true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 1 {
		t.Errorf("deleted count: got %d, want 1", resp.UsersDeleted)
	}
	if !resp.DryRun {
		t.Error("DryRun: got false, want true")
	}
	if len(svc.deleted) != 0 {
		t.Errorf("delete must not be called in dry-run: got %v", svc.deleted)
	}
}

func TestProcessUsers_KeepsUsersWithinGracePeriod(t *testing.T) {
	svc := &mockUserService{authFactors: map[string][]*userv2.AuthFactor{}}
	recent := testNow.AddDate(0, 0, -2)
	users := []*userv2.User{mkUser("new", "new", false, recent)}

	resp, err := processUsers(t.Context(), svc, users, testThreshold(), false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 0 {
		t.Errorf("deleted: got %d, want 0 (within grace period)", resp.UsersDeleted)
	}
	if len(svc.deleted) != 0 {
		t.Errorf("should not delete: got %v", svc.deleted)
	}
}

func TestProcessUsers_DeleteFailureIsSkippedNotFatal(t *testing.T) {
	svc := &mockUserService{
		authFactors: map[string][]*userv2.AuthFactor{},
		deleteErr:   map[string]error{"u1": errors.New("internal error")},
	}
	users := []*userv2.User{
		mkUser("u1", "u1", false, testOld),
		mkUser("u2", "u2", false, testOld),
	}
	resp, err := processUsers(t.Context(), svc, users, testThreshold(), false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 1 {
		t.Errorf("deleted: got %d, want 1", resp.UsersDeleted)
	}
	if resp.UsersSkipped != 1 {
		t.Errorf("skipped: got %d, want 1", resp.UsersSkipped)
	}
	if len(svc.deleted) != 1 || svc.deleted[0] != "u2" {
		t.Errorf("deleted: got %v, want [u2]", svc.deleted)
	}
}

func TestProcessUsers_FactorLookupErrorIsSkipped(t *testing.T) {
	svc := &mockUserService{
		authFactorsErr: map[string]error{"u1": errors.New("api error")},
	}
	// Email verified so auth-factors lookup is triggered and will fail.
	users := []*userv2.User{mkUser("u1", "u1", true, testOld)}
	resp, err := processUsers(t.Context(), svc, users, testThreshold(), false)
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
	svc := &mockUserService{authFactors: map[string][]*userv2.AuthFactor{}}
	thr := testThreshold()
	users := []*userv2.User{mkUser("boundary", "boundary", false, thr)}

	resp, err := processUsers(t.Context(), svc, users, thr, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.UsersDeleted != 0 {
		t.Errorf("deleted: got %d, want 0 (exactly at threshold should be kept)", resp.UsersDeleted)
	}
}

// ---------------------------------------------------------------------------
// silence logs in test output
// ---------------------------------------------------------------------------

func TestMain(m *testing.M) {
	log.SetOutput(io.Discard)
	os.Exit(m.Run())
}
