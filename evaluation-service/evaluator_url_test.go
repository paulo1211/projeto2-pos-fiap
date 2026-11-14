package main

import (
	"errors"
	"testing"
)

func TestDownstreamURL(t *testing.T) {
	got, err := downstreamURL("http://flag-service:8002", "flags", "enable-new-dashboard_v2.1")
	if err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}
	if want := "http://flag-service:8002/flags/enable-new-dashboard_v2.1"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}

	// Barra final na base não duplica a barra.
	got, err = downstreamURL("http://targeting-service:8003/", "rules", "x")
	if err != nil || got != "http://targeting-service:8003/rules/x" {
		t.Fatalf("got %q (%v)", got, err)
	}
}

func TestDownstreamURLRejectsUnsafeNames(t *testing.T) {
	for _, name := range []string{
		"", "..", ".", "../admin", "a/b", "x?admin=1", "x#frag", "x%2Fy",
		"a b", "@evil.com", "-x", "http://evil.com",
	} {
		if _, err := downstreamURL("http://flag-service:8002", "flags", name); !errors.Is(err, ErrInvalidFlagName) {
			t.Errorf("nome %q deveria ser rejeitado, err=%v", name, err)
		}
	}
}

func TestDownstreamURLRejectsBadBase(t *testing.T) {
	for _, base := range []string{"", "flag-service:8002", "ftp://flag-service", "http://"} {
		if _, err := downstreamURL(base, "flags", "ok"); err == nil {
			t.Errorf("base %q deveria ser rejeitada", base)
		}
	}
}
