package main

import (
	"context"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel/trace"
)

func TestBackgroundTaskKeepsTraceAndGetsOwnTimeout(t *testing.T) {
	parentSC := trace.NewSpanContext(trace.SpanContextConfig{
		TraceID: trace.TraceID{1}, SpanID: trace.SpanID{2}, TraceFlags: trace.FlagsSampled,
	})
	parent, cancel := context.WithCancel(trace.ContextWithSpanContext(context.Background(), parentSC))
	cancel()
	var tasks backgroundTasks
	result := make(chan bool, 1)
	if !tasks.start(parent, 50*time.Millisecond, func(ctx context.Context) {
		_, hasDeadline := ctx.Deadline()
		valid := ctx.Err() == nil && hasDeadline && trace.SpanContextFromContext(ctx).TraceID() == parentSC.TraceID()
		<-ctx.Done()
		result <- valid && ctx.Err() == context.DeadlineExceeded
	}) {
		t.Fatal("rejeitou publicação")
	}
	drainCtx, cancelDrain := context.WithTimeout(context.Background(), time.Second)
	defer cancelDrain()
	if err := tasks.drain(drainCtx); err != nil {
		t.Fatal(err)
	}
	if !<-result {
		t.Fatal("contexto/timeout inválido")
	}
	if tasks.start(parent, time.Second, func(context.Context) {}) {
		t.Fatal("aceitou tarefa após drain")
	}
}

func TestDrainWaitsForInFlightPublication(t *testing.T) {
	var tasks backgroundTasks
	release := make(chan struct{})
	completed := make(chan struct{})
	tasks.start(context.Background(), time.Second, func(context.Context) { <-release; close(completed) })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := tasks.drain(ctx); err != context.Canceled {
		t.Fatalf("drain = %v", err)
	}
	close(release)
	if err := tasks.drain(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-completed:
	default:
		t.Fatal("retornou sem concluir publicação")
	}
}

func TestConcurrentSubmitAndDrain(t *testing.T) {
	var tasks backgroundTasks
	var submitters sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 32; i++ {
		submitters.Add(1)
		go func() {
			defer submitters.Done()
			<-start
			tasks.start(context.Background(), time.Second, func(context.Context) {})
		}()
	}
	close(start)
	if err := tasks.drain(context.Background()); err != nil {
		t.Fatal(err)
	}
	submitters.Wait()
	if tasks.start(context.Background(), time.Second, func(context.Context) {}) {
		t.Fatal("aceitou após fechar")
	}
}
