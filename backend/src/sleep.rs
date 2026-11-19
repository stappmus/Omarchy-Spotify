//! Watches logind for resume-from-sleep so the engine can reconnect at once.

use futures::StreamExt;
use mpris_server::zbus::{self, MatchRule, MessageStream, message::Type};
use tokio::sync::watch;

/// Bumps `resumed` each time logind reports the system woke up. Never returns
/// and never drops the sender, so receivers can select on it unconditionally.
pub async fn watch_resume(resumed: watch::Sender<u64>) {
    if let Err(error) = run(&resumed).await {
        log::warn!("not watching for resume from sleep: {error}");
    }
    std::future::pending::<()>().await;
}

async fn run(resumed: &watch::Sender<u64>) -> zbus::Result<()> {
    let connection = zbus::Connection::system().await?;
    let rule = MatchRule::builder()
        .msg_type(Type::Signal)
        .sender("org.freedesktop.login1")?
        .interface("org.freedesktop.login1.Manager")?
        .member("PrepareForSleep")?
        .path("/org/freedesktop/login1")?
        .build();
    let mut stream = MessageStream::for_match_rule(rule, &connection, None).await?;
    while let Some(message) = stream.next().await {
        let Ok(message) = message else { continue };
        // PrepareForSleep(true) before suspend, (false) after resume.
        if let Ok(false) = message.body().deserialize::<bool>() {
            resumed.send_modify(|count| *count += 1);
        }
    }
    Ok(())
}
