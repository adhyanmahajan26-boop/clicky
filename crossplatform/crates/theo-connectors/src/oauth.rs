//! Signing in to a remote app: OAuth 2.1 with PKCE, as MCP's authorization section describes it.
//!
//! 1. Find the authorization server: the 401's `WWW-Authenticate: Bearer resource_metadata="…"`, else the server's
//!    `/.well-known/oauth-protected-resource`, else (older servers) the server's own origin.
//! 2. Read its metadata (`/.well-known/oauth-authorization-server`, then OpenID's), else the default `/authorize`,
//!    `/token` and `/register`.
//! 3. Get a client: the one the owner set (`oauth.clientId`), the one the hub registered before, or a new one through
//!    dynamic client registration. A server with no registration and no owner-set client can't be signed in to, and
//!    the error says so.
//! 4. Open the browser at the authorization address, with a PKCE S256 challenge, a random state and `resource`, and wait
//!    on a loopback address (`http://127.0.0.1:<port>/callback`) for the browser to come back.
//! 5. Exchange the code for tokens, keep them in the vault, and refresh them when they run out.

use base64::Engine;
use serde_json::Value;
use sha2::Digest;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

use crate::files::{FileLock, HubPaths};
use crate::model::AppEntry;
use crate::vault::{OAuthRecord, OAuthTokens, RegisteredOAuthClient, Vault};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct WwwAuthenticateChallenge {
    pub resource_metadata: Option<String>,
    pub scope: Option<String>,
    pub error: Option<String>,
}

/// Reads `Bearer resource_metadata="https://…", scope="a b", error="invalid_token"`.
pub fn parse_www_authenticate(header: &str) -> WwwAuthenticateChallenge {
    let mut challenge = WwwAuthenticateChallenge::default();
    let parameters = header.trim().strip_prefix("Bearer").or_else(|| header.trim().strip_prefix("bearer")).unwrap_or(header);
    let mut remaining = parameters.trim();
    while !remaining.is_empty() {
        let Some(equals_at) = remaining.find('=') else { break };
        let name = remaining[..equals_at].trim().trim_start_matches(',').trim().to_lowercase();
        remaining = remaining[equals_at + 1..].trim_start();
        let value;
        if let Some(after_quote) = remaining.strip_prefix('"') {
            let closing_quote_at = after_quote.find('"').unwrap_or(after_quote.len());
            value = after_quote[..closing_quote_at].to_string();
            remaining = after_quote.get(closing_quote_at + 1..).unwrap_or("");
        } else {
            let end_at = remaining.find(',').unwrap_or(remaining.len());
            value = remaining[..end_at].trim().to_string();
            remaining = &remaining[end_at..];
        }
        remaining = remaining.trim_start().trim_start_matches(',').trim_start();
        match name.as_str() {
            "resource_metadata" => challenge.resource_metadata = Some(value),
            "scope" => challenge.scope = Some(value),
            "error" => challenge.error = Some(value),
            _ => {}
        }
    }
    challenge
}

#[derive(Debug, Clone)]
pub struct AuthorizationServer {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub registration_endpoint: Option<String>,
    pub supports_pkce_s256: bool,
    /// What the protected resource says it is (sent as `resource`).
    pub resource: String,
    pub scopes_to_ask_for: Option<String>,
}

fn get_json(address: &str) -> Option<Value> {
    let response = crate::http::agent_for(address).get(address).timeout(Duration::from_secs(20)).set("Accept", "application/json").call().ok()?;
    serde_json::from_str(&response.into_string().ok()?).ok()
}

fn origin_of(address: &url::Url) -> String {
    let mut origin = format!("{}://{}", address.scheme(), address.host_str().unwrap_or(""));
    if let Some(port) = address.port() {
        origin.push_str(&format!(":{port}"));
    }
    origin
}

/// The MCP server's address as the `resource` it is known by: no fragment, no trailing slash on an empty path.
pub fn canonical_resource(server_address: &str) -> String {
    match url::Url::parse(server_address) {
        Ok(mut parsed) => {
            parsed.set_fragment(None);
            let text = parsed.to_string();
            if parsed.path() == "/" && parsed.query().is_none() {
                text.trim_end_matches('/').to_string()
            } else {
                text
            }
        }
        Err(_) => server_address.to_string(),
    }
}

