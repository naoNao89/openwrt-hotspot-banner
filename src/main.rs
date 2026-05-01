use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use tokio::time::interval;
use tracing::info;

mod firewall;
mod handlers;
mod pages;
mod state;
mod theme;

use state::AppState;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    tracing_subscriber::fmt::init();

    if env::args().any(|arg| arg == "--cleanup") {
        state::cleanup_empty_state();
        return;
    }

    let port = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8080);
    let session_minutes = env::var("SESSION_MINUTES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(60u64);
    let disconnect_grace_seconds = env::var("DISCONNECT_GRACE_SECONDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(30u64);
    let queue_retry_seconds = env::var("QUEUE_RETRY_SECONDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(300u64);
    let max_active_sessions = env::var("MAX_ACTIVE_SESSIONS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(30usize);
    let guest_iface = env::var("GUEST_IFACE").unwrap_or_else(|_| "ath01".to_string());
    let theme_dir = env::var("THEME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/etc/hotspot-banner/theme"));
    let default_theme_dir = env::var("DEFAULT_THEME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/usr/share/hotspot-banner/default-theme"));

    let state = AppState::new(
        Duration::from_secs(session_minutes * 60),
        Duration::from_secs(disconnect_grace_seconds),
        Duration::from_secs(queue_retry_seconds),
        max_active_sessions,
        guest_iface,
        theme_dir,
        default_theme_dir,
    );

    info!("Running in standalone mode (iptables-based captive portal)");
    let state_clone = state.clone();
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(30));
        loop {
            ticker.tick().await;
            state_clone.cleanup_expired_sessions();
            state_clone.cleanup_disconnected_sessions();
        }
    });
    let app = handlers::router(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    info!("Hotspot portal starting on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    .unwrap();
}
