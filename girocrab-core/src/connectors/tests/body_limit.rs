use crate::connectors::{read_body_limited, too_large};
use crate::error::CoreResult;

/// Answers one request on a local port with `response` and returns the URL.
fn serve_once(response: &'static str) -> String {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        let (mut s, _) = listener.accept().unwrap();
        let _ = s.read(&mut [0u8; 4096]);
        let _ = s.write_all(response.as_bytes());
    });
    url
}

async fn read(response: &'static str, limit: usize) -> CoreResult<Vec<u8>> {
    // A proxy from the environment would take the request instead of the local server.
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let resp = client.get(serve_once(response)).send().await.unwrap();
    read_body_limited(resp, limit).await
}

fn assert_too_large(r: CoreResult<Vec<u8>>, limit: usize) {
    assert_eq!(r.unwrap_err().to_string(), too_large(limit).to_string());
}

#[tokio::test]
async fn body_within_the_limit_is_returned() {
    let r = read("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", 5).await;
    assert_eq!(r.unwrap(), b"hello");
}

#[tokio::test]
async fn declared_length_over_the_limit_fails_before_reading() {
    // The body never arrives: reading it would fail with a different error.
    let r = read("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n", 8).await;
    assert_too_large(r, 8);
}

#[tokio::test]
async fn chunked_body_over_the_limit_fails() {
    let r = read(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n",
        8,
    )
    .await;
    assert_too_large(r, 8);
}
