// Ashdrop API — a thin, zero-knowledge blob store with a view counter.
// All crypto is client-side; the server never sees a key or plaintext.
package main

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxBody = 96 * 1024      // ciphertext is capped ~64KB; leave room for JSON
	maxTTL  = 30 * 24 * 3600 // 30 days
	minTTL  = 60             // 1 minute floor

	inboxProofHeader = "X-Ashdrop-Inbox-Proof"
	inboxProofInfo   = "ashdrop-inbox-v1"

	maxRateLimitWindows = 4096
)

type API struct {
	store *Store
}

type inboxResponseItem struct {
	ID        string `json:"id"`
	ExpiresAt int64  `json:"expiresAt"`
	ViewsLeft int    `json:"viewsLeft"`
}

func main() {
	dbPath := getenv("ASHDROP_DB", "ashdrop.db")
	st, err := OpenStore(dbPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer st.Close()

	go cleanupLoop(st)

	addr := ":" + getenv("PORT", "8080")
	log.Printf("ashdrop api listening on %s (db: %s)", addr, dbPath)
	log.Fatal(http.ListenAndServe(addr, newHandler(st)))
}

// ---- handlers ----

func newHandler(store *Store) http.Handler {
	api := &API{store: store}
	trustProxy, _ := strconv.ParseBool(os.Getenv("ASHDROP_TRUST_PROXY"))
	createLimiter := newIPRateLimiter(30)
	inboxLimiter := newIPRateLimiter(30)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/secrets", api.handleCreate)
	mux.HandleFunc("GET /api/secrets/{id}", api.handleGet)
	mux.HandleFunc("GET /api/secrets/{id}/metadata", api.handleMetadata)
	mux.HandleFunc("POST /api/secrets/{id}/open", api.handleOpen)
	mux.HandleFunc("POST /api/secrets/{id}/burn", api.handleBurn)
	mux.HandleFunc("GET /api/secrets/{id}/status", api.handleStatus)
	mux.HandleFunc("DELETE /api/secrets/{id}", api.handleDelete)
	mux.HandleFunc("GET /api/inbox-key", api.handleInboxKey)
	mux.Handle("GET /api/addresses/{recipientPub}/inbox", inboxRateLimit(http.HandlerFunc(api.handleInbox), inboxLimiter, trustProxy))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	return cors(rateLimit(mux, createLimiter, trustProxy))
}

func (api *API) handleCreate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	var req struct {
		Ciphertext   string `json:"ciphertext"`
		IV           string `json:"iv"`
		TTL          int    `json:"ttl"`
		MaxViews     int    `json:"maxViews"`
		RecipientPub string `json:"recipientPub"`
		EphemeralPub string `json:"ephemeralPub"` // non-empty = recipient-keyed ECDH drop
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
	if (req.RecipientPub == "") != (req.EphemeralPub == "") ||
		(req.RecipientPub != "" && (!validPublicKey(req.RecipientPub) || !validPublicKey(req.EphemeralPub))) {
		httpError(w, http.StatusBadRequest, "invalid recipient public key")
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
		Ciphertext:   req.Ciphertext,
		IV:           req.IV,
		MaxViews:     maxViews,
		ExpiresAt:    time.Now().Unix() + int64(ttl),
		NotifyTok:    notify,
		RecipientPub: req.RecipientPub,
		EphemeralPub: req.EphemeralPub,
	}
	if err := api.store.Put(id, sec); err != nil {
		httpError(w, http.StatusInternalServerError, "could not store secret")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":          id,
		"notifyToken": notify,
		"expiresAt":   sec.ExpiresAt,
	})
}

