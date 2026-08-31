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
    let url = format!("{}/departures", config::BACKEND_URL);

    let mut builder = client
        .get(&url)
        .timeout(Duration::from_secs(config::BACKEND_TIMEOUT_SECS));

    if !config::BACKEND_API_KEY.is_empty() {
        builder = builder.bearer_auth(config::BACKEND_API_KEY);
    }

    builder.send().await?.json::<DeparturesResponse>().await
}