pub fn discover_authorization_server(server_address: &str, challenge: &WwwAuthenticateChallenge) -> Result<AuthorizationServer, String> {
    let parsed_server_address = url::Url::parse(server_address).map_err(|_| "The app's address isn't valid.".to_string())?;
    let server_origin = origin_of(&parsed_server_address);
    let server_path = parsed_server_address.path().trim_end_matches('/').to_string();

    let mut resource_metadata_addresses = vec![];
    if let Some(address) = &challenge.resource_metadata {
        resource_metadata_addresses.push(address.clone());
    }
    if !server_path.is_empty() {
        resource_metadata_addresses.push(format!("{server_origin}/.well-known/oauth-protected-resource{server_path}"));
    }
    resource_metadata_addresses.push(format!("{server_origin}/.well-known/oauth-protected-resource"));
    let resource_metadata = resource_metadata_addresses.iter().find_map(|address| get_json(address).filter(|metadata| metadata.is_object()));

    let issuer = resource_metadata
        .as_ref()
        .and_then(|metadata| metadata.get("authorization_servers"))
        .and_then(Value::as_array)
        .and_then(|servers| servers.first())
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| server_origin.clone());
    let resource = resource_metadata
        .as_ref()
        .and_then(|metadata| metadata.get("resource"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| canonical_resource(server_address));
    let advertised_scopes = resource_metadata
        .as_ref()
        .and_then(|metadata| metadata.get("scopes_supported"))
        .and_then(Value::as_array)
        .map(|scopes| scopes.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        .filter(|scopes| !scopes.is_empty());

    let parsed_issuer = url::Url::parse(&issuer).map_err(|_| format!("The app named a sign-in server that isn't a valid address: {issuer}"))?;
    let issuer_origin = origin_of(&parsed_issuer);
    let issuer_path = parsed_issuer.path().trim_end_matches('/').to_string();
    let metadata_addresses = if issuer_path.is_empty() {
        vec![format!("{issuer_origin}/.well-known/oauth-authorization-server"), format!("{issuer_origin}/.well-known/openid-configuration")]
    } else {
        vec![
            format!("{issuer_origin}/.well-known/oauth-authorization-server{issuer_path}"),
            format!("{issuer_origin}/.well-known/openid-configuration{issuer_path}"),
            format!("{issuer_origin}{issuer_path}/.well-known/openid-configuration"),
        ]
    };
    let server_metadata = metadata_addresses.iter().find_map(|address| get_json(address).filter(|metadata| metadata.get("token_endpoint").is_some()));

    let string_field = |field: &str| server_metadata.as_ref().and_then(|metadata| metadata.get(field)).and_then(Value::as_str).map(str::to_string);
    let authorization_endpoint = string_field("authorization_endpoint").unwrap_or_else(|| format!("{issuer_origin}/authorize"));
    let token_endpoint = string_field("token_endpoint").unwrap_or_else(|| format!("{issuer_origin}/token"));
    let registration_endpoint = match &server_metadata {
        Some(_) => string_field("registration_endpoint"),
        None => Some(format!("{issuer_origin}/register")),
    };
    // OAuth 2.1 requires S256. A server that lists its methods without it is refused; one that lists none is trusted to
    // support it, as MCP's own clients do.
    let supports_pkce_s256 = match server_metadata.as_ref().and_then(|metadata| metadata.get("code_challenge_methods_supported")).and_then(Value::as_array) {
        Some(methods) => methods.iter().any(|method| method.as_str() == Some("S256")),
        None => true,
    };

    Ok(AuthorizationServer {
        issuer,
        authorization_endpoint,
        token_endpoint,
        registration_endpoint,
        supports_pkce_s256,
        resource,
        scopes_to_ask_for: challenge.scope.clone().or(advertised_scopes),
    })
}

fn random_url_safe_text(byte_count: usize) -> String {
    use rand::RngCore;
    let mut bytes = vec![0u8; byte_count];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn pkce_challenge_for(code_verifier: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(code_verifier.as_bytes()))
}

fn loopback_redirect_uri(port: u16) -> String {
    format!("http://127.0.0.1:{port}/callback")
}

fn port_of_redirect_uri(redirect_uri: &str) -> Option<u16> {
    url::Url::parse(redirect_uri).ok()?.port()
}

/// A sign-in that has started: the address to open and the loopback listener waiting for the browser.
pub struct PendingSignIn {
    pub address_to_open: String,
    listener: TcpListener,
    expected_state: String,
    code_verifier: String,
    redirect_uri: String,
    client: RegisteredOAuthClient,
    server: AuthorizationServer,
}

pub fn begin_sign_in(entry: &AppEntry, vault: &Vault, server: AuthorizationServer) -> Result<PendingSignIn, String> {
    if !server.supports_pkce_s256 {
        return Err("This app's sign-in server doesn't support PKCE (S256), which Theo needs to sign in safely.".into());
    }
    let mut secrets = vault.read(&entry.id);
    let owner_client_id = entry.oauth.as_ref().and_then(|settings| settings.client_id.clone()).filter(|client_id| !client_id.trim().is_empty());

    let (listener, client) = if let Some(client_id) = owner_client_id {
        // A client the owner registered for an installed app takes any loopback port (RFC 8252).
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| format!("Couldn't listen for the browser: {error}"))?;
        let port = listener.local_addr().map_err(|error| error.to_string())?.port();
        let client_secret = secrets.owner_client_secret.clone();
        let client = RegisteredOAuthClient {
            client_id,
            token_endpoint_auth_method: if client_secret.is_some() { "client_secret_post".into() } else { "none".into() },
            client_secret,
            redirect_uri: Some(loopback_redirect_uri(port)),
            issuer: server.issuer.clone(),
            registered_by_hub: false,
        };
        (listener, client)
    } else {
        let earlier_client = secrets
            .oauth
            .as_ref()
            .and_then(|record| record.client.clone())
            .filter(|client| client.registered_by_hub && client.issuer == server.issuer);
        // The earlier client is kept when its port is free, since most servers only accept the exact redirect address
        // a client registered with.
        let reused = earlier_client.and_then(|client| {
            let port = client.redirect_uri.as_deref().and_then(port_of_redirect_uri)?;
            let listener = TcpListener::bind(("127.0.0.1", port)).ok()?;
            Some((listener, client))
        });
        match reused {
            Some(pair) => pair,
            None => {
                let registration_endpoint = server.registration_endpoint.clone().ok_or_else(|| {
                    format!(
                        "This app's sign-in server ({}) doesn't let apps register themselves. It needs a client id from the app's developer: add it as \"oauth\": {{\"clientId\": \"…\"}} on the app.",
                        server.issuer
                    )
                })?;
                let listener = TcpListener::bind("127.0.0.1:0").map_err(|error| format!("Couldn't listen for the browser: {error}"))?;
                let port = listener.local_addr().map_err(|error| error.to_string())?.port();
                let client = register_client(&registration_endpoint, &loopback_redirect_uri(port), &server.issuer, server.scopes_to_ask_for.as_deref())?;
                let record = secrets.oauth.get_or_insert_with(OAuthRecord::default);
                record.client = Some(client.clone());
                vault.write(&entry.id, &secrets)?;
                (listener, client)
            }
        }
    };

    let redirect_uri = client.redirect_uri.clone().unwrap_or_default();
    let code_verifier = random_url_safe_text(48);
    let expected_state = random_url_safe_text(24);
    let mut address_to_open = url::Url::parse(&server.authorization_endpoint).map_err(|_| "The sign-in server's address isn't valid.".to_string())?;
    {
        let mut query = address_to_open.query_pairs_mut();
        query
            .append_pair("response_type", "code")
            .append_pair("client_id", &client.client_id)
            .append_pair("redirect_uri", &redirect_uri)
            .append_pair("code_challenge", &pkce_challenge_for(&code_verifier))
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &expected_state)
            .append_pair("resource", &server.resource);
        if let Some(scopes) = &server.scopes_to_ask_for {
            query.append_pair("scope", scopes);
        }
    }
    Ok(PendingSignIn { address_to_open: address_to_open.to_string(), listener, expected_state, code_verifier, redirect_uri, client, server })
}

