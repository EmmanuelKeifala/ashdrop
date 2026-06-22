// Ashdrop API — a thin, zero-knowledge blob store with a view counter.
// All crypto is client-side; the server never sees a key or plaintext.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	maxBody = 96 * 1024       // ciphertext is capped ~64KB; leave room for JSON
	maxTTL  = 30 * 24 * 3600  // 30 days
	minTTL  = 60              // 1 minute floor
)

var store *Store

func main() {
	dbPath := getenv("ASHDROP_DB", "ashdrop.db")
	st, err := OpenStore(dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	store = st
	defer st.Close()

	go cleanupLoop(st)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/secrets", handleCreate)
	mux.HandleFunc("GET /api/secrets/{id}", handleGet)
	mux.HandleFunc("POST /api/secrets/{id}/burn", handleBurn)
	mux.HandleFunc("GET /api/secrets/{id}/status", handleStatus)
	mux.HandleFunc("DELETE /api/secrets/{id}", handleDelete)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	addr := ":" + getenv("PORT", "8080")
	log.Printf("ashdrop api listening on %s (db: %s)", addr, dbPath)
	log.Fatal(http.ListenAndServe(addr, cors(rateLimit(mux))))
}

// ---- handlers ----

func handleCreate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	var req struct {
		Ciphertext string `json:"ciphertext"`
		IV         string `json:"iv"`
		TTL        int    `json:"ttl"`
		MaxViews   int    `json:"maxViews"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Ciphertext == "" || req.IV == "" {
		httpError(w, http.StatusBadRequest, "ciphertext and iv are required")
		return
	}
	if len(req.Ciphertext) > maxBody {
		httpError(w, http.StatusRequestEntityTooLarge, "secret too large")
		return
	}

	ttl := req.TTL
	if ttl < minTTL {
		ttl = 24 * 3600
	}
	if ttl > maxTTL {
		ttl = maxTTL
	}
	maxViews := req.MaxViews
	if maxViews < 0 {
		maxViews = 0
	}

	id, notify := randHex(16), randHex(16)
	sec := Secret{
		Ciphertext: req.Ciphertext,
		IV:         req.IV,
		MaxViews:   maxViews,
		ExpiresAt:  time.Now().Unix() + int64(ttl),
		NotifyTok:  notify,
	}
	if err := store.Put(id, sec); err != nil {
		httpError(w, http.StatusInternalServerError, "could not store secret")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":          id,
		"notifyToken": notify,
		"expiresAt":   sec.ExpiresAt,
	})
}

func handleGet(w http.ResponseWriter, r *http.Request) {
	sec, err := store.Fetch(r.PathValue("id"))
	if err != nil {
		httpError(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if sec == nil {
		httpError(w, http.StatusNotFound, "this secret no longer exists")
		return
	}
	viewsLeft := -1 // unlimited
	if sec.MaxViews > 0 {
		viewsLeft = sec.MaxViews - sec.Views
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ciphertext": sec.Ciphertext,
		"iv":         sec.IV,
		"viewsLeft":  viewsLeft,
	})
}

func handleBurn(w http.ResponseWriter, r *http.Request) {
	if err := store.Burn(r.PathValue("id")); err != nil {
		httpError(w, http.StatusInternalServerError, "burn failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	tok := r.URL.Query().Get("notifyToken")
	notifyTok, opened, openedAt, found, err := store.Status(id)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "status failed")
		return
	}
	if !found {
		httpError(w, http.StatusNotFound, "not found")
		return
	}
	if tok == "" || tok != notifyTok {
		httpError(w, http.StatusForbidden, "invalid token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"opened":   opened,
		"openedAt": openedAt,
	})
}

func handleDelete(w http.ResponseWriter, r *http.Request) {
	if err := store.Delete(r.PathValue("id")); err != nil {
		httpError(w, http.StatusInternalServerError, "delete failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- middleware ----

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// rateLimit is a small fixed-window per-IP limiter on writes (POST). Reads pass.
func rateLimit(next http.Handler) http.Handler {
	type win struct {
		start time.Time
		count int
	}
	var (
		mu      sync.Mutex
		windows = map[string]*win{}
		limit   = 30 // creates per minute per IP
	)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || !strings.HasPrefix(r.URL.Path, "/api/secrets") || strings.HasSuffix(r.URL.Path, "/burn") {
			next.ServeHTTP(w, r)
			return
		}
		ip := clientIP(r)
		mu.Lock()
		x := windows[ip]
		if x == nil || time.Since(x.start) > time.Minute {
			x = &win{start: time.Now()}
			windows[ip] = x
		}
		x.count++
		over := x.count > limit
		mu.Unlock()
		if over {
			w.Header().Set("Retry-After", "60")
			httpError(w, http.StatusTooManyRequests, "slow down")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- helpers ----

func cleanupLoop(s *Store) {
	t := time.NewTicker(5 * time.Minute)
	defer t.Stop()
	for range t.C {
		if n, err := s.Cleanup(); err == nil && n > 0 {
			log.Printf("cleanup: removed %d expired secrets", n)
		}
	}
}

func clientIP(r *http.Request) string {
	if f := r.Header.Get("X-Forwarded-For"); f != "" {
		return strings.TrimSpace(strings.Split(f, ",")[0])
	}
	host, _, found := strings.Cut(r.RemoteAddr, ":")
	if !found {
		return r.RemoteAddr
	}
	return host
}

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
