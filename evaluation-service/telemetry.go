package main

// Inicialização do OpenTelemetry (traces + métricas) via OTLP/HTTP para o
// OTel Collector gateway, que roteia traces para o New Relic/spanmetrics e
// métricas para o Prometheus.
//
// Configuração pelas variáveis de ambiente padrão do OTel:
//   OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES,
//   OTEL_EXPORTER_OTLP_ENDPOINT (ex.: http://otel-gateway.observability:4318),
//   OTEL_SDK_DISABLED=true desliga a exportação (uso local sem Collector).
//
// Arquivo idêntico em auth-service e evaluation-service.

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// setupTelemetry configura os providers globais. A função retornada faz o
// flush/shutdown dos exporters e deve ser chamada no encerramento.
func setupTelemetry(ctx context.Context, defaultServiceName string) (func(context.Context) error, error) {
	// W3C TraceContext + Baggage: mesmo formato usado pelos serviços Python
	// e pelos MessageAttributes do SQS.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	if strings.EqualFold(strings.TrimSpace(os.Getenv("OTEL_SDK_DISABLED")), "true") {
		log.Println("OpenTelemetry desabilitado (OTEL_SDK_DISABLED=true).")
		return func(context.Context) error { return nil }, nil
	}

	// Ordem importa: detectores posteriores sobrescrevem os anteriores, então
	// OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES prevalecem sobre o padrão.
	res, err := resource.New(ctx,
		resource.WithAttributes(attribute.String("service.name", defaultServiceName)),
		resource.WithTelemetrySDK(),
		resource.WithFromEnv(),
	)
	if err != nil {
		return nil, err
	}

	traceExporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tracerProvider)

	metricExporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		_ = tracerProvider.Shutdown(ctx)
		return nil, err
	}
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(meterProvider)

	return func(ctx context.Context) error {
		// Os providers recebem o mesmo prazo total, mas drenam em paralelo.
		var wg sync.WaitGroup
		var traceErr, metricErr error
		wg.Add(2)
		go func() { defer wg.Done(); traceErr = tracerProvider.Shutdown(ctx) }()
		go func() { defer wg.Done(); metricErr = meterProvider.Shutdown(ctx) }()
		wg.Wait()
		return errors.Join(traceErr, metricErr)
	}, nil
}

// instrumentHandler cria o span SERVER de cada requisição (extraindo o
// traceparent recebido) e ignora o /health das probes do Kubernetes.
func instrumentHandler(h http.Handler, operation string) http.Handler {
	wrapped := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// http.route (dimensão do spanmetrics) vem do padrão do ServeMux; o
		// otelhttp não o obtém sozinho porque o mux recebe uma cópia do request.
		if pattern := routePattern(h, r); pattern != "" {
			trace.SpanFromContext(r.Context()).SetAttributes(attribute.String("http.route", pattern))
		}
		h.ServeHTTP(w, r)
		if r.URL.Path != "/health" {
			logWithTrace(r.Context(), "HTTP %s concluído", operation)
		}
	})
	return otelhttp.NewHandler(wrapped, operation,
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" }),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			// Mux.Handler fornece o padrão, sem valores arbitrários de URL.
			if pattern := routePattern(h, r); pattern != "" {
				return r.Method + " " + pattern
			}
			return r.Method
		}),
	)
}

// routePattern devolve o padrão registrado no ServeMux (sem valores
// arbitrários da URL), ou "" quando não há rota.
func routePattern(h http.Handler, r *http.Request) string {
	if mux, ok := h.(*http.ServeMux); ok {
		_, pattern := mux.Handler(r)
		return pattern
	}
	return ""
}

// logWithTrace mantém o formato de correlação também em goroutines derivadas.
func logWithTrace(ctx context.Context, format string, args ...any) {
	sc := trace.SpanContextFromContext(ctx)
	values := append([]any{sc.TraceID().String(), sc.SpanID().String()}, args...)
	log.Printf("[trace_id=%s span_id=%s] "+format, values...)
}
