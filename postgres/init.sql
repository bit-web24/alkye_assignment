BEGIN;

CREATE TABLE IF NOT EXISTS users (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(320) NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role VARCHAR(32) NOT NULL DEFAULT 'user'
        CHECK (role IN ('admin', 'user')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS two_factor_codes (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    login_challenge_id TEXT NOT NULL UNIQUE,
    code VARCHAR(6) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sessions (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS email_logs (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    recipient VARCHAR(320) NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    code VARCHAR(6) NOT NULL,
    login_challenge_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE email_logs ADD COLUMN IF NOT EXISTS code VARCHAR(6);
UPDATE email_logs SET code = '' WHERE code IS NULL;
ALTER TABLE email_logs ALTER COLUMN code SET NOT NULL;
ALTER TABLE two_factor_codes ADD COLUMN IF NOT EXISTS login_challenge_id TEXT;
UPDATE two_factor_codes
SET login_challenge_id = 'legacy-' || id
WHERE login_challenge_id IS NULL;
ALTER TABLE two_factor_codes ALTER COLUMN login_challenge_id SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_two_factor_codes_login_challenge_id
    ON two_factor_codes (login_challenge_id);
ALTER TABLE email_logs ADD COLUMN IF NOT EXISTS login_challenge_id TEXT;
UPDATE email_logs
SET login_challenge_id = 'legacy-' || id
WHERE login_challenge_id IS NULL;
ALTER TABLE email_logs ALTER COLUMN login_challenge_id SET NOT NULL;

CREATE TABLE IF NOT EXISTS tasks (
    id BIGSERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    priority VARCHAR(32),
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    created_by_id BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    assigned_to_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_two_factor_codes_user_id
    ON two_factor_codes (user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id
    ON sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_created_by_id
    ON tasks (created_by_id);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to_id
    ON tasks (assigned_to_id);

COMMIT;
