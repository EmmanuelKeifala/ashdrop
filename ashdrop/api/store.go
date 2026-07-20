package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"database/sql"
	"errors"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Secret is the server's entire view of a drop: ciphertext + metadata.
// It never holds the key or plaintext — by design.
type Secret struct {
	Ciphertext   string
	IV           string
	MaxViews     int // 0 = unlimited
	Views        int
	ExpiresAt    int64
	CreatedAt    int64
	NotifyTok    string
	OpenedAt     *int64
	RecipientPub string // non-empty = recipient-keyed drop (ECDH); recipient's public key
	EphemeralPub string // non-empty = recipient-keyed drop (ECDH); sender's ephemeral public key
}

// InboxItem is the recipient-visible metadata for an unburned inbox entry.
type InboxItem struct {
	ID        string
	ExpiresAt int64
	ViewsLeft int
}

// Store is the persistence seam. SQLite today; swappable for Redis at scale
// without touching the handlers.
type Store struct{ db *sql.DB }

const schema = `
CREATE TABLE IF NOT EXISTS secrets (
	id            TEXT PRIMARY KEY,
	ciphertext    TEXT NOT NULL,
	iv            TEXT NOT NULL,
	max_views     INTEGER NOT NULL,
	views         INTEGER NOT NULL DEFAULT 0,
	burned        INTEGER NOT NULL DEFAULT 0,
	expires_at    INTEGER NOT NULL,
	created_at    INTEGER NOT NULL DEFAULT 0,
	notify_token  TEXT NOT NULL,
	opened_at     INTEGER,
	recipient_pub TEXT NOT NULL DEFAULT '',
	ephemeral_pub TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_secrets_expires ON secrets(expires_at);
CREATE TABLE IF NOT EXISTS inbox_keys (
	id          INTEGER PRIMARY KEY CHECK (id = 1),
	private_key BLOB NOT NULL
);
`

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	// Single writer keeps the burn transaction correct and avoids lock churn.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	// Migrate existing databases before creating an index that uses new columns.
	for _, migration := range []string{
		`ALTER TABLE secrets ADD COLUMN pin_protected INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE secrets ADD COLUMN ephemeral_pub TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE secrets ADD COLUMN recipient_pub TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE secrets ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0`,
	} {
		if _, err := db.Exec(migration); err != nil && !strings.Contains(err.Error(), "duplicate column name") {
			_ = db.Close()
			return nil, err
		}
	}
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS idx_secrets_recipient_inbox ON secrets(recipient_pub, burned, expires_at, created_at, id)`); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func now() int64 { return time.Now().Unix() }

func (s *Store) Put(id string, sec Secret) error {
	createdAt := sec.CreatedAt
	if createdAt == 0 {
		createdAt = now()
	}
	_, err := s.db.Exec(
		`INSERT INTO secrets (id, ciphertext, iv, max_views, views, burned, expires_at, created_at, notify_token, recipient_pub, ephemeral_pub)
		 VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)`,
		id, sec.Ciphertext, sec.IV, sec.MaxViews, sec.ExpiresAt, createdAt, sec.NotifyTok, sec.RecipientPub, sec.EphemeralPub,
	)
	return err
}

// InboxPrivateKey returns the canonical P-256 private scalar used to decrypt
// recipient inbox entries. Persisted key material is never replaced on error.
func (s *Store) InboxPrivateKey() ([]byte, error) {
	var stored []byte
	err := s.db.QueryRow(`SELECT private_key FROM inbox_keys WHERE id = 1`).Scan(&stored)
	if err == nil {
		key, err := ecdh.P256().NewPrivateKey(stored)
		if err != nil || !bytes.Equal(stored, key.Bytes()) {
			if err != nil {
				return nil, err
			}
			return nil, errors.New("invalid inbox private key")
		}
		return append([]byte(nil), stored...), nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	var privateKey []byte
	for {
		candidate := make([]byte, 32)
		if _, err := rand.Read(candidate); err != nil {
			return nil, err
		}
		key, err := ecdh.P256().NewPrivateKey(candidate)
		if err == nil {
			privateKey = key.Bytes()
			break
		}
	}

	result, err := s.db.Exec(`INSERT OR IGNORE INTO inbox_keys (id, private_key) VALUES (1, ?)`, privateKey)
	if err != nil {
		return nil, err
	}
	if rows, err := result.RowsAffected(); err != nil {
		return nil, err
	} else if rows == 1 {
		return append([]byte(nil), privateKey...), nil
	}

	// Another store created the key after the initial lookup; validate it rather
	// than replacing it so corruption remains observable.
	if err := s.db.QueryRow(`SELECT private_key FROM inbox_keys WHERE id = 1`).Scan(&stored); err != nil {
		return nil, err
	}
	key, err := ecdh.P256().NewPrivateKey(stored)
	if err != nil || !bytes.Equal(stored, key.Bytes()) {
		if err != nil {
			return nil, err
		}
		return nil, errors.New("invalid inbox private key")
	}
	return append([]byte(nil), stored...), nil
}

// ListInbox returns recipient-visible metadata for active recipient-keyed drops.
func (s *Store) ListInbox(recipientPub string, limit int) ([]InboxItem, error) {
	if limit <= 0 {
		return []InboxItem{}, nil
	}
	rows, err := s.db.Query(
		`SELECT id, expires_at, CASE WHEN max_views = 0 THEN -1 ELSE max_views - views END
		 FROM secrets
		 WHERE recipient_pub = ? AND burned = 0 AND expires_at > ?
		 ORDER BY created_at ASC, id ASC
		 LIMIT ?`,
		recipientPub, now(), limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck

	var inbox []InboxItem
	for rows.Next() {
		var item InboxItem
		if err := rows.Scan(&item.ID, &item.ExpiresAt, &item.ViewsLeft); err != nil {
			return nil, err
		}
		inbox = append(inbox, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return inbox, nil
}

// Metadata returns public drop state without reading the encrypted payload.
// Expired rows are reaped lazily. Returns (nil, nil) for a missing or burned drop.
func (s *Store) Metadata(id string) (*Secret, error) {
	var sec Secret
	var openedAt sql.NullInt64
	var burned int
	row := s.db.QueryRow(
		`SELECT max_views, views, burned, expires_at, created_at, opened_at, recipient_pub, ephemeral_pub
		 FROM secrets WHERE id = ?`, id)
	err := row.Scan(&sec.MaxViews, &sec.Views, &burned, &sec.ExpiresAt, &sec.CreatedAt, &openedAt, &sec.RecipientPub, &sec.EphemeralPub)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if sec.ExpiresAt <= now() {
		_, _ = s.db.Exec(`DELETE FROM secrets WHERE id = ?`, id)
		return nil, nil
	}
	if burned == 1 {
		return nil, nil
	}
	if openedAt.Valid {
		v := openedAt.Int64
		sec.OpenedAt = &v
	}
	return &sec, nil
}

// Open atomically retrieves and records a view. A final permitted view returns
// its captured payload while burning and wiping the stored payload before commit.
func (s *Store) Open(id string) (*Secret, error) {
	tx, err := s.db.BeginTx(context.Background(), nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() //nolint:errcheck

	var sec Secret
	var openedAt int64
	current := now()
	row := tx.QueryRow(
		`UPDATE secrets
		 SET views = views + 1, opened_at = COALESCE(opened_at, ?)
		 WHERE id = ? AND burned = 0 AND expires_at > ? AND (max_views = 0 OR views < max_views)
		 RETURNING ciphertext, iv, max_views, views, expires_at, created_at, opened_at, ephemeral_pub`,
		current, id, current)
	err = row.Scan(&sec.Ciphertext, &sec.IV, &sec.MaxViews, &sec.Views, &sec.ExpiresAt, &sec.CreatedAt, &openedAt, &sec.EphemeralPub)
	if errors.Is(err, sql.ErrNoRows) {
		if _, err := tx.Exec(`DELETE FROM secrets WHERE id = ? AND expires_at <= ?`, id, current); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sec.OpenedAt = &openedAt

	if sec.MaxViews > 0 && sec.Views >= sec.MaxViews {
		_, err = tx.Exec(
			`UPDATE secrets SET burned = 1, ciphertext = '', iv = '' WHERE id = ?`,
			id,
		)
		if err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &sec, nil
}

// Fetch returns the secret only if it's still retrievable (exists, unexpired,
// not yet burned). Expired rows are reaped lazily. Returns (nil, nil) for "gone".
func (s *Store) Fetch(id string) (*Secret, error) {
	var sec Secret
	var openedAt sql.NullInt64
	var burned int
	row := s.db.QueryRow(
		`SELECT ciphertext, iv, max_views, views, burned, expires_at, created_at, notify_token, opened_at, recipient_pub, ephemeral_pub
		 FROM secrets WHERE id = ?`, id)
	err := row.Scan(&sec.Ciphertext, &sec.IV, &sec.MaxViews, &sec.Views, &burned, &sec.ExpiresAt, &sec.CreatedAt, &sec.NotifyTok, &openedAt, &sec.RecipientPub, &sec.EphemeralPub)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if sec.ExpiresAt <= now() {
		_, _ = s.db.Exec(`DELETE FROM secrets WHERE id = ?`, id)
		return nil, nil
	}
	if burned == 1 {
		return nil, nil
	}
	if sec.RecipientPub != "" {
		return nil, nil
	}
	if openedAt.Valid {
		v := openedAt.Int64
		sec.OpenedAt = &v
	}
	return &sec, nil
}

// Burn atomically records a view and, once the view limit is hit, burns the
// secret: marks it burned and wipes the ciphertext. Idempotent. The row lingers
// (sans ciphertext) until TTL so the sender's "opened?" poll still works.
func (s *Store) Burn(id string) error {
	tx, err := s.db.BeginTx(context.Background(), nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	var maxViews, views, burned int
	var expiresAt int64
	var openedAt sql.NullInt64
	row := tx.QueryRow(`SELECT max_views, views, burned, expires_at, opened_at FROM secrets WHERE id = ?`, id)
	if err := row.Scan(&maxViews, &views, &burned, &expiresAt, &openedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil // already gone — burn is idempotent
		}
		return err
	}
	if burned == 1 || expiresAt <= now() {
		return nil
	}

	views++
	if !openedAt.Valid {
		openedAt = sql.NullInt64{Int64: now(), Valid: true}
	}

	if maxViews > 0 && views >= maxViews {
		_, err = tx.Exec(`UPDATE secrets SET views = ?, burned = 1, ciphertext = '', iv = '', opened_at = ? WHERE id = ?`,
			views, openedAt.Int64, id)
	} else {
		_, err = tx.Exec(`UPDATE secrets SET views = ?, opened_at = ? WHERE id = ?`,
			views, openedAt.Int64, id)
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

// Status reports whether a drop was opened, for the sender's notify token.
func (s *Store) Status(id string) (notifyTok string, opened bool, openedAt *int64, found bool, err error) {
	var oa sql.NullInt64
	var expiresAt int64
	row := s.db.QueryRow(`SELECT notify_token, opened_at, expires_at FROM secrets WHERE id = ?`, id)
	e := row.Scan(&notifyTok, &oa, &expiresAt)
	if errors.Is(e, sql.ErrNoRows) {
		return "", false, nil, false, nil
	}
	if e != nil {
		return "", false, nil, false, e
	}
	if expiresAt <= now() {
		return "", false, nil, false, nil
	}
	if oa.Valid {
		v := oa.Int64
		return notifyTok, true, &v, true, nil
	}
	return notifyTok, false, nil, true, nil
}

func (s *Store) Delete(id string) error {
	_, err := s.db.Exec(`DELETE FROM secrets WHERE id = ?`, id)
	return err
}

func (s *Store) Cleanup() (int64, error) {
	r, err := s.db.Exec(`DELETE FROM secrets WHERE expires_at <= ?`, now())
	if err != nil {
		return 0, err
	}
	n, _ := r.RowsAffected()
	return n, nil
}