fn register_client(registration_endpoint: &str, redirect_uri: &str, issuer: &str, scopes: Option<&str>) -> Result<RegisteredOAuthClient, String> {
    let mut registration = serde_json::json!({
        "client_name": "Theo",
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
        "application_type": "native",
    });
    if let Some(scopes) = scopes {
        registration["scope"] = Value::String(scopes.to_string());
    }
    let response = crate::http::agent_for(registration_endpoint)
        .post(registration_endpoint)
        .timeout(Duration::from_secs(30))
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_string(&registration.to_string());
    let body = match response {
        Ok(response) => response.into_string().map_err(|error| error.to_string())?,
        Err(ureq::Error::Status(status, response)) => {
            let detail = oauth_error_description(&response.into_string().unwrap_or_default());
            return Err(format!("The app's sign-in server wouldn't register Theo ({status}){detail}."));
        }
        Err(error) => return Err(format!("Couldn't reach the app's sign-in server: {error}")),
    };
    let answer: Value = serde_json::from_str(&body).map_err(|_| "The sign-in server's registration answer wasn't JSON.".to_string())?;
    let client_id = answer.get("client_id").and_then(Value::as_str).ok_or("The sign-in server registered Theo without a client id.")?;
    let client_secret = answer.get("client_secret").and_then(Value::as_str).map(str::to_string);
    let token_endpoint_auth_method = answer
        .get("token_endpoint_auth_method")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| if client_secret.is_some() { "client_secret_basic".into() } else { "none".into() });
    Ok(RegisteredOAuthClient {
        client_id: client_id.to_string(),
        client_secret,
        token_endpoint_auth_method,
        redirect_uri: Some(redirect_uri.to_string()),
        issuer: issuer.to_string(),
        registered_by_hub: true,
    })
}

