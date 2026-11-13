//! Private stdio bridge. The shell owns its lifetime; no network listener or
//! authentication tokens are exposed to other local applications.
use super::{SpotifyApiError, device_login::PendingLogin, router, session};
use crate::config::BackendConfig;
use anyhow::{Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
    task::JoinSet,
};

#[derive(Deserialize)]
struct Request {
    id: u64,
    command: String,
    #[serde(default)]
    request_id: Option<u64>,
    #[serde(default)]
    method: String,
    #[serde(default)]
    path: String,
    #[serde(default)]
    query: Value,
    #[serde(default)]
    body: Value,
}
fn response(id: u64, status: u16, data: Value, error: &str) -> Value {
    json!({"type":"response","id":id,"status":status,"data":data,"error":error})
}
fn route_input(path: &str, query: &Value) -> Result<(String, Vec<(String, String)>)> {
    let url = url::Url::parse(&format!(
        "https://api.spotify.com/v1{}",
        if path.starts_with('/') { path } else { "" }
    ))?;
    let url = if path.starts_with("https://") {
        url::Url::parse(path)?
    } else {
        url
    };
    if url.scheme() != "https"
        || url.host_str() != Some("api.spotify.com")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || !url.path().starts_with("/v1/")
    {
        bail!("Invalid Spotify request path");
    }
    let mut args: Vec<(String, String)> = url
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if let Some(query) = query.as_object() {
        for (k, v) in query {
            args.retain(|(key, _)| key != k);
            let value = match v {
                Value::String(v) => v.clone(),
                Value::Array(v) => v
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(","),
                Value::Null => continue,
                _ => v.to_string(),
            };
            args.push((k.clone(), value));
        }
    }
    Ok((url.path().trim_start_matches("/v1").into(), args))
}
async fn handle(request: &Request) -> Result<Value> {
    match request.command.as_str() {
        "status" => match session::current().await {
            Ok(_) => Ok(json!({"logged_in":true})),
            Err(session::Unavailable::NoLogin) => Ok(json!({"logged_in":false})),
            Err(reason) => bail!("{}", reason.message()),
        },
        "token" => {
            let session = session::current()
                .await
                .map_err(|e| anyhow::anyhow!(e.message()))?;
            let token = session.session().login5().auth_token().await?;
            Ok(json!({"token":token.access_token}))
        }
        "request" => {
            let method = http::Method::from_bytes(request.method.as_bytes())?;
            let (path, query) = route_input(&request.path, &request.query)?;
            let query: Vec<(&str, String)> =
                query.iter().map(|(k, v)| (k.as_str(), v.clone())).collect();
            let mut result = router::route(
                &method,
                &path,
                &query,
                (!request.body.is_null()).then_some(&request.body),
            )
            .await?;
            resolve_pages(&mut result, &path, &query);
            Ok(result)
        }
        _ => bail!("Unknown native session command"),
    }
}
// Adapters use internal page markers. Convert these to the same safe URL shape
// understood by the existing QML pagination layer, preserving filters and type.
fn resolve_pages(value: &mut Value, path: &str, query: &[(&str, String)]) {
    match value {
        Value::Object(object) => {
            if let Some(next) = object
                .get("next")
                .and_then(Value::as_str)
                .filter(|v| v.starts_with("internal://"))
            {
                let marker = url::Url::parse(next).expect("internal pagination marker");
                let mut next = url::Url::parse(&format!("https://api.spotify.com/v1{path}"))
                    .expect("validated path");
                let offsets: Vec<_> = marker
                    .query_pairs()
                    .map(|(k, v)| (k.into_owned(), v.into_owned()))
                    .collect();
                {
                    let mut params = next.query_pairs_mut();
                    for (key, val) in query {
                        if *key != "offset" && *key != "after" {
                            params.append_pair(key, val);
                        }
                    }
                    for (key, val) in offsets {
                        params.append_pair(&key, &val);
                    }
                    if marker.host_str() == Some("following") {
                        if let Some(after) = object.get("cursors").and_then(|v| v["after"].as_str())
                        {
                            params.append_pair("after", after);
                        }
                    }
                }
                object.insert("next".into(), Value::String(next.into()));
            }
            for (key, child) in object.iter_mut() {
                let child_path = if key == "tracks"
                    && path.starts_with("/albums/")
                    && !path.ends_with("/tracks")
                {
                    format!("{path}/tracks")
                } else if key == "episodes"
                    && path.starts_with("/shows/")
                    && !path.ends_with("/episodes")
                {
                    format!("{path}/episodes")
                } else {
                    path.into()
                };
                resolve_pages(child, &child_path, query);
            }
        }
        Value::Array(items) => {
            for item in items {
                resolve_pages(item, path, query);
            }
        }
        _ => {}
    }
}
pub async fn serve(config: BackendConfig) -> Result<()> {
    session::configure(config);
    let (tx, mut rx) = mpsc::channel::<Value>(32);
    let writer = tokio::spawn(async move {
        let mut output = tokio::io::stdout();
        while let Some(message) = rx.recv().await {
            let mut bytes = serde_json::to_vec(&message)?;
            bytes.push(b'\n');
            output.write_all(&bytes).await?;
            output.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    });
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    let mut jobs = JoinSet::new();
    let mut aborts = std::collections::HashMap::<u64, tokio::task::AbortHandle>::new();
    loop {
        let line = tokio::select! {
            line = input.next_line() => line?,
            _ = jobs.join_next(), if !jobs.is_empty() => continue,
        };
        let Some(line) = line else {
            break;
        };
        if line.len() > 1_048_576 {
            break;
        }
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                tx.send(response(0, 400, Value::Null, "Invalid native request"))
                    .await?;
                continue;
            }
        };
        aborts.retain(|_, handle| !handle.is_finished());
        if request.command == "cancel_request" {
            if let Some(handle) = request.request_id.and_then(|id| aborts.remove(&id)) {
                handle.abort();
            }
            tx.send(response(request.id, 200, Value::Null, "")).await?;
            continue;
        }
        if request.command == "cancel" || request.command == "logout" {
            jobs.abort_all();
            while jobs.join_next().await.is_some() {}
            if request.command == "logout" {
                session::forget().await;
            }
            tx.send(response(request.id, 200, json!({"logged_in":false}), ""))
                .await?;
            break; // Also discards every account-specific cache.
        }
        if request.command == "login" {
            jobs.abort_all();
            while jobs.join_next().await.is_some() {}
            super::library::clear_cache().await;
            super::search::clear_cache().await;
            super::playlists::forget_rootlist().await;
            super::metadata::clear_cache();
        }
        if jobs.len() >= 8 {
            tx.send(response(
                request.id,
                503,
                Value::Null,
                "Spotify is busy. Try again.",
            ))
            .await?;
            continue;
        }
        let tx = tx.clone();
        let id = request.id;
        let abort = jobs.spawn(async move {
            let result = if request.command == "login" {
                async {
                    let pending = PendingLogin::start().await?;
                    tx.send(json!({"type":"pairing","id":request.id,"url":pending.url(),"code":pending.code()})).await?;
                    let credentials = pending.finish().await?;
                    session::log_in(credentials).await.map_err(|e| anyhow::anyhow!(e.message()))?;
                    Ok(json!({"logged_in":true}))
                }.await
            } else {
                tokio::time::timeout(Duration::from_secs(40), handle(&request)).await
                    .unwrap_or_else(|_| Err(anyhow::anyhow!("Spotify request timed out")))
            };
            let message = match result {
                Ok(data) => response(request.id,200,data,""),
                Err(error) => {
                    let status = error.downcast_ref::<SpotifyApiError>().map(|e| e.status.as_u16()).unwrap_or(503);
                    response(request.id,status,Value::Null,&error.to_string())
                }
            };
            let _ = tx.send(message).await;
        });
        aborts.insert(id, abort);
    }
    jobs.abort_all();
    while jobs.join_next().await.is_some() {}
    drop(tx);
    writer.await??;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pagination_is_local_and_preserves_query() {
        let (path, query) = route_input(
            "https://api.spotify.com/v1/me/tracks?offset=30",
            &json!({"limit":30}),
        )
        .unwrap();
        assert_eq!(path, "/me/tracks");
        assert!(query.contains(&("offset".into(), "30".into())));
        assert!(query.contains(&("limit".into(), "30".into())));
        assert!(route_input("https://evil.test/v1/me", &Value::Null).is_err());
    }
    #[test]
    fn next_page_keeps_filters_and_following_cursor() {
        let mut page = json!({"next":"internal://page?offset=30"});
        resolve_pages(
            &mut page,
            "/search",
            &[
                ("q", "a & b".into()),
                ("type", "track".into()),
                ("offset", "0".into()),
            ],
        );
        let (path, args) = route_input(page["next"].as_str().unwrap(), &Value::Null).unwrap();
        assert_eq!(path, "/search");
        assert!(args.contains(&("offset".into(), "30".into())));
        assert!(args.contains(&("q".into(), "a & b".into())));
        let mut page = json!({"artists":{"next":"internal://following","cursors":{"after":"abc"}}});
        resolve_pages(&mut page, "/me/following", &[]);
        assert!(
            page["artists"]["next"]
                .as_str()
                .unwrap()
                .ends_with("?after=abc")
        );
    }
}
