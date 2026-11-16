package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Com a falha injetada, /validate responde 500 (conta no alerta de 5xx) sem
// tocar no banco; desligando, volta ao comportamento normal.
func TestChaosTogglesValidateFailure(t *testing.T) {
	app := &App{MasterKey: "master"}
	chaos := app.masterKeyAuthMiddleware(http.HandlerFunc(app.chaosHandler))

	post := func(body, key string) int {
		req := httptest.NewRequest(http.MethodPost, "/admin/chaos", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+key)
		rec := httptest.NewRecorder()
		chaos.ServeHTTP(rec, req)
		return rec.Code
	}
	validate := func() int {
		req := httptest.NewRequest(http.MethodGet, "/validate", nil)
		req.Header.Set("Authorization", "Bearer tm_key_qualquer")
		rec := httptest.NewRecorder()
		app.validateKeyHandler(rec, req)
		return rec.Code
	}

	if code := post(`{"fail": true}`, "errada"); code != http.StatusForbidden {
		t.Fatalf("sem MASTER_KEY: status = %d, esperado 403", code)
	}
	if app.failValidate.Load() {
		t.Fatal("falha não pode ser ligada sem MASTER_KEY")
	}
	if code := post(`{"fail": true}`, "master"); code != http.StatusOK {
		t.Fatalf("ligar: status = %d", code)
	}
	if code := validate(); code != http.StatusInternalServerError {
		t.Fatalf("com falha: /validate = %d, esperado 500", code)
	}
	if code := post(`{"fail": false}`, "master"); code != http.StatusOK {
		t.Fatalf("desligar: status = %d", code)
	}
	if app.failValidate.Load() {
		t.Fatal("falha deveria estar desligada")
	}
	if code := post(`nada`, "master"); code != http.StatusBadRequest {
		t.Fatalf("corpo inválido: status = %d, esperado 400", code)
	}
}
