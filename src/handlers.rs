use std::net::SocketAddr;

use axum::{
    extract::{ConnectInfo, State},
    http::{header, StatusCode, Uri},
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
};
use tracing::info;

use crate::firewall;
use crate::pages::{build_banner_page, build_queue_page, CLOSE_PAGE, SUCCESS_PAGE};
use crate::state::AppState;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(root_handler))
        .route("/generate_204", get(captive_probe_handler))
        .route("/gen_204", get(captive_probe_handler))
        .route("/hotspot-detect.html", get(captive_probe_handler))
        .route("/library/test/success.html", get(captive_probe_handler))
        .route("/ncsi.txt", get(captive_probe_handler))
        .route("/connecttest.txt", get(captive_probe_handler))
        .route("/redirect", get(captive_probe_handler))
        .route("/accept", get(accept_handler))
        .route("/health", get(health_handler))
        .with_state(state)
}

async fn root_handler(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> Response {
    let client_ip = addr.ip().to_string();

    if state.is_authenticated(&client_ip) {
        info!("Already authenticated (root): {}", client_ip);
        return Html(SUCCESS_PAGE).into_response();
    }

    if state.is_queue_full_for(&client_ip) {
        info!("Queued client (root): {}", client_ip);
        return Html(build_queue_page(
            state.queue_retry_seconds(),
            state.active_session_count(),
            state.max_active_sessions(),
        ))
        .into_response();
    }

    info!("Unauthenticated client (root): {}", client_ip);
    Html(build_banner_page("FreeWiFi", "/accept", None, None)).into_response()
}

async fn captive_probe_handler(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    uri: Uri,
) -> Response {
    let client_ip = addr.ip().to_string();
    let path = uri.path();

    if state.is_authenticated(&client_ip) {
        info!("Authenticated probe: {} {}", client_ip, path);
        return os_success_response(path);
    }

    if state.is_queue_full_for(&client_ip) {
        info!("Queued probe: {} {}", client_ip, path);
        return Html(build_queue_page(
            state.queue_retry_seconds(),
            state.active_session_count(),
            state.max_active_sessions(),
        ))
        .into_response();
    }

    info!("Unauthenticated probe: {} {}", client_ip, path);
    Html(build_banner_page("FreeWiFi", "/accept", None, None)).into_response()
}

fn os_success_response(path: &str) -> Response {
    match path {
        "/generate_204" | "/gen_204" => (StatusCode::NO_CONTENT, "").into_response(),
        "/hotspot-detect.html" | "/library/test/success.html" => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/html")],
            "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>",
        )
            .into_response(),
        "/ncsi.txt" => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/plain")],
            "Microsoft NCSI",
        )
            .into_response(),
        "/connecttest.txt" => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/plain")],
            "Microsoft Connect Test",
        )
            .into_response(),
        _ => (StatusCode::NO_CONTENT, "").into_response(),
    }
}

async fn accept_handler(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
) -> Response {
    let client_ip = addr.ip().to_string();
    let client_mac = firewall::mac_for_ip(&client_ip);

    if !state.authenticate(&client_ip, client_mac.clone()) {
        info!("Client queued: {} {:?}", client_ip, client_mac);
        return Html(build_queue_page(
            state.queue_retry_seconds(),
            state.active_session_count(),
            state.max_active_sessions(),
        ))
        .into_response();
    }

    firewall::add_iptables_accept(&client_ip, client_mac.as_deref());
    info!("Client authenticated: {} {:?}", client_ip, client_mac);
    Html(CLOSE_PAGE).into_response()
}

async fn health_handler() -> &'static str {
    "ok"
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::time::Duration;

    use axum::body::{to_bytes, Body};
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    use super::router;
    use crate::state::AppState;

    fn test_state(max_active_sessions: usize) -> AppState {
        AppState::new(
            Duration::from_secs(3600),
            Duration::from_secs(30),
            Duration::from_secs(300),
            max_active_sessions,
            "ath01".to_string(),
        )
    }

    fn connect_info(ip: [u8; 4]) -> SocketAddr {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip)), 49152)
    }

    async fn get_body(app: axum::Router, path: &str, client_ip: [u8; 4]) -> (StatusCode, String) {
        let response = app
            .oneshot(
                Request::builder()
                    .uri(path)
                    .extension(axum::extract::ConnectInfo(connect_info(client_ip)))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (status, String::from_utf8(body.to_vec()).unwrap())
    }

    #[tokio::test]
    async fn integration_root_shows_queue_when_capacity_is_full() {
        let state = test_state(1);
        assert!(state.authenticate("192.168.28.10", None));
        let app = router(state);

        let (status, body) = get_body(app, "/", [192, 168, 28, 11]).await;

        assert_eq!(status, StatusCode::OK);
        assert!(body.contains("FreeWiFi is full"));
        assert!(body.contains("Active sessions: 1 / 1"));
        assert!(body.contains(r#"<meta http-equiv="refresh" content="300">"#));
    }

    #[tokio::test]
    async fn integration_captive_probe_shows_queue_when_capacity_is_full() {
        let state = test_state(1);
        assert!(state.authenticate("192.168.28.10", None));
        let app = router(state);

        let (status, body) = get_body(app, "/generate_204", [192, 168, 28, 11]).await;

        assert_eq!(status, StatusCode::OK);
        assert!(body.contains("FreeWiFi is full"));
        assert!(body.contains("Active sessions: 1 / 1"));
    }

    #[tokio::test]
    async fn integration_authenticated_probe_returns_os_success() {
        let state = test_state(1);
        assert!(state.authenticate("192.168.28.10", None));
        let app = router(state);

        let (status, body) = get_body(app, "/generate_204", [192, 168, 28, 10]).await;

        assert_eq!(status, StatusCode::NO_CONTENT);
        assert!(body.is_empty());
    }

    #[tokio::test]
    async fn integration_unauthenticated_root_shows_connect_page_when_not_full() {
        let state = test_state(1);
        let app = router(state);

        let (status, body) = get_body(app, "/", [192, 168, 28, 10]).await;

        assert_eq!(status, StatusCode::OK);
        assert!(body.contains("Connect & Start Internet"));
        assert!(!body.contains("FreeWiFi is full"));
    }
}
