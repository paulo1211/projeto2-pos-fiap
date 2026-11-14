package main

import (
	"context"
	"sync"
	"time"
)

const publicationTimeout = 5 * time.Second

type backgroundTasks struct {
	mu     sync.Mutex
	closed bool
	wg     sync.WaitGroup
}

func (b *backgroundTasks) start(parent context.Context, timeout time.Duration, task func(context.Context)) bool {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return false
	}
	b.wg.Add(1)
	b.mu.Unlock()
	go func() {
		defer b.wg.Done()
		ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), timeout)
		defer cancel()
		task(ctx)
	}()
	return true
}

func (b *backgroundTasks) drain(ctx context.Context) error {
	b.mu.Lock()
	b.closed = true
	b.mu.Unlock()
	done := make(chan struct{})
	go func() { b.wg.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
