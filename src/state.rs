use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tracing::info;

use crate::firewall;

#[derive(Debug, Clone)]
pub struct Session {
    authenticated_at: Instant,
    mac: Option<String>,
    missing_since: Option<Instant>,
}

#[derive(Debug, Clone)]
pub struct AppState {
    sessions: Arc<Mutex<HashMap<String, Session>>>,
    missing_auth_rules: Arc<Mutex<HashMap<String, Instant>>>,
    session_duration: Duration,
    disconnect_grace: Duration,
    queue_retry: Duration,
    max_active_sessions: usize,
    guest_iface: String,
}

impl AppState {
    pub fn new(
        session_duration: Duration,
        disconnect_grace: Duration,
        queue_retry: Duration,
        max_active_sessions: usize,
        guest_iface: String,
    ) -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            missing_auth_rules: Arc::new(Mutex::new(HashMap::new())),
            session_duration,
            disconnect_grace,
            queue_retry,
            max_active_sessions,
            guest_iface,
        }
    }

    pub fn authenticate(&self, client_ip: &str, mac: Option<String>) -> bool {
        if self.is_queue_full_for(client_ip) {
            return false;
        }

        let mut sessions = self.sessions.lock().unwrap();
        sessions.insert(
            client_ip.to_string(),
            Session {
                authenticated_at: Instant::now(),
                mac,
                missing_since: None,
            },
        );
        drop(sessions);
        self.enforce_session_limit();
        true
    }

    pub fn is_authenticated(&self, client_ip: &str) -> bool {
        let sessions = self.sessions.lock().unwrap();
        if let Some(session) = sessions.get(client_ip) {
            if Instant::now().duration_since(session.authenticated_at) < self.session_duration {
                return true;
            }
        }
        false
    }

    pub fn queue_retry_seconds(&self) -> u64 {
        self.queue_retry.as_secs()
    }

    pub fn active_session_count(&self) -> usize {
        let now = Instant::now();
        self.sessions
            .lock()
            .unwrap()
            .values()
            .filter(|session| now.duration_since(session.authenticated_at) < self.session_duration)
            .count()
    }

    pub fn max_active_sessions(&self) -> usize {
        self.max_active_sessions
    }

    pub fn is_queue_full_for(&self, client_ip: &str) -> bool {
        if self.max_active_sessions == 0 || self.is_authenticated(client_ip) {
            return false;
        }

        self.active_session_count() >= self.max_active_sessions
    }

    pub fn cleanup_expired_sessions(&self) {
        let now = Instant::now();
        let mut sessions = self.sessions.lock().unwrap();
        let to_remove: Vec<String> = sessions
            .iter()
            .filter(|(_, s)| now.duration_since(s.authenticated_at) > self.session_duration)
            .map(|(ip, _)| ip.clone())
            .collect();
        for ip in to_remove {
            if let Some(session) = sessions.remove(&ip) {
                firewall::remove_iptables_accept(&ip, session.mac.as_deref());
            }
            info!("Expired session removed: {}", ip);
        }
    }

    pub fn enforce_session_limit(&self) {
        if self.max_active_sessions == 0 {
            return;
        }

        let mut sessions = self.sessions.lock().unwrap();
        if sessions.len() <= self.max_active_sessions {
            return;
        }

        let mut ordered_sessions: Vec<(String, Instant)> = sessions
            .iter()
            .map(|(ip, session)| (ip.clone(), session.authenticated_at))
            .collect();
        ordered_sessions.sort_by_key(|(_, authenticated_at)| *authenticated_at);

        let remove_count = sessions.len().saturating_sub(self.max_active_sessions);
        let to_remove: Vec<String> = ordered_sessions
            .into_iter()
            .take(remove_count)
            .map(|(ip, _)| ip)
            .collect();

        for ip in to_remove {
            if let Some(session) = sessions.remove(&ip) {
                firewall::remove_iptables_accept(&ip, session.mac.as_deref());
                info!("Queue limit removed oldest session: {}", ip);
            }
        }
    }

    pub fn cleanup_disconnected_sessions(&self) {
        let Some(mut active_macs) = firewall::associated_macs(&self.guest_iface) else {
            return;
        };
        active_macs.extend(firewall::arp_macs_for_device("br-guest"));

        let now = Instant::now();
        let mut missing_auth_rules = self.missing_auth_rules.lock().unwrap();
        let tracked_ips: HashSet<String> = self.sessions.lock().unwrap().keys().cloned().collect();

        for (ip, mac) in firewall::authenticated_clients() {
            if tracked_ips.contains(&ip) {
                continue;
            }

            let Some(mac) = mac else {
                continue;
            };
            let key = format!("{ip}|{mac}");

            if active_macs.contains(&mac) {
                missing_auth_rules.remove(&key);
                continue;
            }

            let missing_since = missing_auth_rules.entry(key.clone()).or_insert(now);
            if now.duration_since(*missing_since) >= self.disconnect_grace {
                firewall::remove_iptables_accept(&ip, Some(&mac));
                missing_auth_rules.remove(&key);
                info!("Disconnected firewall rule removed: {}", ip);
            }
        }
        drop(missing_auth_rules);

        let mut sessions = self.sessions.lock().unwrap();
        let mut to_remove = Vec::new();

        for (ip, session) in sessions.iter_mut() {
            let Some(mac) = session.mac.as_deref() else {
                continue;
            };

            if active_macs.contains(mac) {
                session.missing_since = None;
                continue;
            }

            let missing_since = session.missing_since.get_or_insert(now);
            if now.duration_since(*missing_since) >= self.disconnect_grace {
                to_remove.push(ip.clone());
            }
        }

        for ip in to_remove {
            if let Some(session) = sessions.remove(&ip) {
                firewall::remove_iptables_accept(&ip, session.mac.as_deref());
                info!("Disconnected session removed: {}", ip);
            }
        }
    }
}

