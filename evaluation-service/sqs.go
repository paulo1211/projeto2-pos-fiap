package main

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// Evento que será enviado para a fila
type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

// queueName extrai o nome da fila da URL (https://sqs.<região>.amazonaws.com/<conta>/<fila>).
func queueName(queueURL string) string {
	trimmed := strings.TrimRight(queueURL, "/")
	return trimmed[strings.LastIndex(trimmed, "/")+1:]
}

// traceMessageAttributes serializa o contexto do trace atual (W3C
// traceparent/tracestate) como MessageAttributes do SQS. O analytics-service
// extrai esses atributos e continua o MESMO trace distribuído no consumidor.
func traceMessageAttributes(ctx context.Context) map[string]*sqs.MessageAttributeValue {
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)

	attrs := make(map[string]*sqs.MessageAttributeValue, len(carrier))
	for key, value := range carrier {
		attrs[key] = &sqs.MessageAttributeValue{
			DataType:    aws.String("String"),
			StringValue: aws.String(value),
		}
	}
	return attrs
}

// sendEvaluationEvent envia um evento para a fila SQS
func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	// Se a URL da fila não foi configurada, apenas loga localmente e sai.
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		logWithTrace(ctx, "[SQS_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		logWithTrace(ctx, "Erro ao serializar evento SQS: %v", err)
		return
	}

	// Span PRODUCER: aparece no trace do /evaluate e é o "pai" do span
	// CONSUMER do analytics-service (liga os dois serviços no Service Map).
	queue := queueName(a.SqsQueueURL)
	ctx, span := otel.Tracer("evaluation-service").Start(ctx, queue+" publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.operation", "publish"),
			attribute.String("messaging.destination.name", queue),
		),
	)
	defer span.End()

	// Envia a mensagem (o traceparent é injetado a partir do span PRODUCER)
	output, err := a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: traceMessageAttributes(ctx),
	})

	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		logWithTrace(ctx, "Erro ao enviar mensagem para SQS: %v", err)
	} else {
		span.SetAttributes(attribute.String("messaging.message.id", aws.StringValue(output.MessageId)))
		logWithTrace(ctx, "Evento de avaliação enviado para SQS (Flag: %s)", flagName)
	}
}
