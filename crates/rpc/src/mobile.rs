//! Mobile adapter: a bearer-token WebSocket listener that forwards a fixed
//! allowlist of methods to the engine's RPC service.
//!
//! The local IPC socket trusts anything on loopback and rejects browsers by
//! `Origin`; that is not a public transport. Phones instead dial this listener,
//! prove a shared token in the handshake, and get only the methods a remote
//! viewport needs. Everything else answers `RpcError::UnknownMethod`.

use std::sync::Arc;

use async_trait::async_trait;
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{
    ErrorResponse, Request as HandshakeRequest, Response as HandshakeResponse,
};
use tokio_tungstenite::tungstenite::http::StatusCode;

use crate::methods;
use crate::server::serve_ws_stream;
use crate::{RpcError, RpcReply, RpcService};

/// What a remote viewport may call. Grow deliberately: every entry here is
/// reachable from off-host with only the mobile token.
pub const MOBILE_METHODS: &[&str] = &[
    methods::ENGINE_INFO,
    methods::WATCH_DEVICES,
    methods::WATCH_SPACES,
    methods::WATCH_CHATS,
    methods::WATCH_SESSIONS,
    methods::WATCH_DOC_MESSAGES,
    methods::QUEUE_COMMAND,
    methods::GET_CHECKOUT_DIFF,
    methods::UPLOAD_CHUNK,
    methods::UPLOAD_COMMIT,
    methods::READ_ATTACHMENT_CHUNK,
];

struct Allowlisted(Arc<dyn RpcService>);

#[async_trait]
impl RpcService for Allowlisted {
    async fn handle(&self, method: &str, params: serde_json::Value) -> Result<RpcReply, RpcError> {
        if !MOBILE_METHODS.contains(&method) {
            return Err(RpcError::UnknownMethod(method.to_string()));
        }
        self.0.handle(method, params).await
    }
}

/// Accept authenticated mobile connections forever.
pub async fn serve_mobile_listener(
    listener: TcpListener,
    service: Arc<dyn RpcService>,
    token: Arc<str>,
) {
    let service: Arc<dyn RpcService> = Arc::new(Allowlisted(service));
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                tracing::debug!(%peer, "mobile: connection accepted");
                let token = token.clone();
                let service = service.clone();
                tokio::spawn(async move {
                    #[allow(clippy::result_large_err)]
                    let check = |req: &HandshakeRequest, resp: HandshakeResponse| {
                        if bearer_matches(req, &token) {
                            Ok(resp)
                        } else {
                            tracing::warn!(%peer, "mobile: rejecting handshake without a valid token");
                            let mut err = ErrorResponse::new(Some("unauthorized".to_string()));
                            *err.status_mut() = StatusCode::UNAUTHORIZED;
                            Err(err)
                        }
                    };
                    match tokio_tungstenite::accept_hdr_async(stream, check).await {
                        Ok(ws) => serve_ws_stream(ws, service).await,
                        Err(err) => tracing::warn!(error = %err, "mobile: handshake failed"),
                    }
                });
            }
            Err(err) => {
                tracing::warn!(error = %err, "mobile: accept failed");
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
}

fn bearer_matches(req: &HandshakeRequest, token: &str) -> bool {
    let Some(header) = req.headers().get("authorization") else {
        return false;
    };
    let Some(presented) = header.as_bytes().strip_prefix(b"Bearer ") else {
        return false;
    };
    constant_time_eq(presented, token.as_bytes())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    struct Echo;

    #[async_trait]
    impl RpcService for Echo {
        async fn handle(&self, _: &str, params: serde_json::Value) -> Result<RpcReply, RpcError> {
            Ok(RpcReply::Value(params))
        }
    }

    async fn dial(url: &str, token: Option<&str>) -> Result<String, String> {
        let mut req = url.into_client_request().unwrap();
        if let Some(token) = token {
            req.headers_mut()
                .insert("authorization", format!("Bearer {token}").parse().unwrap());
        }
        match tokio_tungstenite::connect_async(req).await {
            Ok(_) => Ok("connected".into()),
            Err(err) => Err(err.to_string()),
        }
    }

    #[tokio::test]
    async fn handshake_requires_the_token_and_dispatch_honours_the_allowlist() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(serve_mobile_listener(
            listener,
            Arc::new(Echo),
            "secret".into(),
        ));

        assert!(dial(&url, None).await.unwrap_err().contains("401"));
        assert!(dial(&url, Some("wrong")).await.unwrap_err().contains("401"));
        assert_eq!(dial(&url, Some("secret")).await.unwrap(), "connected");

        let allowed = Allowlisted(Arc::new(Echo));
        assert!(
            allowed
                .handle(methods::ENGINE_INFO, serde_json::json!({}))
                .await
                .is_ok()
        );
        assert!(matches!(
            allowed.handle(methods::MUTATE, serde_json::json!({})).await,
            Err(RpcError::UnknownMethod(_))
        ));
    }
}
