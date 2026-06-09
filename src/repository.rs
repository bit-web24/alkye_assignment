use sqlx::{PgPool, Postgres, Transaction};

use crate::entities::{AuthUser, EmailLog, Task, User};

pub struct Repository;

impl Repository {
    pub async fn seed_users(pool: &PgPool) -> Result<Option<Vec<User>>, sqlx::Error> {
        let mut transaction = pool.begin().await?;
        let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
            .fetch_one(&mut *transaction)
            .await?;

        if user_count > 0 {
            transaction.rollback().await?;
            return Ok(None);
        }

        sqlx::query(
            r#"
            INSERT INTO users (name, email, password_hash, role)
            VALUES
                ('Admin', 'admin@example.com', 'admin123', 'admin'),
                ('James Bond', 'user@example.com', 'jamesbond123', 'user')
            "#,
        )
        .execute(&mut *transaction)
        .await?;

        let users = fetch_all_users(&mut transaction).await?;
        transaction.commit().await?;
        Ok(Some(users))
    }

    pub async fn find_user_by_credentials(
        pool: &PgPool,
        email: &str,
        password: &str,
    ) -> Result<Option<AuthUser>, sqlx::Error> {
        sqlx::query_as::<_, AuthUser>(
            r#"
            SELECT id, email, role
            FROM users
            WHERE LOWER(email) = LOWER($1) AND password_hash = $2
            "#,
        )
        .bind(email)
        .bind(password)
        .fetch_optional(pool)
        .await
    }

    pub async fn create_two_factor_challenge(
        pool: &PgPool,
        user_id: i64,
        email: &str,
        login_challenge_id: &str,
        code: &str,
    ) -> Result<EmailLog, sqlx::Error> {
        let mut transaction = pool.begin().await?;

        sqlx::query(
            r#"
            UPDATE two_factor_codes
            SET used_at = CURRENT_TIMESTAMP
            WHERE user_id = $1 AND used_at IS NULL
            "#,
        )
        .bind(user_id)
        .execute(&mut *transaction)
        .await?;

        sqlx::query(
            r#"
            INSERT INTO two_factor_codes (user_id, login_challenge_id, code, expires_at)
            VALUES ($1, $2, $3, CURRENT_TIMESTAMP + INTERVAL '5 minutes')
            "#,
        )
        .bind(user_id)
        .bind(login_challenge_id)
        .bind(code)
        .execute(&mut *transaction)
        .await?;

        let subject = "Your two-factor authentication code";
        let body = format!("Your verification code is {code}");
        let email_log = sqlx::query_as::<_, EmailLog>(
            r#"
            INSERT INTO email_logs (
                user_id, recipient, subject, body, code, login_challenge_id
            )
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING
                recipient AS "to",
                subject,
                body,
                code,
                login_challenge_id,
                EXTRACT(EPOCH FROM created_at)::BIGINT AS created_at
            "#,
        )
        .bind(user_id)
        .bind(email)
        .bind(subject)
        .bind(body)
        .bind(code)
        .bind(login_challenge_id)
        .fetch_one(&mut *transaction)
        .await?;

        transaction.commit().await?;
        Ok(email_log)
    }

    pub async fn latest_email_log(pool: &PgPool) -> Result<Option<EmailLog>, sqlx::Error> {
        sqlx::query_as::<_, EmailLog>(
            r#"
            SELECT
                recipient AS "to",
                subject,
                body,
                code,
                login_challenge_id,
                EXTRACT(EPOCH FROM created_at)::BIGINT AS created_at
            FROM email_logs
            ORDER BY id DESC
            LIMIT 1
            "#,
        )
        .fetch_optional(pool)
        .await
    }

    pub async fn verify_two_factor(
        pool: &PgPool,
        login_challenge_id: &str,
        code: &str,
    ) -> Result<Option<AuthUser>, sqlx::Error> {
        let mut transaction = pool.begin().await?;
        let code_id = sqlx::query_scalar::<_, i64>(
            r#"
            SELECT tfc.id
            FROM two_factor_codes tfc
            WHERE tfc.login_challenge_id = $1
              AND tfc.code = $2
              AND tfc.used_at IS NULL
              AND tfc.expires_at > CURRENT_TIMESTAMP
            ORDER BY tfc.id DESC
            LIMIT 1
            FOR UPDATE OF tfc
            "#,
        )
        .bind(login_challenge_id)
        .bind(code)
        .fetch_optional(&mut *transaction)
        .await?;

        let Some(code_id) = code_id else {
            transaction.rollback().await?;
            return Ok(None);
        };

        sqlx::query("UPDATE two_factor_codes SET used_at = CURRENT_TIMESTAMP WHERE id = $1")
            .bind(code_id)
            .execute(&mut *transaction)
            .await?;

        let user = sqlx::query_as::<_, AuthUser>(
            r#"
            SELECT u.id, u.email, u.role
            FROM users u
            JOIN two_factor_codes tfc ON tfc.user_id = u.id
            WHERE tfc.id = $1
            "#,
        )
        .bind(code_id)
        .fetch_one(&mut *transaction)
        .await?;

        transaction.commit().await?;
        Ok(Some(user))
    }

