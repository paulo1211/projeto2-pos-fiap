package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// App struct (para injeção de dependência)
type App struct {
	DB        *sql.DB
	MasterKey string
}

func main() {
	// Carrega o .env para desenvolvimento local. Em produção, isso não fará nada.
	_ = godotenv.Load()

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8001" // Porta padrão
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL deve ser definida")
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		log.Fatal("MASTER_KEY deve ser definida")
	}

	// --- OpenTelemetry ---
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdownTelemetry, err := setupTelemetry(ctx, "auth-service")
	if err != nil {
		log.Fatalf("Não foi possível inicializar o OpenTelemetry: %v", err)
	}

	// --- Conexão com o Banco ---
	db, err := connectDB(databaseURL)
	if err != nil {
		log.Fatalf("Não foi possível conectar ao banco de dados: %v", err)
	}
	defer db.Close()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)

	// Endpoint público para validar uma chave
	// (WithRouteTag preenche http.route, usado nas métricas por rota)
	mux.Handle("/validate", otelhttp.WithRouteTag("/validate", http.HandlerFunc(app.validateKeyHandler)))

	// Endpoints de "admin" para criar/gerenciar chaves
	// Eles são protegidos pelo middleware de autenticação
	mux.Handle("/admin/keys", otelhttp.WithRouteTag("/admin/keys",
		app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler))))

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           instrumentHandler(mux, "auth-service"),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("Serviço de Autenticação (Go) rodando na porta %s", port)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	// Encerramento gracioso: termina as requisições em andamento e faz flush
	// dos spans/métricas pendentes antes de o pod ser finalizado.
	<-ctx.Done()
	log.Println("Sinal de encerramento recebido, finalizando...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("Erro ao encerrar o servidor HTTP: %v", err)
		_ = server.Close()
	}
	cancel()
	flushCtx, cancelFlush := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelFlush()
	if err := shutdownTelemetry(flushCtx); err != nil {
		log.Printf("Erro ao encerrar o OpenTelemetry: %v", err)
	}
}

// connectDB inicializa e testa a conexão com o PostgreSQL
func connectDB(databaseURL string) (*sql.DB, error) {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, err
	}

	if err = db.Ping(); err != nil {
		return nil, err
	}

	log.Println("Conectado ao PostgreSQL com sucesso!")
	return db, nil
}
