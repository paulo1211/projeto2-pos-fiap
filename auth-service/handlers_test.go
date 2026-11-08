package main

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"testing"

	_ "github.com/jackc/pgx/v4/stdlib"
)

// Banco indisponível é falha de infraestrutura: /validate deve responder 5xx
// (e não 401 "chave inválida"), para aparecer nos traces e no alerta de 5xx.
func TestValidateKeyReturns503WhenDatabaseIsDown(t *testing.T) {
	// Porta 1 em localhost: conexão recusada imediatamente.
	db, err := sql.Open("pgx", "postgres://user:pass@127.0.0.1:1/db?connect_timeout=1")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	app := &App{DB: db}
	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", "Bearer tm_key_qualquer")
	rec := httptest.NewRecorder()

	app.validateKeyHandler(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusServiceUnavailable)
	}
}

func TestValidateKeyReturns401WithoutHeader(t *testing.T) {
	app := &App{}
	rec := httptest.NewRecorder()

	app.validateKeyHandler(rec, httptest.NewRequest(http.MethodGet, "/validate", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusUnauthorized)
	}
}
