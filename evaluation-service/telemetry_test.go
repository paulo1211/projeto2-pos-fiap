package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// setupTestTracing instala um TracerProvider que grava os spans em memória.
func setupTestTracing(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	recorder := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
	prevTP, prevProp := otel.GetTracerProvider(), otel.GetTextMapPropagator()
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		_ = tp.Shutdown(context.Background())
		otel.SetTracerProvider(prevTP)
		otel.SetTextMapPropagator(prevProp)
	})
	return recorder
}

func TestQueueName(t *testing.T) {
	got := queueName("https://sqs.us-east-1.amazonaws.com/123456789012/togglemaster-evaluations/")
	if got != "togglemaster-evaluations" {
		t.Fatalf("queueName = %q", got)
	}
}

// O traceparent do span atual precisa ir nos MessageAttributes do SQS para o
// analytics-service continuar o mesmo trace.
func TestTraceMessageAttributesCarriesTraceparent(t *testing.T) {
	setupTestTracing(t)
	ctx, span := otel.Tracer("test").Start(context.Background(), "parent")
	defer span.End()

	attrs := traceMessageAttributes(ctx)
	tp, ok := attrs["traceparent"]
	if !ok {
		t.Fatalf("traceparent ausente: %v", attrs)
	}
	if *tp.DataType != "String" {
		t.Fatalf("DataType = %q, esperado String", *tp.DataType)
	}
	if !strings.Contains(*tp.StringValue, span.SpanContext().TraceID().String()) {
		t.Fatalf("traceparent %q não contém o trace %s", *tp.StringValue, span.SpanContext().TraceID())
	}
}

// As chamadas ao flag-service devem gerar span CLIENT filho da requisição e
// propagar o traceparent no header HTTP.
func TestFetchFlagPropagatesTraceContext(t *testing.T) {
	recorder := setupTestTracing(t)

	var gotTraceparent string
	flagSvc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotTraceparent = r.Header.Get("traceparent")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":1,"name":"f1","is_enabled":true}`))
	}))
	defer flagSvc.Close()

	app := &App{
		HttpClient:     &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)},
		FlagServiceURL: flagSvc.URL,
	}

	ctx, parent := otel.Tracer("test").Start(context.Background(), "GET /evaluate")
	flag, err := app.fetchFlag(ctx, "f1")
	parent.End()
	if err != nil || flag == nil || flag.Name != "f1" {
		t.Fatalf("fetchFlag = %+v, %v", flag, err)
	}

	traceID := parent.SpanContext().TraceID().String()
	if !strings.Contains(gotTraceparent, traceID) {
		t.Fatalf("traceparent recebido %q não pertence ao trace %s", gotTraceparent, traceID)
	}

	var client sdktrace.ReadOnlySpan
	for _, s := range recorder.Ended() {
		if s.SpanKind() == trace.SpanKindClient {
			client = s
		}
	}
	if client == nil {
		t.Fatal("nenhum span CLIENT gravado")
	}
	if client.Parent().SpanID() != parent.SpanContext().SpanID() {
		t.Fatal("span CLIENT não é filho do span da requisição")
	}
}

// /health (probes do Kubernetes) não deve gerar spans; as demais rotas sim.
func TestInstrumentHandlerSkipsHealth(t *testing.T) {
	recorder := setupTestTracing(t)
	mux := http.NewServeMux()
	mux.HandleFunc("/evaluate", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	h := instrumentHandler(mux, "test")

	for _, path := range []string{"/health", "/evaluate"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}

	ended := recorder.Ended()
	if len(ended) != 1 || ended[0].Name() != "GET /evaluate" {
		names := make([]string, 0, len(ended))
		for _, s := range ended {
			names = append(names, s.Name())
		}
		t.Fatalf("spans = %v, esperado só [GET /evaluate]", names)
	}
	// http.route vem do padrão do ServeMux e é dimensão do spanmetrics.
	var route string
	for _, kv := range ended[0].Attributes() {
		if kv.Key == "http.route" {
			route = kv.Value.AsString()
		}
	}
	if route != "/evaluate" {
		t.Fatalf("http.route = %q, esperado /evaluate", route)
	}
}
