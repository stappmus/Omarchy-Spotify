//! Spotify device authorization owned by this repository. No callback listener,
//! developer dashboard or user-supplied client ID is involved.
use anyhow::{Context, Result, bail};
use librespot_core::authentication::Credentials;
use serde::Deserialize;
use std::time::{Duration, Instant};

// The existing librespot desktop identity, also used by its session token provider.
const PLAYER_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const SCOPES: &str = "streaming user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-read-private";
#[derive(Deserialize)]
struct Authorization {
    device_code: String,
    user_code: String,
    verification_uri: String,
    verification_uri_complete: Option<String>,
    expires_in: u64,
    #[serde(default = "default_interval")]
    interval: u64,
}
fn default_interval() -> u64 {
    5
}
#[derive(Deserialize)]
struct TokenReply {
    access_token: Option<String>,
    error: Option<String>,
}

pub struct PendingLogin {
    client: reqwest::Client,
    auth: Authorization,
    deadline: Instant,
}
impl PendingLogin {
    pub fn url(&self) -> &str {
        self.auth
            .verification_uri_complete
            .as_deref()
            .unwrap_or(&self.auth.verification_uri)
    }
    pub fn code(&self) -> &str {
        &self.auth.user_code
    }
    pub async fn start() -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        let response = client
            .post("https://accounts.spotify.com/oauth2/device/authorize")
            .form(&[("client_id", PLAYER_CLIENT_ID), ("scope", SCOPES)])
            .send()
            .await
            .context("Could not reach Spotify sign-in")?;
        if !response.status().is_success() {
            bail!(
                "Spotify sign-in returned HTTP {}",
                response.status().as_u16()
            );
        }
        let auth: Authorization =
            serde_json::from_slice(&super::response_bytes(response, 64 * 1024).await?)
                .context("Spotify returned an invalid sign-in prompt")?;
        validate_url(
            auth.verification_uri_complete
                .as_deref()
                .unwrap_or(&auth.verification_uri),
        )?;
        if auth.device_code.is_empty()
            || auth.user_code.is_empty()
            || auth.user_code.len() > 32
            || !auth
                .user_code
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-')
            || auth.expires_in == 0
            || auth.interval > 3600
        {
            bail!("Spotify returned an incomplete sign-in prompt");
        }
        let deadline = Instant::now() + Duration::from_secs(auth.expires_in.min(3600));
        Ok(Self {
            client,
            auth,
            deadline,
        })
    }
    pub async fn finish(self) -> Result<Credentials> {
        let mut interval = self.auth.interval.max(1);
        loop {
            if Instant::now() + Duration::from_secs(interval) >= self.deadline {
                bail!("Sign-in expired. Click Log in to try again.");
            }
            tokio::time::sleep(Duration::from_secs(interval)).await;
            let response = self
                .client
                .post("https://accounts.spotify.com/api/token")
                .form(&[
                    ("client_id", PLAYER_CLIENT_ID),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ("device_code", self.auth.device_code.as_str()),
                ])
                .send()
                .await
                .context("Could not complete Spotify sign-in")?;
            let successful = response.status().is_success();
            let reply: TokenReply =
                serde_json::from_slice(&super::response_bytes(response, 64 * 1024).await?)
                    .context("Spotify returned an invalid sign-in response")?;
            if successful {
                if let Some(token) = reply.access_token.filter(|v| !v.is_empty()) {
                    return Ok(Credentials::with_access_token(token));
                }
                bail!("Spotify did not complete sign-in");
            }
            match reply.error.as_deref() {
                Some("authorization_pending") => {}
                Some("slow_down") => interval = interval.saturating_add(5),
                Some("access_denied") => bail!("Spotify sign-in was declined"),
                Some("expired_token") => bail!("Sign-in expired. Click Log in to try again."),
                _ => bail!("Spotify could not complete sign-in. Try again."),
            }
        }
    }
}
fn validate_url(value: &str) -> Result<()> {
    let url = url::Url::parse(value)?;
    if url.scheme() != "https"
        || !matches!(
            url.host_str(),
            Some("accounts.spotify.com" | "spotify.com" | "www.spotify.com")
        )
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        bail!("Spotify returned an unexpected sign-in address");
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sign_in_addresses_must_belong_to_spotify() {
        for url in [
            "https://accounts.spotify.com/pair?code=abc",
            "https://spotify.com/pair",
        ] {
            assert!(validate_url(url).is_ok());
        }
        for url in [
            "http://spotify.com/pair",
            "https://spotify.com.evil.test/pair",
            "https://user@spotify.com/pair",
            "https://spotify.com:123/pair",
        ] {
            assert!(validate_url(url).is_err());
        }
    }
}
