//! Repository-owned Spotify session, device login and native request bridge.
mod bridge;
mod catalog;
mod collection;
mod device_login;
mod json;
mod library;
mod metadata;
mod player;
mod playlists;
mod router;
mod search;
mod session;
mod transport;

pub use bridge::serve;

pub async fn authenticate(config: crate::config::BackendConfig) -> anyhow::Result<()> {
    session::configure(config);
    let pending = device_login::PendingLogin::start().await?;
    println!(
        "Log in at {} (pairing code {}).",
        pending.url(),
        pending.code()
    );
    let _ = std::process::Command::new("xdg-open")
        .arg(pending.url())
        .spawn();
    let credentials = pending.finish().await?;
    session::log_in(credentials)
        .await
        .map_err(|e| anyhow::anyhow!(e.message()))?;
    println!("Spotify sign-in succeeded. Library and playback are connected.");
    Ok(())
}

#[derive(Debug)]
pub struct SpotifyApiError {
    pub status: reqwest::StatusCode,
    pub body: String,
}
impl std::fmt::Display for SpotifyApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.status, self.body)
    }
}
impl std::error::Error for SpotifyApiError {}
#[cfg(test)]
fn is_forbidden_error(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<SpotifyApiError>()
        .is_some_and(|e| e.status == reqwest::StatusCode::FORBIDDEN)
}

/// Attribution retained in every distributed executable.
pub const LICENSE_NOTICE: &str = r#"# Third-party notices

The native Spotify JSON adapters in `backend/src/spotify/` contain code adapted
from spotatui commit `2987067afb54f79c79406f3d5fce0e4797d269ae`.
This code is maintained locally; spotatui is not a build or runtime dependency.
Protocol transport, device login and process integration are implemented here.

Source: https://github.com/LargeModGames/spotatui

MIT License

Copyright (c) 2021 Alexander Keliris
Copyright (c) 2025 LargeModGames

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"#;

/// Bound repository-owned HTTP responses even when Content-Length is absent.
async fn response_bytes(
    mut response: reqwest::Response,
    limit: usize,
) -> anyhow::Result<bytes::Bytes> {
    if response
        .content_length()
        .is_some_and(|size| size > limit as u64)
    {
        anyhow::bail!("Spotify response exceeds the size limit");
    }
    let mut body = bytes::BytesMut::new();
    while let Some(chunk) = response.chunk().await? {
        if chunk.len() > limit.saturating_sub(body.len()) {
            anyhow::bail!("Spotify response exceeds the size limit");
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body.freeze())
}
