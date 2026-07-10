// Lambda function that deletes Zitadel users who have not completed
// registration.
//
// A user has not completed registration when they:
//   - Have not verified their email address, OR
//   - Have no MFA methods registered.
//
// For every active human user in the Zitadel instance, the function checks
// whether registration is complete. Users whose registration has been
// incomplete for longer than INACTIVE_DAYS are deleted.
//
// Required environment variables:
//
//	ZITADEL_URL                  - Base URL of the Zitadel instance
//	ZITADEL_PRIVATE_KEY_SSM_PATH - SSM Parameter Store path for the Zitadel service account JSON key
//	INACTIVE_DAYS                - Users with incomplete registration older than this are deleted
//
// Optional environment variables:
//
//	DRY_RUN - When "true", report what would be deleted without making changes (default: false)
//	LOCAL   - When "true", run the handler directly instead of starting the Lambda (default: false)
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/zitadel/oidc/v3/pkg/oidc"
	zitadelclient "github.com/zitadel/zitadel-go/v3/pkg/client"
	objectv2 "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/object/v2"
	userv2 "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/user/v2"
	"github.com/zitadel/zitadel-go/v3/pkg/zitadel"
	"google.golang.org/grpc"
)

const (
	pageLimit = 100
)

// ---------------------------------------------------------------------------
// Module-level configuration (read once at cold start)
// ---------------------------------------------------------------------------

var (
	zitadelURL               string
	zitadelPrivateKeySSMPath string
	inactiveDays             int
	dryRun                   bool
)

var (
	ssmClient        *ssm.Client
	zitadelAPIClient *zitadelclient.Client
	initErr          error
)

// userService is the subset of the Zitadel UserServiceV2 gRPC client used by
// this function.
type userService interface {
	ListUsers(context.Context, *userv2.ListUsersRequest, ...grpc.CallOption) (*userv2.ListUsersResponse, error)
	ListAuthenticationFactors(context.Context, *userv2.ListAuthenticationFactorsRequest, ...grpc.CallOption) (*userv2.ListAuthenticationFactorsResponse, error)
	DeleteUser(context.Context, *userv2.DeleteUserRequest, ...grpc.CallOption) (*userv2.DeleteUserResponse, error)
}

