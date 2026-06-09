mod entities;
mod postgres;
mod repository;
mod router;

use router::app;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();
    let database_url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let pg_pool = postgres::create_pool(&database_url)
        .await
        .expect("failed to connect to PostgreSQL");

    let listener = TcpListener::bind("127.0.0.1:8000")
        .await
        .expect("failed to bind server");

    println!("server listening on http://127.0.0.1:8000");
    axum::serve(listener, app(pg_pool))
        .await
        .expect("server failed");
}
