use serde::Deserialize;
use std::time::Duration;

use crate::config;

#[derive(Deserialize, Debug)]
pub struct DeparturesResponse {
    pub stops: Vec<Stop>,
}

#[derive(Deserialize, Debug)]
pub struct Stop {
    pub stop_name: String,
    pub departures: Vec<Departure>,
}

#[derive(Deserialize, Debug)]
pub struct Departure {
    pub line: String,
    pub destination: String,
    /// Minutes until departure. 0 or negative = departing now.
    pub minutes: i32,
}

pub async fn fetch(client: &reqwest::Client) -> Result<DeparturesResponse, reqwest::Error> {
    let cfg = config::get();
    let url = format!("{}/departures", cfg.backend_url);

    let mut builder = client
        .get(&url)
        .timeout(Duration::from_secs(cfg.backend_timeout_secs));

    if !cfg.backend_api_key.is_empty() {
        builder = builder.bearer_auth(&cfg.backend_api_key);
    }

    builder.send().await?.json::<DeparturesResponse>().await
}