    pub async fn create_session(
        pool: &PgPool,
        user_id: i64,
        token: &str,
    ) -> Result<(), sqlx::Error> {
        sqlx::query(
            r#"
            INSERT INTO sessions (user_id, token, expires_at)
            VALUES ($1, $2, CURRENT_TIMESTAMP + INTERVAL '24 hours')
            "#,
        )
        .bind(user_id)
        .bind(token)
        .execute(pool)
        .await?;
        Ok(())
    }

    pub async fn find_user_by_token(
        pool: &PgPool,
        token: &str,
    ) -> Result<Option<AuthUser>, sqlx::Error> {
        sqlx::query_as::<_, AuthUser>(
            r#"
            SELECT u.id, u.email, u.role
            FROM sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token = $1 AND s.expires_at > CURRENT_TIMESTAMP
            "#,
        )
        .bind(token)
        .fetch_optional(pool)
        .await
    }

    pub async fn create_task(
        pool: &PgPool,
        title: &str,
        description: Option<&str>,
        created_by_id: i64,
    ) -> Result<Task, sqlx::Error> {
        sqlx::query_as::<_, Task>(
            r#"
            INSERT INTO tasks (title, description, created_by_id)
            VALUES ($1, $2, $3)
            RETURNING
                id,
                title,
                description,
                priority,
                status,
                created_by_id,
                assigned_to_id,
                EXTRACT(EPOCH FROM created_at)::BIGINT AS created_at,
                EXTRACT(EPOCH FROM updated_at)::BIGINT AS updated_at
            "#,
        )
        .bind(title)
        .bind(description)
        .bind(created_by_id)
        .fetch_one(pool)
        .await
    }

    pub async fn user_exists(pool: &PgPool, user_id: i64) -> Result<bool, sqlx::Error> {
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)")
            .bind(user_id)
            .fetch_one(pool)
            .await
    }

    pub async fn find_task(pool: &PgPool, task_id: i64) -> Result<Option<Task>, sqlx::Error> {
        sqlx::query_as::<_, Task>(
            r#"
            SELECT
                id,
                title,
                description,
                priority,
                status,
                created_by_id,
                assigned_to_id,
                EXTRACT(EPOCH FROM created_at)::BIGINT AS created_at,
                EXTRACT(EPOCH FROM updated_at)::BIGINT AS updated_at
            FROM tasks
            WHERE id = $1
            "#,
        )
        .bind(task_id)
        .fetch_optional(pool)
        .await
    }

    pub async fn assign_task(
        pool: &PgPool,
        task_id: i64,
        assignee_id: i64,
        creator_id: i64,
    ) -> Result<Option<Task>, sqlx::Error> {
        sqlx::query_as::<_, Task>(
            r#"
            UPDATE tasks
            SET assigned_to_id = $2, updated_at = CURRENT_TIMESTAMP
            WHERE id = $1 AND created_by_id = $3
            RETURNING
                id,
                title,
                description,
                priority,
                status,
                created_by_id,
                assigned_to_id,
                EXTRACT(EPOCH FROM created_at)::BIGINT AS created_at,
                EXTRACT(EPOCH FROM updated_at)::BIGINT AS updated_at
            "#,
        )
        .bind(task_id)
        .bind(assignee_id)
        .bind(creator_id)
        .fetch_optional(pool)
        .await
    }

    pub async fn tasks_assigned_to(pool: &PgPool, user_id: i64) -> Result<Vec<Task>, sqlx::Error> {
        sqlx::query_as::<_, Task>(
            r#"
            SELECT
                id,
                title,
                description,
                priority,
                status,
                created_by_id,
                assigned_to_id,
                EXTRACT(EPOCH FROM created_at)::BIGINT AS created_at,
                EXTRACT(EPOCH FROM updated_at)::BIGINT AS updated_at
            FROM tasks
            WHERE assigned_to_id = $1
            ORDER BY id
            "#,
        )
        .bind(user_id)
        .fetch_all(pool)
        .await
    }
}

async fn fetch_all_users(
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Vec<User>, sqlx::Error> {
    sqlx::query_as::<_, User>(
        r#"
        SELECT id, name, email, role
        FROM users
        ORDER BY id
        "#,
    )
    .fetch_all(&mut **transaction)
    .await
}
