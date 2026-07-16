package main

import (
	"context"
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
	NotifyTok    string
	OpenedAt     *int64
	RecipientPub string // non-empty = recipient-keyed drop (ECDH); recipient's public key
	EphemeralPub string // non-empty = recipient-keyed drop (ECDH); sender's ephemeral public key
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
	notify_token  TEXT NOT NULL,
	opened_at     INTEGER,
	recipient_pub TEXT NOT NULL DEFAULT '',
	ephemeral_pub TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_secrets_expires ON secrets(expires_at);
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
	// Migrate existing databases: safe to ignore errors when columns already exist.
	_, _ = db.Exec(`ALTER TABLE secrets ADD COLUMN pin_protected INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE secrets ADD COLUMN ephemeral_pub TEXT NOT NULL DEFAULT ''`)
	_, err = db.Exec(`ALTER TABLE secrets ADD COLUMN recipient_pub TEXT NOT NULL DEFAULT ''`)
	if err != nil && !strings.Contains(err.Error(), "duplicate column name: recipient_pub") {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func now() int64 { return time.Now().Unix() }

func (s *Store) Put(id string, sec Secret) error {
	_, err := s.db.Exec(
		`INSERT INTO secrets (id, ciphertext, iv, max_views, views, burned, expires_at, notify_token, recipient_pub, ephemeral_pub)
		 VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?, ?)`,
		id, sec.Ciphertext, sec.IV, sec.MaxViews, sec.ExpiresAt, sec.NotifyTok, sec.RecipientPub, sec.EphemeralPub,
	)
	return err
}

// Metadata returns public drop state without reading the encrypted payload.
// Expired rows are reaped lazily. Returns (nil, nil) for a missing or burned drop.
func (s *Store) Metadata(id string) (*Secret, error) {
	var sec Secret
	var openedAt sql.NullInt64
	var burned int
	row := s.db.QueryRow(
		`SELECT max_views, views, burned, expires_at, opened_at, recipient_pub, ephemeral_pub
		 FROM secrets WHERE id = ?`, id)
	err := row.Scan(&sec.MaxViews, &sec.Views, &burned, &sec.ExpiresAt, &openedAt, &sec.RecipientPub, &sec.EphemeralPub)
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
	var burned int
	var openedAt sql.NullInt64
	row := tx.QueryRow(
		`SELECT ciphertext, iv, max_views, views, burned, expires_at, opened_at, ephemeral_pub
		 FROM secrets WHERE id = ?`, id)
	err = row.Scan(&sec.Ciphertext, &sec.IV, &sec.MaxViews, &sec.Views, &burned, &sec.ExpiresAt, &openedAt, &sec.EphemeralPub)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	current := now()
	if sec.ExpiresAt <= current {
		if _, err := tx.Exec(`DELETE FROM secrets WHERE id = ?`, id); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, nil
	}
	if burned == 1 || (sec.MaxViews > 0 && sec.Views >= sec.MaxViews) {
		return nil, nil
	}

	sec.Views++
	if openedAt.Valid {
		v := openedAt.Int64
		sec.OpenedAt = &v
	} else {
		sec.OpenedAt = &current
	}

	if sec.MaxViews > 0 && sec.Views >= sec.MaxViews {
		_, err = tx.Exec(
			`UPDATE secrets SET views = ?, burned = 1, ciphertext = '', iv = '', opened_at = ? WHERE id = ?`,
			sec.Views, *sec.OpenedAt, id,
		)
	} else {
		_, err = tx.Exec(
			`UPDATE secrets SET views = ?, opened_at = ? WHERE id = ?`,
			sec.Views, *sec.OpenedAt, id,
		)
	}
	if err != nil {
		return nil, err
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
		`SELECT ciphertext, iv, max_views, views, burned, expires_at, notify_token, opened_at, recipient_pub, ephemeral_pub
		 FROM secrets WHERE id = ?`, id)
	err := row.Scan(&sec.Ciphertext, &sec.IV, &sec.MaxViews, &sec.Views, &burned, &sec.ExpiresAt, &sec.NotifyTok, &openedAt, &sec.RecipientPub, &sec.EphemeralPub)
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
