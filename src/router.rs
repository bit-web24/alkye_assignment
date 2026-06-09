use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    Json, Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};

use crate::{
    entities::{
        AssignTaskRequest, CreateTaskRequest, EmailLog, LoginRequest, Task, User,
        VerifyTwoFactorRequest,
    },
    postgres::DbPool,
    repository::Repository,
};

type ApiResult<T> = Result<(StatusCode, Json<T>), ApiError>;

#[derive(Clone)]
struct AppState {
    pg_pool: DbPool,
    sequence: Arc<AtomicU64>,
    jwt_secret: Arc<str>,
}

#[derive(Serialize)]
struct LoginResponse {
    message: &'static str,
    requires_2fa: bool,
    login_challenge_id: String,
}

#[derive(Serialize)]
struct VerifyTwoFactorResponse {
    token: String,
    token_type: &'static str,
}

#[derive(Clone, Deserialize, Serialize)]
struct Claims {
    sub: i64,
    email: String,
    role: String,
    exp: usize,
}

#[derive(Serialize)]
struct SeedUsersResponse {
    message: &'static str,
    users: Vec<User>,
    development_credentials: Vec<DevelopmentCredential>,
}

#[derive(Serialize)]
struct DevelopmentCredential {
    email: &'static str,
    password: &'static str,
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn database(error: sqlx::Error) -> Self {
        eprintln!("database error: {error}");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "database operation failed",
        )
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({ "error": self.message })),
        )
            .into_response()
    }
}

pub fn app(pg_pool: DbPool) -> Router {
    let jwt_secret = std::env::var("JWT_SECRET").expect("JWT_SECRET must be set");
    let state = AppState {
        pg_pool,
        sequence: Arc::new(AtomicU64::new(1)),
        jwt_secret: Arc::from(jwt_secret),
    };

    Router::new()
        .route("/seed/users", post(seed_users))
        .route("/auth/login", post(login))
        .route("/dev/email-logs/latest", get(latest_email_log))
        .route("/auth/verify-2fa", post(verify_two_factor))
        .route("/tasks", post(create_task))
        .route("/tasks/assign", post(assign_task))
        .route("/tasks/view-my-tasks", get(view_my_tasks))
        .with_state(state)
}

async fn seed_users(State(state): State<AppState>) -> ApiResult<SeedUsersResponse> {
    let users = Repository::seed_users(&state.pg_pool)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(|| ApiError::new(StatusCode::CONFLICT, "users have already been seeded"))?;

    Ok((
        StatusCode::CREATED,
        Json(SeedUsersResponse {
            message: "users seeded",
            users,
            development_credentials: vec![
                DevelopmentCredential {
                    email: "admin@example.com",
                    password: "admin123",
                },
                DevelopmentCredential {
                    email: "user@example.com",
                    password: "jamesbond123",
                },
            ],
        }),
    ))
}

async fn login(
    State(state): State<AppState>,
    Json(payload): Json<LoginRequest>,
) -> ApiResult<LoginResponse> {
    let email = payload.email.trim().to_ascii_lowercase();
    let user = Repository::find_user_by_credentials(&state.pg_pool, &email, &payload.password)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, "invalid email or password"))?;

    let code = format!(
        "{:06}",
        state.sequence.fetch_add(1, Ordering::Relaxed) % 1_000_000
    );
    let login_challenge_id = unique_value("challenge", &state.sequence);
    Repository::create_two_factor_challenge(
        &state.pg_pool,
        user.id,
        &email,
        &login_challenge_id,
        &code,
    )
    .await
    .map_err(ApiError::database)?;

    Ok((
        StatusCode::OK,
        Json(LoginResponse {
            message: "verification code sent",
            requires_2fa: true,
            login_challenge_id,
        }),
    ))
}

