//! Minimal collection-v2 wire messages used by this backend.
#[derive(Clone, PartialEq, prost::Message)]
pub struct CollectionItem {
    #[prost(string, tag = "1")]
    pub uri: String,
    #[prost(int32, tag = "2")]
    pub added_at: i32,
    #[prost(bool, tag = "3")]
    pub is_removed: bool,
}
#[derive(Clone, PartialEq, prost::Message)]
pub struct PageRequest {
    #[prost(string, tag = "1")]
    pub username: String,
    #[prost(string, tag = "2")]
    pub set: String,
    #[prost(string, tag = "3")]
    pub pagination_token: String,
    #[prost(int32, tag = "4")]
    pub limit: i32,
}
#[derive(Clone, PartialEq, prost::Message)]
pub struct PageResponse {
    #[prost(message, repeated, tag = "1")]
    pub items: Vec<CollectionItem>,
    #[prost(string, tag = "2")]
    pub next_page_token: String,
    #[prost(string, tag = "3")]
    pub sync_token: String,
}
#[derive(Clone, PartialEq, prost::Message)]
pub struct WriteRequest {
    #[prost(string, tag = "1")]
    pub username: String,
    #[prost(string, tag = "2")]
    pub set: String,
    #[prost(message, repeated, tag = "3")]
    pub items: Vec<CollectionItem>,
}
#[derive(Clone, PartialEq, prost::Message)]
pub struct ContainsRequest {
    #[prost(string, tag = "1")]
    pub username: String,
    #[prost(string, tag = "2")]
    pub set: String,
    #[prost(message, repeated, tag = "3")]
    pub items: Vec<CollectionItem>,
}
#[derive(Clone, PartialEq, prost::Message)]
pub struct ContainsResponse {
    #[prost(bool, repeated, tag = "1")]
    pub found: Vec<bool>,
}