func init() {
	var missing []string
	zitadelURL = os.Getenv("ZITADEL_URL")
	if zitadelURL == "" {
		missing = append(missing, "ZITADEL_URL")
	}
	zitadelPrivateKeySSMPath = os.Getenv("ZITADEL_PRIVATE_KEY_SSM_PATH")
	if zitadelPrivateKeySSMPath == "" {
		missing = append(missing, "ZITADEL_PRIVATE_KEY_SSM_PATH")
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

	zitadelAPIClient, err = zitadelclient.New(
		context.Background(),
		zitadel.New(zitadelURL),
		zitadelclient.WithAuth(zitadelclient.AuthenticationJWTProfile(
			keyFile,
			oidc.ScopeOpenID,
			zitadelclient.ScopeZitadelAPI(),
		)),
	)
	if err != nil {
		initErr = fmt.Errorf("creating Zitadel client: %w", err)
		return
	}
}

// ---------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------

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
// Zitadel operations
// ---------------------------------------------------------------------------

// listActiveUsers fetches every active human user, paging through the result
// set until fewer than limit records are returned.
func listActiveUsers(ctx context.Context, svc userService, limit int) ([]*userv2.User, error) {
	var all []*userv2.User
	var offset uint64

	for {
		log.Printf("Listing active users offset=%d limit=%d", offset, limit)
		resp, err := svc.ListUsers(ctx, &userv2.ListUsersRequest{
			Query: &objectv2.ListQuery{
				Limit:  uint32(limit),
				Offset: offset,
				Asc:    true,
			},
			Queries: []*userv2.SearchQuery{
				{
					Query: &userv2.SearchQuery_StateQuery{
						StateQuery: &userv2.StateQuery{State: userv2.UserState_USER_STATE_ACTIVE},
					},
				},
				{
					Query: &userv2.SearchQuery_TypeQuery{
						TypeQuery: &userv2.TypeQuery{Type: userv2.Type_TYPE_HUMAN},
					},
				},
			},
		})
		if err != nil {
			return nil, fmt.Errorf("listing users: %w", err)
		}
		all = append(all, resp.GetResult()...)
		if len(resp.GetResult()) < limit {
			break
		}
		offset += uint64(len(resp.GetResult()))
	}
	log.Printf("Fetched %d active user(s)", len(all))
	return all, nil
}

func isEmailVerified(u *userv2.User) bool {
	return u.GetHuman().GetEmail().GetIsVerified()
}

func listAuthenticationFactors(ctx context.Context, svc userService, userID string) ([]*userv2.AuthFactor, error) {
	resp, err := svc.ListAuthenticationFactors(ctx, &userv2.ListAuthenticationFactorsRequest{
		UserId: userID,
	})
	if err != nil {
		return nil, fmt.Errorf("listing authentication factors for user %s: %w", userID, err)
	}
	return resp.GetResult(), nil
}

// hasCompletedRegistration returns true when the user has both a verified email
// address and at least one authentication factor registered
func hasCompletedRegistration(ctx context.Context, svc userService, u *userv2.User) (bool, error) {
	if !isEmailVerified(u) {
		return false, nil
	}
	factors, err := listAuthenticationFactors(ctx, svc, u.GetUserId())
	if err != nil {
		return false, err
	}
	return len(factors) > 0, nil
}

func deleteUser(ctx context.Context, svc userService, userID string) error {
	_, err := svc.DeleteUser(ctx, &userv2.DeleteUserRequest{UserId: userID})
	if err != nil {
		return fmt.Errorf("deleting user %s: %w", userID, err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Lambda entry point
// ---------------------------------------------------------------------------

type response struct {
	StatusCode   int      `json:"statusCode"`
	UsersChecked int      `json:"users_checked"`
	UsersDeleted int      `json:"users_deleted"`
	UsersSkipped int      `json:"users_skipped"`
	DeletedUsers []string `json:"deleted_users,omitempty"`
	InactiveDays int      `json:"inactive_days"`
	DryRun       bool     `json:"dry_run"`
	Threshold    string   `json:"threshold"`
}

func processUsers(ctx context.Context, svc userService, users []*userv2.User, threshold time.Time, dryRun bool) (response, error) {
	resp := response{
		StatusCode:   200,
		UsersChecked: len(users),
		InactiveDays: inactiveDays,
		DryRun:       dryRun,
		Threshold:    threshold.Format(time.RFC3339),
	}

	for _, u := range users {
		created := u.GetDetails().GetCreationDate().AsTime().UTC()

		if !created.Before(threshold) {
			log.Printf("Keeping user %s (%s): account created %s is within the registration grace period",
				u.GetUserId(), u.GetUsername(), created.Format(time.RFC3339))
			continue
		}

		completed, err := hasCompletedRegistration(ctx, svc, u)
		if err != nil {
			log.Printf("Skipping user %s (%s): %v", u.GetUserId(), u.GetUsername(), err)
			resp.UsersSkipped++
			continue
		}

		if completed {
			log.Printf("Keeping user %s (%s): registration is complete", u.GetUserId(), u.GetUsername())
			continue
		}

		log.Printf("Deleting user %s (%s): registration incomplete and account created %s is older than threshold %s",
			u.GetUserId(), u.GetUsername(), created.Format(time.RFC3339), threshold.Format(time.RFC3339))
		if !dryRun {
			if err := deleteUser(ctx, svc, u.GetUserId()); err != nil {
				log.Printf("Failed to delete user %s (%s): %v", u.GetUserId(), u.GetUsername(), err)
				resp.UsersSkipped++
				continue
			}
		}
		resp.UsersDeleted++
		resp.DeletedUsers = append(resp.DeletedUsers, u.GetUsername())
	}
	return resp, nil
}

func handler(ctx context.Context) (response, error) {
	if initErr != nil {
		return response{}, initErr
	}

	// Fetch the token once so all gRPC calls reuse the same OIDC session
	token, err := zitadelAPIClient.GetValidToken()
	if err != nil {
		return response{}, fmt.Errorf("getting Zitadel token: %w", err)
	}
	ctx = zitadelclient.BearerTokenCtx(ctx, token)

	now := time.Now().UTC()
	threshold := now.AddDate(0, 0, -inactiveDays)
	log.Printf("Starting incomplete registration sweep: inactive_days=%d threshold=%s dry_run=%t",
		inactiveDays, threshold.Format(time.RFC3339), dryRun)

	svc := zitadelAPIClient.UserServiceV2()

	users, err := listActiveUsers(ctx, svc, pageLimit)
	if err != nil {
		return response{}, fmt.Errorf("listing active users: %w", err)
	}

	result, err := processUsers(ctx, svc, users, threshold, dryRun)
	if err != nil {
		return response{}, err
	}
	log.Printf("Incomplete registration sweep finished: checked=%d deleted=%d skipped=%d dry_run=%t",
		result.UsersChecked, result.UsersDeleted, result.UsersSkipped, result.DryRun)
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
