use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Clone, FromRow, Serialize)]
pub struct User {
    pub id: i64,
    pub name: String,
    pub email: String,
    pub role: String,
}

#[derive(Clone, FromRow)]
pub struct AuthUser {
    pub id: i64,
    pub email: String,
    pub role: String,
}

#[derive(Clone, FromRow, Serialize)]
pub struct EmailLog {
    pub to: String,
    pub subject: String,
    pub body: String,
    pub code: String,
    pub login_challenge_id: String,
    pub created_at: i64,
}

#[derive(Clone, FromRow, Serialize)]
pub struct Task {
    pub id: i64,
    pub title: String,
    pub description: Option<String>,
    pub priority: Option<String>,
    pub status: String,
    pub created_by_id: i64,
    pub assigned_to_id: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct VerifyTwoFactorRequest {
    pub login_challenge_id: String,
    pub code: String,
}

#[derive(Deserialize)]
pub struct CreateTaskRequest {
    pub title: String,
    pub description: Option<String>,
}

#[derive(Deserialize)]
pub struct AssignTaskRequest {
    pub task_id: i64,
    pub user_id: i64,
}
