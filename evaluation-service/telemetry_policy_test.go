package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

func TestTelemetrySamplesRemoteUnsampledParent(t *testing.T) {
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	defer endpoint.Close()
	t.Setenv("OTEL_SDK_DISABLED", "false")
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint.URL)
	t.Setenv("OTEL_TRACES_SAMPLER", "always_off") // A política desta entrega prevalece.
	previousTrace, previousMeter, previousProp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetTextMapPropagator()
	shutdown, err := setupTelemetry(context.Background(), "test")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = shutdown(context.Background())
		otel.SetTracerProvider(previousTrace)
		otel.SetMeterProvider(previousMeter)
		otel.SetTextMapPropagator(previousProp)
	}()
	carrier := propagation.MapCarrier{"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"}
	parent := otel.GetTextMapPropagator().Extract(context.Background(), carrier)
	_, span := otel.Tracer("test").Start(parent, "child")
	defer span.End()
	if !span.SpanContext().IsSampled() {
		t.Fatal("span excluído por parent não amostrado")
	}
	if got := span.SpanContext().TraceID().String(); got != "4bf92f3577b34da6a3ce929d0e0e4736" {
		t.Fatal(got)
	}
}

func TestUnknownPathsHaveStableSpanName(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	provider := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder))
	previous := otel.GetTracerProvider()
	otel.SetTracerProvider(provider)
	defer func() { _ = provider.Shutdown(context.Background()); otel.SetTracerProvider(previous) }()
	mux := http.NewServeMux()
	mux.HandleFunc("/known", func(http.ResponseWriter, *http.Request) {})
	handler := instrumentHandler(mux, "test")
	for _, path := range []string{"/missing/1", "/missing/2", "/known"} {
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}
	spans := recorder.Ended()
	if len(spans) != 3 {
		t.Fatal(len(spans))
	}
	if spans[0].Name() != "GET" || spans[1].Name() != "GET" || spans[2].Name() != "GET /known" {
		t.Fatal("nomes devem usar rota ou método, sem valores de URL")
	}
	for _, s := range spans {
		if s.SpanKind() != trace.SpanKindServer {
			t.Fatal("span não SERVER")
		}
	}
}