fn oauth_error_description(body: &str) -> String {
    let Ok(answer) = serde_json::from_str::<Value>(body) else { return String::new() };
    let error = answer.get("error").and_then(Value::as_str).unwrap_or("");
    let description = answer.get("error_description").and_then(Value::as_str).unwrap_or("");
    match (error.is_empty(), description.is_empty()) {
        (true, true) => String::new(),
        (false, true) => format!(": {error}"),
        (_, false) => format!(": {}", description.chars().take(200).collect::<String>()),
    }
}

const PAGE_AFTER_SIGN_IN: &str = "<!doctype html><meta charset=utf-8><title>Theo</title><body style=\"font:16px -apple-system,Segoe UI,sans-serif;margin:4em auto;max-width:28em;text-align:center\"><h2>Signed in</h2><p>You can close this tab and go back to Theo.</p></body>";
const PAGE_AFTER_FAILED_SIGN_IN: &str = "<!doctype html><meta charset=utf-8><title>Theo</title><body style=\"font:16px -apple-system,Segoe UI,sans-serif;margin:4em auto;max-width:28em;text-align:center\"><h2>Not signed in</h2><p>Go back to Theo and try again.</p></body>";

fn answer_browser(mut connection: TcpStream, status_line: &str, page: &str) {
    let _ = write!(connection, "HTTP/1.1 {status_line}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{page}", page.len());
    let _ = connection.flush();
}

impl PendingSignIn {
    /// Waits for the browser to come back to the loopback address, then trades the code for tokens and saves them.
    pub fn finish(self, app_id: &str, vault: &Vault, wait_at_most: Duration) -> Result<(), String> {
        self.listener.set_nonblocking(true).map_err(|error| error.to_string())?;
        let deadline = Instant::now() + wait_at_most;
        let authorization_code = loop {
            if Instant::now() > deadline {
                return Err("The sign-in wasn't finished in the browser in time.".into());
            }
            let connection = match self.listener.accept() {
                Ok((connection, _)) => connection,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                }
                Err(error) => return Err(format!("The browser's answer couldn't be read: {error}")),
            };
            let _ = connection.set_nonblocking(false);
            let _ = connection.set_read_timeout(Some(Duration::from_secs(10)));
            let mut request_line = String::new();
            if BufReader::new(&connection).read_line(&mut request_line).is_err() {
                continue;
            }
            let target = request_line.split_whitespace().nth(1).unwrap_or("/").to_string();
            let Ok(callback_address) = url::Url::parse(&format!("http://127.0.0.1{target}")) else { continue };
            if callback_address.path() != "/callback" {
                // A favicon request, or anything else a browser tries on its own.
                answer_browser(connection, "404 Not Found", "");
                continue;
            }
            let query_value = |name: &str| callback_address.query_pairs().find(|(key, _)| key == name).map(|(_, value)| value.to_string());
            if query_value("state").as_deref() != Some(self.expected_state.as_str()) {
                // Not this sign-in's answer (an old tab, or someone else's request): keep waiting for the right one.
                answer_browser(connection, "400 Bad Request", PAGE_AFTER_FAILED_SIGN_IN);
                continue;
            }
            if let Some(error) = query_value("error") {
                answer_browser(connection, "200 OK", PAGE_AFTER_FAILED_SIGN_IN);
                let description = query_value("error_description").map(|text| format!(": {text}")).unwrap_or_default();
                return Err(format!("The sign-in was refused ({error}){description}."));
            }
            let Some(code) = query_value("code") else {
                answer_browser(connection, "400 Bad Request", PAGE_AFTER_FAILED_SIGN_IN);
                return Err("The browser came back without a sign-in code.".into());
            };
            answer_browser(connection, "200 OK", PAGE_AFTER_SIGN_IN);
            break code;
        };

