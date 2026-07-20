package main

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type testAPI struct {
	store   *Store
	handler http.Handler
}

type createResponse struct {
	ID          string `json:"id"`
	NotifyToken string `json:"notifyToken"`
	ExpiresAt   int64  `json:"expiresAt"`
}

type inboxResponse struct {
	Items []inboxResponseItem `json:"items"`
}

func newTestAPI(t *testing.T) *testAPI {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "ashdrop.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return &testAPI{store: store, handler: newHandler(store)}
}

func request(t *testing.T, handler http.Handler, method, target, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	return requestFrom(t, handler, method, target, body, headers, "192.0.2.1:1234")
}

func requestFrom(t *testing.T, handler http.Handler, method, target, body string, headers map[string]string, remoteAddr string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.RemoteAddr = remoteAddr
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func decodeJSON[T any](t *testing.T, recorder *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(recorder.Body.Bytes(), &value); err != nil {
		t.Fatalf("decode response %q: %v", recorder.Body.String(), err)
	}
	return value
}

func p256Key(t *testing.T) (*ecdh.PrivateKey, string) {
	t.Helper()
	privateKey, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate P-256 key: %v", err)
	}
	return privateKey, base64.RawURLEncoding.EncodeToString(privateKey.PublicKey().Bytes())
}

func createPayload(t *testing.T, recipientPub, ephemeralPub string, ttl, maxViews int) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"ciphertext":   "ciphertext-value",
		"iv":           "nonce-value",
		"ttl":          ttl,
		"maxViews":     maxViews,
		"recipientPub": recipientPub,
		"ephemeralPub": ephemeralPub,
	})
	if err != nil {
		t.Fatalf("encode create payload: %v", err)
	}
	return string(body)
}