pub fn cleanup_empty_state() {
    info!("Running cleanup mode");
    AppState::new(
        Duration::from_secs(3600),
        Duration::from_secs(30),
        Duration::from_secs(300),
        30,
        "ath01".to_string(),
    )
    .cleanup_expired_sessions();
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::AppState;

    fn test_state(max_active_sessions: usize) -> AppState {
        AppState::new(
            Duration::from_secs(3600),
            Duration::from_secs(30),
            Duration::from_secs(300),
            max_active_sessions,
            "ath01".to_string(),
        )
    }

    #[test]
    fn authenticate_accepts_until_max_active_sessions() {
        let state = test_state(2);

        assert!(state.authenticate("192.168.28.10", None));
        assert!(state.authenticate("192.168.28.11", None));

        assert_eq!(state.active_session_count(), 2);
        assert!(state.is_authenticated("192.168.28.10"));
        assert!(state.is_authenticated("192.168.28.11"));
    }

    #[test]
    fn authenticate_rejects_new_client_when_queue_is_full() {
        let state = test_state(1);

        assert!(state.authenticate("192.168.28.10", None));

        assert!(state.is_queue_full_for("192.168.28.11"));
        assert!(!state.authenticate("192.168.28.11", None));
        assert_eq!(state.active_session_count(), 1);
        assert!(!state.is_authenticated("192.168.28.11"));
    }

    #[test]
    fn authenticated_client_is_not_queued_when_limit_is_full() {
        let state = test_state(1);

        assert!(state.authenticate("192.168.28.10", None));

        assert!(!state.is_queue_full_for("192.168.28.10"));
        assert!(state.is_queue_full_for("192.168.28.11"));
    }

    #[test]
    fn zero_max_active_sessions_disables_queue_limit() {
        let state = test_state(0);

        assert!(state.authenticate("192.168.28.10", None));
        assert!(state.authenticate("192.168.28.11", None));
        assert!(state.authenticate("192.168.28.12", None));

        assert_eq!(state.active_session_count(), 3);
        assert!(!state.is_queue_full_for("192.168.28.13"));
    }

    #[test]
    fn exposes_queue_settings() {
        let state = test_state(30);

        assert_eq!(state.queue_retry_seconds(), 300);
        assert_eq!(state.max_active_sessions(), 30);
    }
}
