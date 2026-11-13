//! Native protocol operations, implemented here on the existing librespot session.
//! Writes are sent once. Retrying a timed-out playlist edit can duplicate tracks.
use super::collection::{
    CollectionItem, ContainsRequest, ContainsResponse, PageRequest, PageResponse, WriteRequest,
};
use bytes::Bytes;
use http::{HeaderMap, Method};
use librespot_core::{Error, SpotifyId, session::Session, spclient::SpClient};
use librespot_protocol::{
    connect::SetVolumeCommand,
    playlist4_external::{ListChanges, SelectedListContent},
};
use prost::Message as ProstMessage;
use protobuf::Message;
use serde_json::{Value, json};
use std::{ops::Deref, sync::OnceLock, time::Duration};

pub struct NativeApi {
    session: Session,
    core: SpClient,
}
impl Deref for NativeApi {
    type Target = SpClient;
    fn deref(&self) -> &SpClient {
        &self.core
    }
}
fn http() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(25))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("TLS client")
    })
}
impl NativeApi {
    pub fn new(session: &Session) -> Self {
        Self {
            session: session.clone(),
            core: session.spclient().clone(),
        }
    }

    async fn send(
        &self,
        method: &Method,
        url: String,
        headers: HeaderMap,
        body: &[u8],
    ) -> Result<Bytes, Error> {
        let token = self.session.login5().auth_token().await?;
        let client_token = self.core.client_token().await?;
        let response = http()
            .request(method.clone(), url)
            .headers(headers)
            .bearer_auth(token.access_token)
            .header("client-token", client_token)
            .body(body.to_vec())
            .send()
            .await
            .map_err(|_| Error::unavailable("Spotify request failed"))?;
        let status = response.status();
        if !status.is_success() {
            let message = format!("Spotify returned HTTP {}", status.as_u16());
            return Err(match status.as_u16() {
                400 => Error::invalid_argument(message),
                401 => Error::unauthenticated(message),
                403 => Error::permission_denied(message),
                404 => Error::not_found(message),
                412 => Error::failed_precondition(message),
                429 => Error::resource_exhausted(message),
                _ => Error::unavailable(message),
            });
        }
        super::response_bytes(response, 16 * 1024 * 1024)
            .await
            .map_err(|_| Error::unavailable("Spotify response was interrupted or too large"))
    }

    pub async fn request(
        &self,
        method: &Method,
        path: &str,
        headers: Option<HeaderMap>,
        body: Option<&[u8]>,
    ) -> Result<Bytes, Error> {
        if !path.starts_with('/') || path.starts_with("//") {
            return Err(Error::invalid_argument("Invalid native path"));
        }
        self.send(
            method,
            format!("{}{}", self.core.base_url().await?, path),
            headers.unwrap_or_default(),
            body.unwrap_or_default(),
        )
        .await
    }