async fn latest_email_log(State(state): State<AppState>) -> ApiResult<EmailLog> {
    let email_log = Repository::latest_email_log(&state.pg_pool)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "no development email logs found"))?;

    Ok((StatusCode::OK, Json(email_log)))
}

async fn verify_two_factor(
    State(state): State<AppState>,
    Json(payload): Json<VerifyTwoFactorRequest>,
) -> ApiResult<VerifyTwoFactorResponse> {
    let user = Repository::verify_two_factor(
        &state.pg_pool,
        payload.login_challenge_id.trim(),
        payload.code.trim(),
    )
    .await
    .map_err(ApiError::database)?
    .ok_or_else(|| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid or expired verification code",
        )
    })?;
    let token = create_jwt(&state, &user)?;
    Repository::create_session(&state.pg_pool, user.id, &token)
        .await
        .map_err(ApiError::database)?;

    Ok((
        StatusCode::OK,
        Json(VerifyTwoFactorResponse {
            token,
            token_type: "Bearer",
        }),
    ))
}

async fn create_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateTaskRequest>,
) -> ApiResult<Task> {
    let user = authenticate(&state, &headers).await?;
    if user.role != "admin" {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "only admins can create tasks",
        ));
    }
    let title = payload.title.trim();
    if title.is_empty() {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "title is required"));
    }

    let description = payload
        .description
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let task = Repository::create_task(&state.pg_pool, title, description, user.id)
        .await
        .map_err(ApiError::database)?;

    Ok((StatusCode::CREATED, Json(task)))
}

async fn assign_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<AssignTaskRequest>,
) -> ApiResult<Task> {
    let current_user = authenticate(&state, &headers).await?;
    if current_user.role != "admin" {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "only admins can assign tasks",
        ));
    }

    if !Repository::user_exists(&state.pg_pool, payload.user_id as i64)
        .await
        .map_err(ApiError::database)?
    {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "assignee not found"));
    }

    let existing_task = Repository::find_task(&state.pg_pool, payload.task_id)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "task not found"))?;
    if existing_task.created_by_id != current_user.id {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "only the task creator can assign this task",
        ));
    }

    let task = Repository::assign_task(
        &state.pg_pool,
        payload.task_id,
        payload.user_id,
        current_user.id,
    )
    .await
    .map_err(ApiError::database)?
    .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "task not found"))?;

    Ok((StatusCode::OK, Json(task)))
}

async fn view_my_tasks(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Vec<Task>> {
    let user = authenticate(&state, &headers).await?;
    let tasks = Repository::tasks_assigned_to(&state.pg_pool, user.id)
        .await
        .map_err(ApiError::database)?;

    Ok((StatusCode::OK, Json(tasks)))
}

async fn authenticate(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<crate::entities::AuthUser, ApiError> {
    let token = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, "bearer token is required"))?;

    let claims = decode::<Claims>(
        token,
        &DecodingKey::from_secret(state.jwt_secret.as_bytes()),
        &Validation::default(),
    )
    .map_err(|_| ApiError::new(StatusCode::UNAUTHORIZED, "invalid bearer token"))?
    .claims;

    let user = Repository::find_user_by_token(&state.pg_pool, token)
        .await
        .map_err(ApiError::database)?
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, "invalid bearer token"))?;
    if claims.sub != user.id || claims.email != user.email || claims.role != user.role {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid bearer token",
        ));
    }

    Ok(user)
}

fn create_jwt(state: &AppState, user: &crate::entities::AuthUser) -> Result<String, ApiError> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as usize;
    let claims = Claims {
        sub: user.id,
        email: user.email.clone(),
        role: user.role.clone(),
        exp: now + 24 * 60 * 60,
    };

    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(state.jwt_secret.as_bytes()),
    )
    .map_err(|error| {
        eprintln!("JWT creation error: {error}");
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "token creation failed")
    })
}

fn unique_value(prefix: &str, sequence: &AtomicU64) -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = sequence.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}-{timestamp:x}-{sequence:x}")
}