        let mut form = vec![
            ("grant_type", "authorization_code".to_string()),
            ("code", authorization_code),
            ("redirect_uri", self.redirect_uri.clone()),
            ("code_verifier", self.code_verifier.clone()),
            ("resource", self.server.resource.clone()),
        ];
        let tokens = request_tokens(&self.server.token_endpoint, &self.client, &mut form)?;
        let mut secrets = vault.read(app_id);
        secrets.oauth = Some(OAuthRecord {
            client: Some(self.client.clone()),
            tokens: Some(tokens),
            token_endpoint: Some(self.server.token_endpoint.clone()),
            resource: Some(self.server.resource.clone()),
        });
        vault.write(app_id, &secrets)
    }
}

/// Posts to the token endpoint with the client's own authentication and reads the tokens back.
fn request_tokens(token_endpoint: &str, client: &RegisteredOAuthClient, form: &mut Vec<(&str, String)>) -> Result<OAuthTokens, String> {
    let mut request = crate::http::agent_for(token_endpoint)
        .post(token_endpoint)
        .timeout(Duration::from_secs(30))
        .set("Accept", "application/json");
    match (client.token_endpoint_auth_method.as_str(), &client.client_secret) {
        ("client_secret_basic", Some(client_secret)) => {
            let encode = |text: &str| url::form_urlencoded::byte_serialize(text.as_bytes()).collect::<String>();
            let credentials = base64::engine::general_purpose::STANDARD.encode(format!("{}:{}", encode(&client.client_id), encode(client_secret)));
            request = request.set("Authorization", &format!("Basic {credentials}"));
        }
        (_, Some(client_secret)) => {
            form.push(("client_id", client.client_id.clone()));
            form.push(("client_secret", client_secret.clone()));
        }
        (_, None) => form.push(("client_id", client.client_id.clone())),
    }
    let form_pairs: Vec<(&str, &str)> = form.iter().map(|(name, value)| (*name, value.as_str())).collect();
    let body = match request.send_form(&form_pairs) {
        Ok(response) => response.into_string().map_err(|error| error.to_string())?,
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_string().unwrap_or_default();
            let is_invalid_grant = serde_json::from_str::<Value>(&body).ok().and_then(|answer| answer.get("error").and_then(Value::as_str).map(|error| error == "invalid_grant")).unwrap_or(false);
            if is_invalid_grant {
                return Err(INVALID_GRANT.into());
            }
            return Err(format!("The sign-in server refused the token request ({status}){}.", oauth_error_description(&body)));
        }
        Err(error) => return Err(format!("Couldn't reach the sign-in server: {error}")),
    };
    let answer: Value = serde_json::from_str(&body).map_err(|_| "The sign-in server's token answer wasn't JSON.".to_string())?;
    let access_token = answer.get("access_token").and_then(Value::as_str).ok_or("The sign-in server answered without an access token.")?;
    let expires_at = answer.get("expires_in").and_then(|value| value.as_i64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))).map(|seconds| chrono::Utc::now().timestamp() + seconds);
    Ok(OAuthTokens {
        access_token: access_token.to_string(),
        refresh_token: answer.get("refresh_token").and_then(Value::as_str).map(str::to_string),
        expires_at,
        scope: answer.get("scope").and_then(Value::as_str).map(str::to_string),
    })
}

