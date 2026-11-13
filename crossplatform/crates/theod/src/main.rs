//! theod: Theo's harness engine as a background program. The desktop app embeds the same engine; this runs it headless, for
//! servers, tests and anyone who wants Theo without a window.
//!
//!   theod [--data DIR] [--test]      run (DIR defaults to the platform's Theo-Desktop folder)
//!   theod --version

use std::path::PathBuf;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let mut data: Option<PathBuf> = None;
    let mut test = std::env::var("THEO_TEST").map(|v| v == "1").unwrap_or(false);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--data" => data = args.next().map(PathBuf::from),
            "--test" => test = true,
            "--version" | "-V" => {
                println!("theod {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            "--help" | "-h" => {
                println!("theod [--data DIR] [--test]\n\nRuns Theo's harness engine. Commands go in DIR/control-inbox as JSON files; answers appear in DIR/control-outbox.");
                return Ok(());
            }
            other => anyhow::bail!("unknown argument {other}"),
        }
    }
    let root = data.unwrap_or_else(theo_core::paths::default_root);
    std::fs::create_dir_all(&root)?;
    let harness = theo_core::Harness::new(root.clone(), test);
    std::fs::write(harness.paths.pid_file(), std::process::id().to_string())?;
    harness.start();
    eprintln!("[theod] running on {} with data in {}", std::env::consts::OS, root.display());
    let inbox = tokio::spawn(theo_core::control::serve_inbox(harness.clone()));
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {
            _ = term.recv() => {}
            _ = tokio::signal::ctrl_c() => {}
            _ = inbox => {}
        }
    }
    #[cfg(not(unix))]
    {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = inbox => {}
        }
    }
    // Engines still running end with Theo: a turn nobody will read shouldn't keep using the owner's subscription.
    harness.shutdown();
    std::process::exit(0);
}