    async fn proto<M: Message>(
        &self,
        path: &str,
        message: &M,
        content_type: &'static str,
    ) -> Result<Bytes, Error> {
        let headers = HeaderMap::from_iter([
            (
                http::header::CONTENT_TYPE,
                http::HeaderValue::from_static(content_type),
            ),
            (
                http::header::ACCEPT,
                http::HeaderValue::from_static(content_type),
            ),
        ]);
        self.request(
            &Method::POST,
            path,
            Some(headers),
            Some(&message.write_to_bytes()?),
        )
        .await
    }
    pub async fn get_collection_page(
        &self,
        set: &str,
        token: &str,
        limit: i32,
    ) -> Result<PageResponse, Error> {
        let request = PageRequest {
            username: self.session.username(),
            set: set.into(),
            pagination_token: token.into(),
            limit,
        };
        let bytes = self.collection("/collection/v2/paging", &request).await?;
        PageResponse::decode(bytes)
            .map_err(|_| Error::failed_precondition("Invalid Spotify collection response"))
    }
    pub async fn write_collection(
        &self,
        set: &str,
        items: Vec<CollectionItem>,
    ) -> Result<(), Error> {
        let request = WriteRequest {
            username: self.session.username(),
            set: set.into(),
            items,
        };
        self.collection("/collection/v2/write", &request).await?;
        Ok(())
    }
    pub async fn collection_contains(&self, set: &str, uris: &[&str]) -> Result<Vec<bool>, Error> {
        let request = ContainsRequest {
            username: self.session.username(),
            set: set.into(),
            items: uris
                .iter()
                .map(|uri| CollectionItem {
                    uri: (*uri).into(),
                    ..Default::default()
                })
                .collect(),
        };
        let bytes = self.collection("/collection/v2/contains", &request).await?;
        let result = ContainsResponse::decode(bytes)
            .map_err(|_| Error::failed_precondition("Invalid Spotify collection response"))?;
        if result.found.len() != uris.len() {
            return Err(Error::failed_precondition(
                "Incomplete Spotify collection response",
            ));
        }
        Ok(result.found)
    }
    async fn collection<M: ProstMessage>(&self, path: &str, message: &M) -> Result<Bytes, Error> {
        let headers = HeaderMap::from_iter([
            (
                http::header::CONTENT_TYPE,
                http::HeaderValue::from_static("application/vnd.collection-v2.spotify.proto"),
            ),
            (
                http::header::ACCEPT,
                http::HeaderValue::from_static("application/vnd.collection-v2.spotify.proto"),
            ),
        ]);
        self.request(
            &Method::POST,
            path,
            Some(headers),
            Some(&message.encode_to_vec()),
        )
        .await
    }
    async fn playlist_changes(
        &self,
        path: &str,
        changes: &ListChanges,
    ) -> Result<SelectedListContent, Error> {
        let bytes = self
            .proto(path, changes, "application/x-www-form-urlencoded")
            .await?;
        Ok(SelectedListContent::parse_from_bytes(&bytes)?)
    }
    pub async fn post_playlist_changes(
        &self,
        id: &SpotifyId,
        changes: &ListChanges,
    ) -> Result<SelectedListContent, Error> {
        self.playlist_changes(
            &format!("/playlist/v2/playlist/{}/changes", id.to_base62()),
            changes,
        )
        .await
    }
    pub async fn post_rootlist_changes(
        &self,
        changes: &ListChanges,
    ) -> Result<SelectedListContent, Error> {
        self.playlist_changes(
            &format!(
                "/playlist/v2/user/{}/rootlist/changes",
                self.session.username()
            ),
            changes,
        )
        .await
    }
    pub async fn pathfinder_query(
        &self,
        operation: &str,
        hash: &str,
        variables: Value,
    ) -> Result<Value, Error> {
        let body = json!({"operationName":operation,"variables":variables,"extensions":{"persistedQuery":{"version":1,"sha256Hash":hash}}}).to_string();
        let headers = HeaderMap::from_iter([
            (
                http::header::CONTENT_TYPE,
                http::HeaderValue::from_static("application/json"),
            ),
            (
                http::HeaderName::from_static("app-platform"),
                http::HeaderValue::from_static("Win32_x86_64"),
            ),
            (
                http::HeaderName::from_static("spotify-app-version"),
                librespot_core::version::spotify_semantic_version().parse()?,
            ),
        ]);
        let bytes = self
            .send(
                &Method::POST,
                "https://api-partner.spotify.com/pathfinder/v2/query".into(),
                headers,
                body.as_bytes(),
            )
            .await?;
        Ok(serde_json::from_slice(&bytes)?)
    }
    pub async fn send_player_command(
        &self,
        target: &str,
        mut command: Value,
    ) -> Result<Bytes, Error> {
        let now = chrono::Utc::now().timestamp_millis();
        let id = format!("{:032x}", rand::random::<u128>());
        if let Some(object) = command.as_object_mut() {
            object.entry("options").or_insert(json!({"override_restrictions":false,"only_for_local_device":false,"system_initiated":false}));
            object.entry("logging_params").or_insert(json!({"command_initiated_time":now,"command_received_time":now,"page_instance_ids":[],"interaction_ids":[],"device_identifier":self.session.device_id(),"command_id":id}));
        }
        let body = json!({"command":command,"connection_type":"wlan","intent_id":id}).to_string();
        let mut headers = HeaderMap::new();
        headers.insert(http::header::CONTENT_TYPE, "application/json".parse()?);
        headers.insert(
            "x-spotify-connection-id",
            self.session.connection_id().parse()?,
        );
        self.request(
            &Method::POST,
            &format!(
                "/connect-state/v1/player/command/from/{}/to/{target}",
                self.session.device_id()
            ),
            Some(headers),
            Some(body.as_bytes()),
        )
        .await
    }
    pub async fn set_remote_volume(&self, target: &str, volume: u16) -> Result<Bytes, Error> {
        let body = SetVolumeCommand {
            volume: volume.into(),
            ..Default::default()
        }
        .write_to_bytes()?;
        let mut headers = HeaderMap::new();
        headers.insert(
            http::header::CONTENT_TYPE,
            "application/x-protobuf".parse()?,
        );
        headers.insert(
            "x-spotify-connection-id",
            self.session.connection_id().parse()?,
        );
        self.request(
            &Method::PUT,
            &format!(
                "/connect-state/v1/connect/volume/from/{}/to/{target}",
                self.session.device_id()
            ),
            Some(headers),
            Some(&body),
        )
        .await
    }
}
