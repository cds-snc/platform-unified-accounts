package main

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// ---------------------------------------------------------------------------
// Mock sqsService
// ---------------------------------------------------------------------------

type mockSQSService struct {
	// ReceiveMessage: each call returns the next page sequentially.
	receivePages [][]sqstypes.Message
	receiveCall  int
	receiveErr   error

	sendErr   error
	sent      []sqs.SendMessageInput
	deleteErr error
	deleted   []string
}

func (m *mockSQSService) ReceiveMessage(_ context.Context, _ *sqs.ReceiveMessageInput, _ ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error) {
	if m.receiveErr != nil {
		return nil, m.receiveErr
	}
	idx := m.receiveCall
	m.receiveCall++
	if idx < len(m.receivePages) {
		return &sqs.ReceiveMessageOutput{Messages: m.receivePages[idx]}, nil
	}
	return &sqs.ReceiveMessageOutput{}, nil
}

func (m *mockSQSService) SendMessage(_ context.Context, in *sqs.SendMessageInput, _ ...func(*sqs.Options)) (*sqs.SendMessageOutput, error) {
	if m.sendErr != nil {
		return nil, m.sendErr
	}
	m.sent = append(m.sent, *in)
	return &sqs.SendMessageOutput{}, nil
}

func (m *mockSQSService) DeleteMessage(_ context.Context, in *sqs.DeleteMessageInput, _ ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error) {
	if m.deleteErr != nil {
		return nil, m.deleteErr
	}
	m.deleted = append(m.deleted, aws.ToString(in.ReceiptHandle))
	return &sqs.DeleteMessageOutput{}, nil
}

// mkMessage builds a sqstypes.Message for tests with an optional RedriveCount attribute.
func mkMessage(id, receiptHandle, body string, redriveCount *int) sqstypes.Message {
	msg := sqstypes.Message{
		MessageId:     aws.String(id),
		ReceiptHandle: aws.String(receiptHandle),
		Body:          aws.String(body),
	}
	if redriveCount != nil {
		msg.MessageAttributes = map[string]sqstypes.MessageAttributeValue{
			redriveCountAttribute: {
				DataType:    aws.String("Number"),
				StringValue: aws.String(itoa(*redriveCount)),
			},
		}
	}
	return msg
}

func itoa(i int) string {
	return []string{"0", "1", "2", "3", "4", "5"}[i]
}

func TestMain(m *testing.M) {
	dlqURL = "https://sqs.example.com/dlq"
	sourceQueueURL = "https://sqs.example.com/source"
	maxRedriveAttempts = 3
	m.Run()
}

func TestRedriveCount(t *testing.T) {
	if got := redriveCount(nil); got != 0 {
		t.Errorf("redriveCount(nil) = %d, want 0", got)
	}

	attrs := map[string]sqstypes.MessageAttributeValue{
		redriveCountAttribute: {StringValue: aws.String("2")},
	}
	if got := redriveCount(attrs); got != 2 {
		t.Errorf("redriveCount(%v) = %d, want 2", attrs, got)
	}

	invalid := map[string]sqstypes.MessageAttributeValue{
		redriveCountAttribute: {StringValue: aws.String("not-a-number")},
	}
	if got := redriveCount(invalid); got != 0 {
		t.Errorf("redriveCount(%v) = %d, want 0", invalid, got)
	}
}

func TestRedriveMessage_FirstAttempt(t *testing.T) {
	svc := &mockSQSService{}
	msg := mkMessage("msg-1", "receipt-1", `{"time":"2026-09-09T19:40:00Z"}`, nil)

	redriven, err := redriveMessage(context.Background(), svc, msg)
	if err != nil {
		t.Fatalf("redriveMessage() error = %v", err)
	}
	if !redriven {
		t.Fatalf("redriveMessage() redriven = false, want true")
	}
	if len(svc.sent) != 1 {
		t.Fatalf("expected 1 message sent, got %d", len(svc.sent))
	}
	got := redriveCount(svc.sent[0].MessageAttributes)
	if got != 1 {
		t.Errorf("redriven message RedriveCount = %d, want 1", got)
	}
	if len(svc.deleted) != 1 || svc.deleted[0] != "receipt-1" {
		t.Errorf("expected receipt-1 to be deleted, got %v", svc.deleted)
	}
}

func TestRedriveMessage_ExceedsMaxAttempts(t *testing.T) {
	svc := &mockSQSService{}
	count := maxRedriveAttempts
	msg := mkMessage("msg-1", "receipt-1", "body", &count)

	redriven, err := redriveMessage(context.Background(), svc, msg)
	if err != nil {
		t.Fatalf("redriveMessage() error = %v", err)
	}
	if redriven {
		t.Fatalf("redriveMessage() redriven = true, want false")
	}
	if len(svc.sent) != 0 {
		t.Errorf("expected no messages sent, got %d", len(svc.sent))
	}
	if len(svc.deleted) != 0 {
		t.Errorf("expected no messages deleted, got %d", len(svc.deleted))
	}
}

func TestRedriveMessage_SendFails(t *testing.T) {
	svc := &mockSQSService{sendErr: errors.New("send failed")}
	msg := mkMessage("msg-1", "receipt-1", "body", nil)

	_, err := redriveMessage(context.Background(), svc, msg)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if len(svc.deleted) != 0 {
		t.Errorf("expected no messages deleted when send fails, got %d", len(svc.deleted))
	}
}

func TestRedriveMessage_DeleteFails(t *testing.T) {
	svc := &mockSQSService{deleteErr: errors.New("delete failed")}
	msg := mkMessage("msg-1", "receipt-1", "body", nil)

	_, err := redriveMessage(context.Background(), svc, msg)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if len(svc.sent) != 1 {
		t.Errorf("expected message to have been sent before delete failure, got %d", len(svc.sent))
	}
}

func TestDrainDLQ(t *testing.T) {
	zero, three := 0, maxRedriveAttempts
	svc := &mockSQSService{
		receivePages: [][]sqstypes.Message{
			{
				mkMessage("msg-1", "receipt-1", "body-1", nil),
				mkMessage("msg-2", "receipt-2", "body-2", &zero),
				mkMessage("msg-3", "receipt-3", "body-3", &three),
			},
		},
	}

	result, err := drainDLQ(context.Background(), svc)
	if err != nil {
		t.Fatalf("drainDLQ() error = %v", err)
	}
	if result.RedrivenCount != 2 {
		t.Errorf("RedrivenCount = %d, want 2", result.RedrivenCount)
	}
	if result.AbandonedCount != 1 {
		t.Errorf("AbandonedCount = %d, want 1", result.AbandonedCount)
	}
}

func TestDrainDLQ_ReceiveError(t *testing.T) {
	svc := &mockSQSService{receiveErr: errors.New("receive failed")}

	_, err := drainDLQ(context.Background(), svc)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestDrainDLQ_Empty(t *testing.T) {
	svc := &mockSQSService{}

	result, err := drainDLQ(context.Background(), svc)
	if err != nil {
		t.Fatalf("drainDLQ() error = %v", err)
	}
	if result.RedrivenCount != 0 || result.AbandonedCount != 0 {
		t.Errorf("expected no redrives or abandons on empty DLQ, got %+v", result)
	}
}