func createDrop(t *testing.T, api *testAPI, recipientPub, ephemeralPub string, ttl, maxViews int) createResponse {
	t.Helper()
	recorder := request(t, api.handler, http.MethodPost, "/api/secrets", createPayload(t, recipientPub, ephemeralPub, ttl, maxViews), nil)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("create status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	return decodeJSON[createResponse](t, recorder)
}

func inboxProof(t *testing.T, api *testAPI, recipientPrivate *ecdh.PrivateKey, recipientPub string, limit int, at int64) string {
	t.Helper()
	canonical := inboxProofInfo + "\nGET\n/api/addresses/" + recipientPub + "/inbox\nlimit=" + fmt.Sprint(limit) + "&at=" + fmt.Sprint(at)
	return inboxProofForCanonical(t, api, recipientPrivate, canonical)
}

func inboxProofForCanonical(t *testing.T, api *testAPI, recipientPrivate *ecdh.PrivateKey, canonical string) string {
	t.Helper()
	recorder := request(t, api.handler, http.MethodGet, "/api/inbox-key", "", nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("inbox key status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	response := decodeJSON[struct {
		PublicKey string `json:"publicKey"`
	}](t, recorder)
	serverBytes, err := base64.RawURLEncoding.DecodeString(response.PublicKey)
	if err != nil {
		t.Fatalf("decode inbox key: %v", err)
	}
	serverPublic, err := ecdh.P256().NewPublicKey(serverBytes)
	if err != nil {
		t.Fatalf("parse inbox key: %v", err)
	}
	shared, err := recipientPrivate.ECDH(serverPublic)
	if err != nil {
		t.Fatalf("derive inbox shared secret: %v", err)
	}
	key, err := hkdf.Key(sha256.New, shared, make([]byte, sha256.Size), inboxProofInfo, sha256.Size)
	clear(shared)
	if err != nil {
		t.Fatalf("derive inbox proof key: %v", err)
	}
	defer clear(key)
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(canonical))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func inboxRequest(t *testing.T, api *testAPI, recipientPub string, limit int, at int64, proof string) *httptest.ResponseRecorder {
	t.Helper()
	target := fmt.Sprintf("/api/addresses/%s/inbox?limit=%d&at=%d", recipientPub, limit, at)
	return request(t, api.handler, http.MethodGet, target, "", map[string]string{inboxProofHeader: proof})
}

func assertError(t *testing.T, recorder *httptest.ResponseRecorder, status int, message string) {
	t.Helper()
	if recorder.Code != status {
		t.Fatalf("status = %d, want %d; body = %s", recorder.Code, status, recorder.Body.String())
	}
	response := decodeJSON[map[string]string](t, recorder)
	if response["error"] != message {
		t.Fatalf("error = %q, want %q", response["error"], message)
	}
}

func TestCreateRecipientKeyValidation(t *testing.T) {
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	offCurveBytes := make([]byte, 65)
	offCurveBytes[0] = 0x04
	offCurve := base64.RawURLEncoding.EncodeToString(offCurveBytes)
	wrongPrefixBytes := make([]byte, 65)
	wrongPrefixBytes[0] = 0x02
	wrongPrefix := base64.RawURLEncoding.EncodeToString(wrongPrefixBytes)

	tests := []struct {
		name       string
		body       string
		wantStatus int
	}{
		{name: "valid pair", body: createPayload(t, recipient, ephemeral, 3600, 1), wantStatus: http.StatusCreated},
		{name: "malformed JSON", body: "{", wantStatus: http.StatusBadRequest},
		{name: "missing ciphertext", body: `{"iv":"nonce"}`, wantStatus: http.StatusBadRequest},
		{name: "missing IV", body: `{"ciphertext":"cipher"}`, wantStatus: http.StatusBadRequest},
		{name: "recipient only", body: createPayload(t, recipient, "", 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "ephemeral only", body: createPayload(t, "", ephemeral, 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "malformed recipient", body: createPayload(t, "%%%", ephemeral, 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "padded recipient", body: createPayload(t, recipient+"=", ephemeral, 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "short recipient", body: createPayload(t, base64.RawURLEncoding.EncodeToString([]byte{4, 1}), ephemeral, 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "wrong recipient prefix", body: createPayload(t, wrongPrefix, ephemeral, 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "off curve recipient", body: createPayload(t, offCurve, ephemeral, 3600, 1), wantStatus: http.StatusBadRequest},
		{name: "off curve ephemeral", body: createPayload(t, recipient, offCurve, 3600, 1), wantStatus: http.StatusBadRequest},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			api := newTestAPI(t)
			recorder := request(t, api.handler, http.MethodPost, "/api/secrets", test.body, nil)
			if recorder.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d; body = %s", recorder.Code, test.wantStatus, recorder.Body.String())
			}
		})
	}
}

func TestCreateAppliesTTLAndViewBounds(t *testing.T) {
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	tests := []struct {
		name          string
		ttl           int
		maxViews      int
		wantTTL       int64
		wantViewsLeft int
	}{
		{name: "short TTL defaults", ttl: minTTL - 1, maxViews: -1, wantTTL: 24 * 3600, wantViewsLeft: -1},
		{name: "long TTL clamps", ttl: maxTTL + 1, maxViews: 2, wantTTL: maxTTL, wantViewsLeft: 2},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			api := newTestAPI(t)
			before := time.Now().Unix()
			created := createDrop(t, api, recipient, ephemeral, test.ttl, test.maxViews)
			if created.ExpiresAt < before+test.wantTTL || created.ExpiresAt > time.Now().Unix()+test.wantTTL {
				t.Fatalf("expiresAt = %d, want current time + %d", created.ExpiresAt, test.wantTTL)
			}
			recorder := request(t, api.handler, http.MethodGet, "/api/secrets/"+created.ID+"/metadata", "", nil)
			metadata := decodeJSON[struct {
				ViewsLeft int `json:"viewsLeft"`
			}](t, recorder)
			if metadata.ViewsLeft != test.wantViewsLeft {
				t.Fatalf("viewsLeft = %d, want %d", metadata.ViewsLeft, test.wantViewsLeft)
			}
		})
	}
}

func TestCreateRateLimit(t *testing.T) {
	api := newTestAPI(t)
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	body := createPayload(t, recipient, ephemeral, 3600, 1)
	for attempt := 1; attempt <= 30; attempt++ {
		recorder := request(t, api.handler, http.MethodPost, "/api/secrets", body, nil)
		if recorder.Code != http.StatusCreated {
			t.Fatalf("attempt %d status = %d, want 201", attempt, recorder.Code)
		}
	}
	otherIP := requestFrom(t, api.handler, http.MethodPost, "/api/secrets", body, nil, "198.51.100.2:4321")
	if otherIP.Code != http.StatusCreated {
		t.Fatalf("other IP status = %d, want 201", otherIP.Code)
	}
	limited := request(t, api.handler, http.MethodPost, "/api/secrets", body, map[string]string{"X-Forwarded-For": "203.0.113.7"})
	if limited.Code != http.StatusTooManyRequests || limited.Header().Get("Retry-After") != "60" {
		t.Fatalf("rate limit response: status=%d retry=%q", limited.Code, limited.Header().Get("Retry-After"))
	}
}

func TestCreateRateLimitUsesTrustedProxyAddress(t *testing.T) {
	t.Setenv("ASHDROP_TRUST_PROXY", "true")
	api := newTestAPI(t)
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	body := createPayload(t, recipient, ephemeral, 3600, 1)
	for attempt := 1; attempt <= 30; attempt++ {
		recorder := request(t, api.handler, http.MethodPost, "/api/secrets", body, map[string]string{"X-Forwarded-For": "203.0.113.1"})
		if recorder.Code != http.StatusCreated {
			t.Fatalf("attempt %d status = %d, want 201", attempt, recorder.Code)
		}
	}
	otherForwardedIP := request(t, api.handler, http.MethodPost, "/api/secrets", body, map[string]string{"X-Forwarded-For": "203.0.113.2, 10.0.0.1"})
	if otherForwardedIP.Code != http.StatusCreated {
		t.Fatalf("other forwarded IP status = %d, want 201", otherForwardedIP.Code)
	}
	limited := request(t, api.handler, http.MethodPost, "/api/secrets", body, map[string]string{"X-Forwarded-For": "203.0.113.1"})
	if limited.Code != http.StatusTooManyRequests {
		t.Fatalf("limited forwarded IP status = %d, want 429", limited.Code)
	}
}

func TestMetadataRouteStates(t *testing.T) {
	api := newTestAPI(t)
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	created := createDrop(t, api, recipient, ephemeral, 3600, 2)

	recorder := request(t, api.handler, http.MethodGet, "/api/secrets/"+created.ID+"/metadata", "", nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("metadata status = %d", recorder.Code)
	}
	metadata := decodeJSON[map[string]any](t, recorder)
	if metadata["recipientKeyed"] != true || metadata["recipientPub"] != recipient || metadata["viewsLeft"] != float64(2) {
		t.Fatalf("unexpected metadata: %#v", metadata)
	}
	if len(metadata) != 4 {
		t.Fatalf("metadata fields = %#v", metadata)
	}
	if _, found := metadata["ciphertext"]; found {
		t.Fatal("metadata exposed ciphertext")
	}

	firstOpen := request(t, api.handler, http.MethodPost, "/api/secrets/"+created.ID+"/open", "", nil)
	if firstOpen.Code != http.StatusOK {
		t.Fatalf("first open status = %d", firstOpen.Code)
	}
	recorder = request(t, api.handler, http.MethodGet, "/api/secrets/"+created.ID+"/metadata", "", nil)
	metadata = decodeJSON[map[string]any](t, recorder)
	if metadata["viewsLeft"] != float64(1) {
		t.Fatalf("viewsLeft after open = %#v", metadata["viewsLeft"])
	}

	_ = request(t, api.handler, http.MethodPost, "/api/secrets/"+created.ID+"/open", "", nil)
	assertError(t, request(t, api.handler, http.MethodGet, "/api/secrets/"+created.ID+"/metadata", "", nil), http.StatusNotFound, "this secret no longer exists")
	assertError(t, request(t, api.handler, http.MethodGet, "/api/secrets/missing/metadata", "", nil), http.StatusNotFound, "this secret no longer exists")

	if err := api.store.Put("expired", Secret{Ciphertext: "cipher", IV: "iv", MaxViews: 1, ExpiresAt: time.Now().Unix() - 1, NotifyTok: "notify", RecipientPub: recipient, EphemeralPub: ephemeral}); err != nil {
		t.Fatal(err)
	}
	assertError(t, request(t, api.handler, http.MethodGet, "/api/secrets/expired/metadata", "", nil), http.StatusNotFound, "this secret no longer exists")
}

func TestOpenRouteStates(t *testing.T) {
	api := newTestAPI(t)
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	limited := createDrop(t, api, recipient, ephemeral, 3600, 1)

	recorder := request(t, api.handler, http.MethodPost, "/api/secrets/"+limited.ID+"/open", "", nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("open status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	opened := decodeJSON[map[string]any](t, recorder)
	if opened["ciphertext"] != "ciphertext-value" || opened["iv"] != "nonce-value" || opened["ephemeralPub"] != ephemeral || opened["recipientKeyed"] != true {
		t.Fatalf("unexpected open response: %#v", opened)
	}
	if _, found := opened["recipientPub"]; found {
		t.Fatal("open response exposed recipient public key")
	}
	assertError(t, request(t, api.handler, http.MethodPost, "/api/secrets/"+limited.ID+"/open", "", nil), http.StatusNotFound, "this secret no longer exists")
	assertError(t, request(t, api.handler, http.MethodPost, "/api/secrets/missing/open", "", nil), http.StatusNotFound, "this secret no longer exists")

	unlimited := createDrop(t, api, recipient, ephemeral, 3600, 0)
	for range 2 {
		if got := request(t, api.handler, http.MethodPost, "/api/secrets/"+unlimited.ID+"/open", "", nil).Code; got != http.StatusOK {
			t.Fatalf("unlimited open status = %d", got)
		}
	}

	if err := api.store.Put("expired", Secret{Ciphertext: "cipher", IV: "iv", MaxViews: 1, ExpiresAt: time.Now().Unix() - 1, NotifyTok: "notify", RecipientPub: recipient, EphemeralPub: ephemeral}); err != nil {
		t.Fatal(err)
	}
	assertError(t, request(t, api.handler, http.MethodPost, "/api/secrets/expired/open", "", nil), http.StatusNotFound, "this secret no longer exists")
}

func TestOpenFinalViewIsAtomic(t *testing.T) {
	api := newTestAPI(t)
	api.store.db.SetMaxOpenConns(8)
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	created := createDrop(t, api, recipient, ephemeral, 3600, 1)

	const requests = 20
	statuses := make(chan int, requests)
	var wait sync.WaitGroup
	for range requests {
		wait.Add(1)
		go func() {
			defer wait.Done()
			statuses <- request(t, api.handler, http.MethodPost, "/api/secrets/"+created.ID+"/open", "", nil).Code
		}()
	}
	wait.Wait()
	close(statuses)
	counts := map[int]int{}
	for status := range statuses {
		counts[status]++
	}
	if counts[http.StatusOK] != 1 || counts[http.StatusNotFound] != requests-1 {
		t.Fatalf("open status counts = %#v", counts)
	}
	var ciphertext string
	if err := api.store.db.QueryRow(`SELECT ciphertext FROM secrets WHERE id = ?`, created.ID).Scan(&ciphertext); err != nil {
		t.Fatal(err)
	}
	if ciphertext != "" {
		t.Fatal("final open did not wipe ciphertext")
	}
}

func TestInboxKeyRoute(t *testing.T) {
	api := newTestAPI(t)
	first := request(t, api.handler, http.MethodGet, "/api/inbox-key", "", nil)
	if first.Code != http.StatusOK || first.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("first inbox key response: status=%d cache=%q", first.Code, first.Header().Get("Cache-Control"))
	}
	firstBody := decodeJSON[map[string]string](t, first)
	encoded := firstBody["publicKey"]
	decoded, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(decoded) != 65 || decoded[0] != 0x04 || base64.RawURLEncoding.EncodeToString(decoded) != encoded {
		t.Fatalf("noncanonical inbox key %q: %v", encoded, err)
	}
	if _, err := ecdh.P256().NewPublicKey(decoded); err != nil {
		t.Fatalf("invalid inbox public key: %v", err)
	}
	second := decodeJSON[map[string]string](t, request(t, api.handler, http.MethodGet, "/api/inbox-key", "", nil))
	if second["publicKey"] != encoded {
		t.Fatal("inbox key changed between requests")
	}

	if err := api.store.Close(); err != nil {
		t.Fatal(err)
	}
	assertError(t, request(t, api.handler, http.MethodGet, "/api/inbox-key", "", nil), http.StatusInternalServerError, "internal server error")
}

func TestInboxListingFiltersAndOrders(t *testing.T) {
	api := newTestAPI(t)
	recipientPrivate, recipient := p256Key(t)
	_, otherRecipient := p256Key(t)
	_, ephemeral := p256Key(t)
	expires := time.Now().Unix() + 3600
	secrets := []struct {
		id        string
		recipient string
		createdAt int64
		maxViews  int
	}{
		{id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", recipient: recipient, createdAt: 2, maxViews: 0},
		{id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", recipient: recipient, createdAt: 2, maxViews: 2},
		{id: "cccccccccccccccccccccccccccccccc", recipient: otherRecipient, createdAt: 1, maxViews: 1},
	}
	for _, secret := range secrets {
		if err := api.store.Put(secret.id, Secret{Ciphertext: "cipher", IV: "iv", MaxViews: secret.maxViews, ExpiresAt: expires, CreatedAt: secret.createdAt, NotifyTok: "notify", RecipientPub: secret.recipient, EphemeralPub: ephemeral}); err != nil {
			t.Fatal(err)
		}
	}
	if err := api.store.Put("expiredexpiredexpiredexpired1234", Secret{Ciphertext: "cipher", IV: "iv", MaxViews: 1, ExpiresAt: time.Now().Unix() - 1, CreatedAt: 0, NotifyTok: "notify", RecipientPub: recipient, EphemeralPub: ephemeral}); err != nil {
		t.Fatal(err)
	}
	if err := api.store.Put("burnedburnedburnedburnedburned12", Secret{Ciphertext: "cipher", IV: "iv", MaxViews: 1, ExpiresAt: expires, CreatedAt: 0, NotifyTok: "notify", RecipientPub: recipient, EphemeralPub: ephemeral}); err != nil {
		t.Fatal(err)
	}
	if _, err := api.store.Open("burnedburnedburnedburnedburned12"); err != nil {
		t.Fatal(err)
	}

	at := time.Now().Unix()
	proof := inboxProof(t, api, recipientPrivate, recipient, 2, at)
	recorder := inboxRequest(t, api, recipient, 2, at, proof)
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("inbox response: status=%d cache=%q body=%s", recorder.Code, recorder.Header().Get("Cache-Control"), recorder.Body.String())
	}
	response := decodeJSON[inboxResponse](t, recorder)
	if len(response.Items) != 2 || response.Items[0].ID != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" || response.Items[0].ViewsLeft != 2 || response.Items[1].ID != "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" || response.Items[1].ViewsLeft != -1 {
		t.Fatalf("unexpected inbox items: %#v", response.Items)
	}
	var raw map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(recorder.Body.String(), "cipher") || strings.Contains(recorder.Body.String(), "nonce") {
		t.Fatal("inbox exposed encrypted payload")
	}
}

func TestInboxAuthenticationEdges(t *testing.T) {
	api := newTestAPI(t)
	recipientPrivate, recipient := p256Key(t)
	_, wrongRecipient := p256Key(t)
	now := time.Now().Unix()
	validProof := inboxProof(t, api, recipientPrivate, recipient, 20, now)
	wrongMethodProof := inboxProofForCanonical(t, api, recipientPrivate, inboxProofInfo+"\nPOST\n/api/addresses/"+recipient+"/inbox\nlimit=20&at="+fmt.Sprint(now))
	wrongPathProof := inboxProofForCanonical(t, api, recipientPrivate, inboxProofInfo+"\nGET\n/api/addresses/"+recipient+"/wrong\nlimit=20&at="+fmt.Sprint(now))
	offCurveBytes := make([]byte, 65)
	offCurveBytes[0] = 0x04
	offCurve := base64.RawURLEncoding.EncodeToString(offCurveBytes)
	wrongPrefixBytes := make([]byte, 65)
	wrongPrefixBytes[0] = 0x02
	wrongPrefix := base64.RawURLEncoding.EncodeToString(wrongPrefixBytes)

	tests := []struct {
		name      string
		recipient string
		limit     string
		at        string
		proof     string
	}{
		{name: "missing limit", recipient: recipient, at: fmt.Sprint(now), proof: validProof},
		{name: "zero limit", recipient: recipient, limit: "0", at: fmt.Sprint(now), proof: validProof},
		{name: "negative limit", recipient: recipient, limit: "-1", at: fmt.Sprint(now), proof: validProof},
		{name: "large limit", recipient: recipient, limit: "101", at: fmt.Sprint(now), proof: validProof},
		{name: "missing timestamp", recipient: recipient, limit: "20", proof: validProof},
		{name: "stale timestamp", recipient: recipient, limit: "20", at: fmt.Sprint(now - 301), proof: validProof},
		{name: "future timestamp", recipient: recipient, limit: "20", at: fmt.Sprint(now + 301), proof: validProof},
		{name: "malformed recipient", recipient: "%25%25%25", limit: "20", at: fmt.Sprint(now), proof: validProof},
		{name: "padded recipient", recipient: recipient + "=", limit: "20", at: fmt.Sprint(now), proof: validProof},
		{name: "short recipient", recipient: "BA", limit: "20", at: fmt.Sprint(now), proof: validProof},
		{name: "wrong recipient prefix", recipient: wrongPrefix, limit: "20", at: fmt.Sprint(now), proof: validProof},
		{name: "off curve recipient", recipient: offCurve, limit: "20", at: fmt.Sprint(now), proof: validProof},
		{name: "missing proof", recipient: recipient, limit: "20", at: fmt.Sprint(now)},
		{name: "malformed proof", recipient: recipient, limit: "20", at: fmt.Sprint(now), proof: "%%%"},
		{name: "padded proof", recipient: recipient, limit: "20", at: fmt.Sprint(now), proof: validProof + "="},
		{name: "short proof", recipient: recipient, limit: "20", at: fmt.Sprint(now), proof: "AA"},
		{name: "wrong proof", recipient: recipient, limit: "20", at: fmt.Sprint(now), proof: base64.RawURLEncoding.EncodeToString(make([]byte, sha256.Size))},
		{name: "wrong recipient binding", recipient: wrongRecipient, limit: "20", at: fmt.Sprint(now), proof: validProof},
		{name: "wrong limit binding", recipient: recipient, limit: "10", at: fmt.Sprint(now), proof: validProof},
		{name: "wrong timestamp binding", recipient: recipient, limit: "20", at: fmt.Sprint(now + 1), proof: validProof},
		{name: "wrong method binding", recipient: recipient, limit: "20", at: fmt.Sprint(now), proof: wrongMethodProof},
		{name: "wrong path binding", recipient: recipient, limit: "20", at: fmt.Sprint(now), proof: wrongPathProof},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			target := "/api/addresses/" + test.recipient + "/inbox?limit=" + test.limit + "&at=" + test.at
			recorder := request(t, api.handler, http.MethodGet, target, "", map[string]string{inboxProofHeader: test.proof})
			assertError(t, recorder, http.StatusUnauthorized, "unauthorized")
		})
	}
}

func TestInboxAcceptsLimitBoundaries(t *testing.T) {
	api := newTestAPI(t)
	recipientPrivate, recipient := p256Key(t)
	for _, limit := range []int{1, 100} {
		at := time.Now().Unix()
		proof := inboxProof(t, api, recipientPrivate, recipient, limit, at)
		recorder := inboxRequest(t, api, recipient, limit, at, proof)
		if recorder.Code != http.StatusOK {
			t.Fatalf("limit %d status = %d, body = %s", limit, recorder.Code, recorder.Body.String())
		}
	}
}

func TestCLIRouteStoreFailures(t *testing.T) {
	_, recipient := p256Key(t)
	_, ephemeral := p256Key(t)
	tests := []struct {
		name    string
		method  string
		target  string
		body    string
		message string
	}{
		{name: "create", method: http.MethodPost, target: "/api/secrets", body: createPayload(t, recipient, ephemeral, 3600, 1), message: "could not store secret"},
		{name: "metadata", method: http.MethodGet, target: "/api/secrets/id/metadata", message: "lookup failed"},
		{name: "open", method: http.MethodPost, target: "/api/secrets/id/open", message: "lookup failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			api := newTestAPI(t)
			if err := api.store.Close(); err != nil {
				t.Fatal(err)
			}
			assertError(t, request(t, api.handler, test.method, test.target, test.body, nil), http.StatusInternalServerError, test.message)
		})
	}
}

