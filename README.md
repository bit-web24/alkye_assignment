# Alkye Assignment — Task Management API

A REST API built with **Rust + Axum + PostgreSQL** that implements user seeding, two-factor email authentication, JWT session management, and task assignment with role-based access control.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Rust (edition 2024) |
| Web framework | Axum 0.8 |
| Database | PostgreSQL 17 (via Docker) |
| Database driver | sqlx 0.9 (async, compile-time checked) |
| Authentication | Two-factor code + JWT (Bearer token) |
| Environment | dotenvy |

---

## Prerequisites

- [Rust](https://rustup.rs/) — stable toolchain (`rustup update stable`)
- [Docker + Docker Compose](https://docs.docker.com/compose/install/)
- `cargo` available in `PATH`

---

## Setup

### 1. Clone the repository

```bash
git clone <repo-url>
cd alkye_assignment
```

### 2. Configure environment variables

Copy the example environment file and adjust values if needed:

```bash
cp .env .env.local   # optional — .env already contains working defaults
```

The defaults in `.env` work out of the box with the Docker Compose setup:

```env
POSTGRES_USER=bittu
POSTGRES_PASSWORD=bittu
POSTGRES_DB=alkye_assignment
DATABASE_URL=postgres://bittu:bittu@localhost:5432/alkye_assignment
JWT_SECRET=local-development-secret-change-me
```

> **Note:** Change `JWT_SECRET` to a long random string in any non-local environment.

---

## Migration

The schema is applied automatically when the PostgreSQL container first starts.  
The migration file is [`postgres/init.sql`](postgres/init.sql) and is mounted into the container at `docker-entrypoint-initdb.d/`.

### Start the database

```bash
docker compose up -d
```

Wait for the healthcheck to pass (usually 5–10 seconds):

```bash
docker compose ps        # Status should show "healthy"
```

The following tables are created:

| Table | Purpose |
|---|---|
| `users` | Registered users with roles (`admin` / `user`) |
| `two_factor_codes` | Time-limited 2FA codes tied to a login challenge |
| `sessions` | JWT tokens with 24-hour expiry |
| `email_logs` | Development log of every "email" sent (2FA codes) |
| `tasks` | Tasks with title, description, priority, status, and assignment |

To reset the database and re-run the migration from scratch:

```bash
docker compose down -v   # removes the named volume
docker compose up -d
```

---

## Run

```bash
cargo run
```

The server starts on `http://127.0.0.1:8000`.

For a faster incremental build during development:

```bash
cargo build && ./target/debug/alkye_assignment
```

---

## Seed

The database starts empty. Seed it with two pre-defined users before doing anything else:

```bash
curl -s -X POST http://127.0.0.1:8000/seed/users | jq
```

**Response (201 Created):**

```json
{
  "message": "users seeded",
  "users": [
    { "id": 1, "name": "Admin",      "email": "admin@example.com", "role": "admin" },
    { "id": 2, "name": "James Bond", "email": "user@example.com",  "role": "user"  }
  ],
  "development_credentials": [
    { "email": "admin@example.com", "password": "admin123"     },
    { "email": "user@example.com",  "password": "jamesbond123" }
  ]
}
```

Calling `/seed/users` a second time returns **409 Conflict** — seeding is intentionally idempotent.

---

## Validation

Every endpoint enforces the following rules. Violations return a JSON error body with the appropriate HTTP status code.

### `POST /auth/login`

| Field | Rule |
|---|---|
| `email` | Required. Matched case-insensitively after trimming whitespace. |
| `password` | Required. Must match the stored password exactly. |

Returns **401 Unauthorized** if the credentials do not match any user.

### `POST /auth/verify-2fa`

| Field | Rule |
|---|---|
| `login_challenge_id` | Required. Must match an active, unexpired challenge. |
| `code` | Required. Must be the 6-digit code issued during login. |

- Codes expire **5 minutes** after they are issued.
- A code is single-use; it is marked `used_at` immediately on success.
- Returns **401 Unauthorized** for any invalid, expired, or already-used combination.

### `POST /tasks`

| Field | Rule |
|---|---|
| `title` | Required; non-empty after trimming. |
| `description` | Optional string. |
| Authorization | Bearer token required. Caller must have role `admin`. |

Returns **400 Bad Request** for a blank title, **401** for a missing/invalid token, **403 Forbidden** for a non-admin caller.

### `POST /tasks/assign`

| Field | Rule |
|---|---|
| `task_id` | Required. Task must exist and have been created by the calling admin. |
| `user_id` | Required. Target user must exist in the database. |
| Authorization | Bearer token required. Caller must have role `admin`. |

- Returns **404 Not Found** if the task or the target user does not exist.
- Returns **403 Forbidden** if the calling admin did not create the task.

### `GET /tasks/view-my-tasks`

| Rule |
|---|
| Bearer token required. Returns tasks assigned to the authenticated user. |

### `GET /dev/email-logs/latest`

No authentication required. Returns the most recently logged 2FA email or **404** if none exist.

---

## API Reference

All requests and responses use `Content-Type: application/json`.  
Protected endpoints require `Authorization: Bearer <token>` in the request header.

### `POST /seed/users`

Seeds the two development users. Safe to call only once.

---

### `POST /auth/login`

**Request:**
```json
{ "email": "admin@example.com", "password": "admin123" }
```

**Response (200):**
```json
{
  "message": "verification code sent",
  "requires_2fa": true,
  "login_challenge_id": "challenge-<hex-timestamp>-<hex-seq>"
}
```

---

### `GET /dev/email-logs/latest`

**Response (200):**
```json
{
  "to": "admin@example.com",
  "subject": "Your two-factor authentication code",
  "body": "Your verification code is 000001",
  "code": "000001",
  "login_challenge_id": "challenge-...",
  "created_at": 1749430800
}
```

---

### `POST /auth/verify-2fa`

**Request:**
```json
{
  "login_challenge_id": "challenge-...",
  "code": "000001"
}
```

**Response (200):**
```json
{ "token": "<jwt>", "token_type": "Bearer" }
```

---

### `POST /tasks`

**Headers:** `Authorization: Bearer <token>`

**Request:**
```json
{ "title": "Fix login bug", "description": "Investigate and resolve the login issue" }
```

**Response (201):**
```json
{
  "id": 1,
  "title": "Fix login bug",
  "description": "Investigate and resolve the login issue",
  "priority": null,
  "status": "pending",
  "created_by_id": 1,
  "assigned_to_id": null,
  "created_at": 1749430800,
  "updated_at": 1749430800
}
```

---

### `POST /tasks/assign`

**Headers:** `Authorization: Bearer <token>`

**Request:**
```json
{ "task_id": 1, "user_id": 2 }
```

**Response (200):** Returns the updated task object (same shape as above, with `assigned_to_id` populated).

---

### `GET /tasks/view-my-tasks`

**Headers:** `Authorization: Bearer <token>`

**Response (200):** Array of task objects assigned to the authenticated user.

---

## Testing

There is no automated test suite in this project. The API can be exercised manually using `curl` or any HTTP client (Postman, Bruno, Insomnia, etc.). The complete happy-path flow is:

### Step 1 — Seed users

```bash
curl -s -X POST http://127.0.0.1:8000/seed/users | jq
```

### Step 2 — Login as admin

```bash
curl -s -X POST http://127.0.0.1:8000/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"admin123"}' | jq
```

Copy the `login_challenge_id` from the response.

### Step 3 — Read the 2FA code

```bash
curl -s http://127.0.0.1:8000/dev/email-logs/latest | jq '.code, .login_challenge_id'
```

### Step 4 — Verify 2FA and obtain JWT

```bash
curl -s -X POST http://127.0.0.1:8000/auth/verify-2fa \
  -H 'Content-Type: application/json' \
  -d '{"login_challenge_id":"<challenge_id>","code":"<code>"}' | jq
```

Export the token for subsequent requests:

```bash
export TOKEN="<jwt from above>"
```

### Step 5 — Create a task (admin only)

```bash
curl -s -X POST http://127.0.0.1:8000/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Fix login bug","description":"Investigate the issue"}' | jq
```

### Step 6 — Assign the task

```bash
curl -s -X POST http://127.0.0.1:8000/tasks/assign \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"task_id":1,"user_id":2}' | jq
```

### Step 7 — View tasks as the regular user

Repeat steps 2–4 using `user@example.com` / `jamesbond123` to obtain a user token, then:

```bash
export USER_TOKEN="<jwt for james bond>"

curl -s http://127.0.0.1:8000/tasks/view-my-tasks \
  -H "Authorization: Bearer $USER_TOKEN" | jq
```

The response should contain the task assigned in step 6.

---

## Error Responses

All errors follow a consistent shape:

```json
{ "error": "<human-readable message>" }
```

| Status | Meaning |
|---|---|
| 400 Bad Request | Missing or invalid request field (e.g. blank task title) |
| 401 Unauthorized | Missing, expired, or invalid bearer token / 2FA code |
| 403 Forbidden | Authenticated but insufficient role or ownership |
| 404 Not Found | Referenced resource does not exist |
| 409 Conflict | Operation would violate a uniqueness constraint (e.g. re-seeding) |
| 500 Internal Server Error | Unexpected database or server error |
