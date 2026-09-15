package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

const (
	redriveCountAttribute = "RedriveCount"
	maxMessagesPerReceive = 10
	maxReceiveBatches     = 10
)

// ---------------------------------------------------------------------------
// Module-level configuration (read once at cold start)
// ---------------------------------------------------------------------------

var (
	dlqURL             string
	sourceQueueURL     string
	maxRedriveAttempts int
)

var (
	sqsClient *sqs.Client
	initErr   error
)

type sqsService interface {
	ReceiveMessage(context.Context, *sqs.ReceiveMessageInput, ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	SendMessage(context.Context, *sqs.SendMessageInput, ...func(*sqs.Options)) (*sqs.SendMessageOutput, error)
	DeleteMessage(context.Context, *sqs.DeleteMessageInput, ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
}

func init() {
	var missing []string
	dlqURL = os.Getenv("DLQ_URL")
	if dlqURL == "" {
		missing = append(missing, "DLQ_URL")
	}
	sourceQueueURL = os.Getenv("SOURCE_QUEUE_URL")
	if sourceQueueURL == "" {
		missing = append(missing, "SOURCE_QUEUE_URL")
	}
	if len(missing) > 0 {
		initErr = fmt.Errorf("required environment variables not set: %s", strings.Join(missing, ", "))
		return
	}

	attempts, err := parseMaxRedriveAttempts()
	if err != nil {
		initErr = err
		return
	}
	maxRedriveAttempts = attempts

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		initErr = fmt.Errorf("loading AWS config: %w", err)
		return
	}
	sqsClient = sqs.NewFromConfig(cfg)
}

func parseMaxRedriveAttempts() (int, error) {
	v := os.Getenv("MAX_REDRIVE_ATTEMPTS")
	if v == "" {
		return 3, nil
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("MAX_REDRIVE_ATTEMPTS must be an integer, got %q", v)
	}
	return i, nil
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

func redriveCount(attrs map[string]sqstypes.MessageAttributeValue) int {
	attr, ok := attrs[redriveCountAttribute]
	if !ok || attr.StringValue == nil {
		return 0
	}
	count, err := strconv.Atoi(aws.ToString(attr.StringValue))
	if err != nil {
		return 0
	}
	return count
}

func withRedriveCount(attrs map[string]sqstypes.MessageAttributeValue, count int) map[string]sqstypes.MessageAttributeValue {
	out := make(map[string]sqstypes.MessageAttributeValue, len(attrs)+1)
	for k, v := range attrs {
		out[k] = v
	}
	out[redriveCountAttribute] = sqstypes.MessageAttributeValue{
		DataType:    aws.String("Number"),
		StringValue: aws.String(strconv.Itoa(count)),
	}
	return out
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

type response struct {
	StatusCode     int `json:"statusCode"`
	RedrivenCount  int `json:"redriven_count"`
	AbandonedCount int `json:"abandoned_count"`
}

func redriveMessage(ctx context.Context, svc sqsService, msg sqstypes.Message) (bool, error) {
	count := redriveCount(msg.MessageAttributes)
	if count >= maxRedriveAttempts {
		log.Printf("Message %s has reached the max redrive attempts (%d), leaving in DLQ for manual review", aws.ToString(msg.MessageId), maxRedriveAttempts)
		return false, nil
	}

	_, err := svc.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:          aws.String(sourceQueueURL),
		MessageBody:       msg.Body,
		MessageAttributes: withRedriveCount(msg.MessageAttributes, count+1),
	})
	if err != nil {
		return false, fmt.Errorf("sending message %s to source queue: %w", aws.ToString(msg.MessageId), err)
	}

	if _, err := svc.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(dlqURL),
		ReceiptHandle: msg.ReceiptHandle,
	}); err != nil {
		return false, fmt.Errorf("deleting redriven message %s from DLQ: %w", aws.ToString(msg.MessageId), err)
	}

	log.Printf("Redrove message %s to source queue (attempt %d/%d)", aws.ToString(msg.MessageId), count+1, maxRedriveAttempts)
	return true, nil
}

func drainDLQ(ctx context.Context, svc sqsService) (response, error) {
	result := response{StatusCode: 200}

	for batch := 0; batch < maxReceiveBatches; batch++ {
		out, err := svc.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:              aws.String(dlqURL),
			MaxNumberOfMessages:   maxMessagesPerReceive,
			MessageAttributeNames: []string{"All"},
		})
		if err != nil {
			return result, fmt.Errorf("receiving messages from DLQ: %w", err)
		}
		if len(out.Messages) == 0 {
			break
		}

		for _, msg := range out.Messages {
			redriven, err := redriveMessage(ctx, svc, msg)
			if err != nil {
				log.Printf("error: %v", err)
				continue
			}
			if redriven {
				result.RedrivenCount++
			} else {
				result.AbandonedCount++
			}
		}
	}

	return result, nil
}

// ---------------------------------------------------------------------------
// Lambda entry point
// ---------------------------------------------------------------------------

func handler(ctx context.Context, _ events.CloudWatchEvent) (response, error) {
	if initErr != nil {
		return response{}, initErr
	}

	result, err := drainDLQ(ctx, sqsClient)
	if err != nil {
		return result, err
	}

	log.Printf("DLQ redrive complete: redriven=%d abandoned=%d", result.RedrivenCount, result.AbandonedCount)
	return result, nil
}

func main() {
	isLocal := os.Getenv("LOCAL") == "true"
	if isLocal {
		log.Println("Running locally, invoking handler directly")
		response, err := handler(context.Background(), events.CloudWatchEvent{})
		if err != nil {
			log.Fatalf("Handler error: %v", err)
		}
		log.Printf("Handler response: %+v", response)
	} else {
		log.Println("Running in Lambda")
		lambda.Start(handler)
	}
}