const INVALID_GRANT: &str = "The app's sign-in has expired.";

/// The outcome of asking for a token to use now.
pub enum AccessTokenOutcome {
    Usable(String),
    /// No sign-in, or one that can't be refreshed: the app needs `signin` again.
    NeedsSignIn,
}

/// A token good for at least another minute, refreshed first if it's about to run out. Only one hub process refreshes at a
/// time: with refresh tokens that rotate, two refreshing at once would sign the app out.
pub fn usable_access_token(app_id: &str, vault: &Vault, paths: &HubPaths, force_refresh: bool) -> Result<AccessTokenOutcome, String> {
    let secrets = vault.read(app_id);
    let Some(tokens) = secrets.oauth.as_ref().and_then(|record| record.tokens.clone()) else { return Ok(AccessTokenOutcome::NeedsSignIn) };
    let still_good = |tokens: &OAuthTokens| tokens.expires_at.map(|expires_at| expires_at - 60 > chrono::Utc::now().timestamp()).unwrap_or(true);
    if !force_refresh && still_good(&tokens) {
        return Ok(AccessTokenOutcome::Usable(tokens.access_token));
    }

    let _lock = FileLock::acquire(&paths.lock_file(&format!("oauth-{app_id}")), Duration::from_secs(40)).map_err(|error| error.to_string())?;
    // Another hub may have refreshed while this one waited for the lock.
    let mut secrets = vault.read(app_id);
    let Some(record) = secrets.oauth.clone() else { return Ok(AccessTokenOutcome::NeedsSignIn) };
    let Some(current_tokens) = record.tokens.clone() else { return Ok(AccessTokenOutcome::NeedsSignIn) };
    if current_tokens.access_token != tokens.access_token && still_good(&current_tokens) {
        return Ok(AccessTokenOutcome::Usable(current_tokens.access_token));
    }
    let (Some(refresh_token), Some(token_endpoint), Some(client)) = (current_tokens.refresh_token.clone(), record.token_endpoint.clone(), record.client.clone()) else {
        return Ok(AccessTokenOutcome::NeedsSignIn);
    };
    let mut form = vec![("grant_type", "refresh_token".to_string()), ("refresh_token", refresh_token.clone())];
    if let Some(resource) = &record.resource {
        form.push(("resource", resource.clone()));
    }
    match request_tokens(&token_endpoint, &client, &mut form) {
        Ok(mut new_tokens) => {
            if new_tokens.refresh_token.is_none() {
                new_tokens.refresh_token = Some(refresh_token);
            }
            let access_token = new_tokens.access_token.clone();
            if let Some(record) = secrets.oauth.as_mut() {
                record.tokens = Some(new_tokens);
            }
            vault.write(app_id, &secrets)?;
            Ok(AccessTokenOutcome::Usable(access_token))
        }
        Err(error) if error == INVALID_GRANT => {
            // The refresh token is dead: forget the tokens (keep the registered client) so the status says "needs sign-in".
            if let Some(record) = secrets.oauth.as_mut() {
                record.tokens = None;
            }
            vault.write(app_id, &secrets)?;
            Ok(AccessTokenOutcome::NeedsSignIn)
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn www_authenticate_is_read() {
        let challenge = parse_www_authenticate(r#"Bearer error="invalid_token", resource_metadata="https://a.example/.well-known/oauth-protected-resource/mcp", scope="read write""#);
        assert_eq!(challenge.resource_metadata.as_deref(), Some("https://a.example/.well-known/oauth-protected-resource/mcp"));
        assert_eq!(challenge.scope.as_deref(), Some("read write"));
        assert_eq!(challenge.error.as_deref(), Some("invalid_token"));
        assert_eq!(parse_www_authenticate("Bearer realm=x"), WwwAuthenticateChallenge::default());
    }

    #[test]
    fn pkce_matches_the_rfc_example() {
        // RFC 7636, appendix B.
        assert_eq!(pkce_challenge_for("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn resources_are_canonical() {
        assert_eq!(canonical_resource("https://mcp.example.com/"), "https://mcp.example.com");
        assert_eq!(canonical_resource("https://mcp.example.com/mcp#x"), "https://mcp.example.com/mcp");
    }
}
