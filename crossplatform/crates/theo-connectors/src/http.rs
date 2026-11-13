//! The HTTP agents. An address on this computer is reached directly; anything else goes through the system's proxy
//! settings (`HTTPS_PROXY` and friends) when there are any.

use std::sync::OnceLock;
use std::time::Duration;

fn build_agent(use_proxy_from_environment: bool) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(20))
        .try_proxy_from_env(use_proxy_from_environment)
        .user_agent(concat!("theo-connectors/", env!("CARGO_PKG_VERSION")))
        .build()
}

pub fn is_loopback_address(address: &str) -> bool {
    url::Url::parse(address)
        .ok()
        .and_then(|parsed| parsed.host_str().map(str::to_string))
        .map(|host| matches!(host.as_str(), "127.0.0.1" | "localhost" | "[::1]" | "::1"))
        .unwrap_or(false)
}

pub fn agent_for(address: &str) -> &'static ureq::Agent {
    static DIRECT_AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    static PROXIED_AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    if is_loopback_address(address) {
        DIRECT_AGENT.get_or_init(|| build_agent(false))
    } else {
        PROXIED_AGENT.get_or_init(|| build_agent(true))
    }
}