func (api *API) handleGet(w http.ResponseWriter, r *http.Request) {
	sec, err := api.store.Fetch(r.PathValue("id"))
	if err != nil {
		httpError(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if sec == nil {
		httpError(w, http.StatusNotFound, "this secret no longer exists")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ciphertext":     sec.Ciphertext,
		"iv":             sec.IV,
		"viewsLeft":      viewsLeft(sec),
		"ephemeralPub":   sec.EphemeralPub,
		"recipientKeyed": sec.EphemeralPub != "",
	})
}

func (api *API) handleMetadata(w http.ResponseWriter, r *http.Request) {
	sec, err := api.store.Metadata(r.PathValue("id"))
	if err != nil {
		httpError(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if sec == nil {
		httpError(w, http.StatusNotFound, "this secret no longer exists")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"recipientKeyed": sec.EphemeralPub != "",
		"recipientPub":   sec.RecipientPub,
		"expiresAt":      sec.ExpiresAt,
		"viewsLeft":      viewsLeft(sec),
	})
}

func (api *API) handleOpen(w http.ResponseWriter, r *http.Request) {
	sec, err := api.store.Open(r.PathValue("id"))
	if err != nil {
		httpError(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if sec == nil {
		httpError(w, http.StatusNotFound, "this secret no longer exists")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ciphertext":     sec.Ciphertext,
		"iv":             sec.IV,
		"ephemeralPub":   sec.EphemeralPub,
		"recipientKeyed": sec.EphemeralPub != "",
	})
}

func (api *API) handleBurn(w http.ResponseWriter, r *http.Request) {
	if err := api.store.Burn(r.PathValue("id")); err != nil {
		httpError(w, http.StatusInternalServerError, "burn failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (api *API) handleStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	tok := r.URL.Query().Get("notifyToken")
	notifyTok, opened, openedAt, found, err := api.store.Status(id)
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

func (api *API) handleDelete(w http.ResponseWriter, r *http.Request) {
	if err := api.store.Delete(r.PathValue("id")); err != nil {
		httpError(w, http.StatusInternalServerError, "delete failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (api *API) handleInboxKey(w http.ResponseWriter, _ *http.Request) {
	key, err := loadInboxServerKey(api.store)
	if err != nil {
		inboxInternalError(w)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]string{
		"publicKey": base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
	})
}

func (api *API) handleInbox(w http.ResponseWriter, r *http.Request) {
	limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || limit < 1 || limit > 100 {
		inboxUnauthorized(w)
		return
	}

	recipientPub := r.PathValue("recipientPub")
	recipientBytes, err := base64.RawURLEncoding.DecodeString(recipientPub)
	if err != nil || len(recipientBytes) != 65 || recipientBytes[0] != 0x04 || base64.RawURLEncoding.EncodeToString(recipientBytes) != recipientPub {
		inboxUnauthorized(w)
		return
	}
	recipientKey, err := ecdh.P256().NewPublicKey(recipientBytes)
	if err != nil {
		inboxUnauthorized(w)
		return
	}

	at, err := strconv.ParseInt(r.URL.Query().Get("at"), 10, 64)
	serverNow := time.Now().Unix()
	if err != nil || at < serverNow-5*60 || at > serverNow+5*60 {
		inboxUnauthorized(w)
		return
	}

	proofText := r.Header.Get(inboxProofHeader)
	proof, err := base64.RawURLEncoding.DecodeString(proofText)
	if err != nil || len(proof) != sha256.Size || base64.RawURLEncoding.EncodeToString(proof) != proofText {
		clear(proof)
		inboxUnauthorized(w)
		return
	}
	defer clear(proof)

	serverKey, err := loadInboxServerKey(api.store)
	if err != nil {
		inboxInternalError(w)
		return
	}
	sharedSecret, err := serverKey.ECDH(recipientKey)
	if err != nil {
		clear(sharedSecret)
		inboxInternalError(w)
		return
	}
	defer clear(sharedSecret)
	hmacKey, err := hkdf.Key(sha256.New, sharedSecret, make([]byte, sha256.Size), inboxProofInfo, sha256.Size)
	clear(sharedSecret)
	if err != nil {
		clear(hmacKey)
		inboxInternalError(w)
		return
	}
	defer clear(hmacKey)

	canonicalRequest := inboxProofInfo + "\nGET\n/api/addresses/" + recipientPub + "/inbox\nlimit=" + strconv.Itoa(limit) + "&at=" + strconv.FormatInt(at, 10)
	mac := hmac.New(sha256.New, hmacKey)
	clear(hmacKey)
	_, _ = mac.Write([]byte(canonicalRequest))
	expectedProof := mac.Sum(nil)
	proofMatches := subtle.ConstantTimeCompare(proof, expectedProof)
	clear(expectedProof)
	clear(proof)
	if proofMatches != 1 {
		inboxUnauthorized(w)
		return
	}

	items, err := api.store.ListInbox(recipientPub, limit)
	if err != nil {
		inboxInternalError(w)
		return
	}
	responseItems := make([]inboxResponseItem, len(items))
	for i, item := range items {
		responseItems[i] = inboxResponseItem{
			ID:        item.ID,
			ExpiresAt: item.ExpiresAt,
			ViewsLeft: item.ViewsLeft,
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"items": responseItems})
}

// ---- middleware ----

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Ashdrop-Inbox-Proof")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type rateWindow struct {
	start time.Time
	count int
}

type ipRateLimiter struct {
	mu      sync.Mutex
	windows map[string]rateWindow
	limit   int
}

func newIPRateLimiter(limit int) *ipRateLimiter {
	return &ipRateLimiter{
		windows: make(map[string]rateWindow),
		limit:   limit,
	}
}

func (l *ipRateLimiter) allow(ip string) bool {
	current := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()

	for key, window := range l.windows {
		if current.Sub(window.start) > time.Minute {
			delete(l.windows, key)
		}
	}

	window, found := l.windows[ip]
	if !found {
		if len(l.windows) >= maxRateLimitWindows {
			return false
		}
		l.windows[ip] = rateWindow{start: current, count: 1}
		return true
	}
	window.count++
	l.windows[ip] = window
	return window.count <= l.limit
}

// rateLimit is a small fixed-window per-IP limiter on creates. Other requests pass.
func rateLimit(next http.Handler, limiter *ipRateLimiter, trustProxy bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/secrets" {
			next.ServeHTTP(w, r)
			return
		}
		if !limiter.allow(clientIP(r, trustProxy)) {
			w.Header().Set("Retry-After", "60")
			httpError(w, http.StatusTooManyRequests, "slow down")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// inboxRateLimit protects the ECDH inbox path from unauthenticated CPU abuse.
func inboxRateLimit(next http.Handler, limiter *ipRateLimiter, trustProxy bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !limiter.allow(clientIP(r, trustProxy)) {
			w.Header().Set("Retry-After", "60")
			httpError(w, http.StatusTooManyRequests, "too many requests")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- helpers ----

func viewsLeft(sec *Secret) int {
	if sec.MaxViews > 0 {
		return sec.MaxViews - sec.Views
	}
	return -1 // unlimited
}

func validPublicKey(encoded string) bool {
	pub, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(pub) != 65 || pub[0] != 0x04 || base64.RawURLEncoding.EncodeToString(pub) != encoded {
		return false
	}
	_, err = ecdh.P256().NewPublicKey(pub)
	return err == nil
}

func inboxUnauthorized(w http.ResponseWriter) {
	httpError(w, http.StatusUnauthorized, "unauthorized")
}

func inboxInternalError(w http.ResponseWriter) {
	httpError(w, http.StatusInternalServerError, "internal server error")
}

func loadInboxServerKey(store *Store) (*ecdh.PrivateKey, error) {
	privateKey, err := store.InboxPrivateKey()
	if err != nil {
		return nil, err
	}
	defer clear(privateKey)
	return ecdh.P256().NewPrivateKey(privateKey)
}

func cleanupLoop(s *Store) {
	t := time.NewTicker(5 * time.Minute)
	defer t.Stop()
	for range t.C {
		if n, err := s.Cleanup(); err == nil && n > 0 {
			log.Printf("cleanup: removed %d expired secrets", n)
		}
	}
}

func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		forwarded, _, _ := strings.Cut(r.Header.Get("X-Forwarded-For"), ",")
		if forwarded = strings.TrimSpace(forwarded); forwarded != "" {
			return forwarded
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
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