func TestCLIRoutesRejectWrongMethods(t *testing.T) {
	api := newTestAPI(t)
	tests := []struct {
		method string
		path   string
	}{
		{method: http.MethodGet, path: "/api/secrets"},
		{method: http.MethodPost, path: "/api/secrets/id/metadata"},
		{method: http.MethodGet, path: "/api/secrets/id/open"},
		{method: http.MethodPost, path: "/api/inbox-key"},
		{method: http.MethodPost, path: "/api/addresses/recipient/inbox"},
	}
	for _, test := range tests {
		recorder := request(t, api.handler, test.method, test.path, "", nil)
		if recorder.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s %s status = %d, want 405", test.method, test.path, recorder.Code)
		}
	}
}

func TestInboxStoreFailure(t *testing.T) {
	api := newTestAPI(t)
	recipientPrivate, recipient := p256Key(t)
	at := time.Now().Unix()
	proof := inboxProof(t, api, recipientPrivate, recipient, 20, at)
	if err := api.store.Close(); err != nil {
		t.Fatal(err)
	}
	assertError(t, inboxRequest(t, api, recipient, 20, at, proof), http.StatusInternalServerError, "internal server error")
}

func TestInboxListStoreFailure(t *testing.T) {
	api := newTestAPI(t)
	recipientPrivate, recipient := p256Key(t)
	at := time.Now().Unix()
	proof := inboxProof(t, api, recipientPrivate, recipient, 20, at)
	if _, err := api.store.db.Exec(`DROP TABLE secrets`); err != nil {
		t.Fatal(err)
	}
	assertError(t, inboxRequest(t, api, recipient, 20, at, proof), http.StatusInternalServerError, "internal server error")
}

func TestInboxRateLimit(t *testing.T) {
	api := newTestAPI(t)
	for attempt := 1; attempt <= 30; attempt++ {
		recorder := request(t, api.handler, http.MethodGet, "/api/addresses/invalid/inbox?limit=20&at=0", "", nil)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d status = %d, want 401", attempt, recorder.Code)
		}
	}
	otherIP := requestFrom(t, api.handler, http.MethodGet, "/api/addresses/invalid/inbox?limit=20&at=0", "", nil, "198.51.100.2:4321")
	if otherIP.Code != http.StatusUnauthorized {
		t.Fatalf("other IP status = %d, want 401", otherIP.Code)
	}
	limited := request(t, api.handler, http.MethodGet, "/api/addresses/invalid/inbox?limit=20&at=0", "", map[string]string{"X-Forwarded-For": "203.0.113.7"})
	if limited.Code != http.StatusTooManyRequests || limited.Header().Get("Retry-After") != "60" {
		t.Fatalf("rate limit response: status=%d retry=%q", limited.Code, limited.Header().Get("Retry-After"))
	}
}
