use std::{
    fs,
    net::TcpListener,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn occupied_callback_port_exits_before_publishing_oauth_url() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let temporary = std::env::temp_dir().join(format!(
        "omarchy-oauth-port-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&temporary).unwrap();
    let config = temporary.join("spotifyd.conf");
    fs::write(&config, "[global]\n").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_omarchy-spotify-backend"))
        .arg("authenticate")
        .arg("--config-path")
        .arg(&config)
        .arg("--oauth-port")
        .arg(port.to_string())
        .env("XDG_STATE_HOME", temporary.join("state"))
        .env("XDG_CACHE_HOME", temporary.join("cache"))
        // A regression must not open a real browser while running the test.
        .env("PATH", &temporary)
        .env("BROWSER", "/bin/false")
        .env("XDG_CURRENT_DESKTOP", "")
        .output()
        .unwrap();
    fs::remove_dir_all(&temporary).unwrap();
    assert_eq!(output.status.code(), Some(21));
    assert!(
        output.stdout.is_empty(),
        "authorization URL must not be published"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains(&format!("port {port} is already in use")));
    assert!(!stderr.contains("accounts.spotify.com"));
}
