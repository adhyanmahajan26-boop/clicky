//! Stopping an engine and everything it started, on each platform.
//!
//! Mac and Linux: the engine runs in its own process group; Stop sends SIGTERM to the group, then SIGKILL to whatever ignored
//! it. The groups running now are written to disk, so a launch after a crash ends any engine left behind (only a process that
//! started when the recorded one did is touched, never a later one that got the same id).
//!
//! Windows: the engine runs in a Job Object that kills every process in it when it's closed, so Stop ends the whole tree and a
//! crash of Theo itself takes the engines with it (the job's handle closes with the process).

use std::path::PathBuf;
use std::sync::Mutex;

#[cfg(unix)]
pub fn configure(cmd: &mut tokio::process::Command) {
    cmd.process_group(0);
}

#[cfg(windows)]
pub fn configure(cmd: &mut tokio::process::Command) {
    // CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
    cmd.creation_flags(0x0000_0200 | 0x0800_0000);
}

pub struct ProcessTree {
    #[cfg(unix)]
    pub pgid: i32,
    #[cfg(windows)]
    job: isize,
}

// The job handle is only used through Windows calls that are safe from any thread.
unsafe impl Send for ProcessTree {}
unsafe impl Sync for ProcessTree {}

impl ProcessTree {
    #[cfg(unix)]
    pub fn attach(child: &tokio::process::Child) -> std::io::Result<Self> {
        let pid = child.id().ok_or_else(|| std::io::Error::other("engine exited before it could be tracked"))? as i32;
        Ok(Self { pgid: pid })
    }

    #[cfg(windows)]
    pub fn attach(child: &tokio::process::Child) -> std::io::Result<Self> {
        use windows_sys::Win32::System::JobObjects::*;
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info as *const _ as *const _, std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32) == 0 {
                // Without kill-on-close the tree wouldn't end with Theo: don't pretend it's tracked.
                let error = std::io::Error::last_os_error();
                windows_sys::Win32::Foundation::CloseHandle(job);
                return Err(error);
            }
            let handle = child.raw_handle().ok_or_else(|| std::io::Error::other("engine exited before it could be tracked"))?;
            if AssignProcessToJobObject(job, handle as _) == 0 {
                let error = std::io::Error::last_os_error();
                windows_sys::Win32::Foundation::CloseHandle(job);
                return Err(error);
            }
            Ok(Self { job: job as isize })
        }
    }

    /// Asks everything in the tree to stop (SIGTERM). Windows has no polite stop for console programs that aren't
    /// attached to a console, so it ends them.
    pub fn terminate(&self) {
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.pgid, libc::SIGTERM);
        }
        #[cfg(windows)]
        self.kill();
    }

    pub fn kill(&self) {
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.pgid, libc::SIGKILL);
        }
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job as _, 1);
        }
    }

    /// Anything still running in the tree.
    pub fn alive(&self) -> bool {
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.pgid, 0) == 0
        }
        #[cfg(windows)]
        unsafe {
            use windows_sys::Win32::System::JobObjects::*;
            let mut info: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = std::mem::zeroed();
            let ok = QueryInformationJobObject(self.job as _, JobObjectBasicAccountingInformation, &mut info as *mut _ as *mut _, std::mem::size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32, std::ptr::null_mut());
            ok != 0 && info.ActiveProcesses > 0
        }
    }
}

#[cfg(windows)]
impl Drop for ProcessTree {
    fn drop(&mut self) {
        unsafe {
            // KILL_ON_JOB_CLOSE: whatever is left in the tree ends with the handle.
            windows_sys::Win32::Foundation::CloseHandle(self.job as _);
        }
    }
}

// MARK: Engines left behind by a crash (Mac and Linux)

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq)]
struct Entry {
    pgid: i32,
    started: u64,
    boot: String,
}

/// The engine groups running now, on disk.
pub struct Registry {
    file: PathBuf,
    entries: Mutex<Vec<Entry>>,
}

impl Registry {
    pub fn new(file: PathBuf) -> Self { Self { file, entries: Mutex::new(vec![]) } }

    fn write(&self, entries: &[Entry]) {
        if entries.is_empty() {
            let _ = std::fs::remove_file(&self.file);
        } else if let Ok(data) = serde_json::to_vec(entries) {
            let _ = crate::store::write_atomic(&self.file, &data);
        }
    }

    pub fn add(&self, tree: &ProcessTree) {
        #[cfg(unix)]
        {
            let entry = Entry { pgid: tree.pgid, started: start_time(tree.pgid).unwrap_or(0), boot: boot_id() };
            let mut entries = self.entries.lock().unwrap();
            entries.push(entry);
            self.write(&entries);
        }
        #[cfg(windows)]
        let _ = tree;
    }

    pub fn remove(&self, tree: &ProcessTree) {
        #[cfg(unix)]
        {
            let mut entries = self.entries.lock().unwrap();
            entries.retain(|e| e.pgid != tree.pgid);
            self.write(&entries);
        }
        #[cfg(windows)]
        let _ = tree;
    }

    /// Ends every engine group running now (Theo is quitting).
    pub fn kill_all(&self) {
        let mut entries = self.entries.lock().unwrap();
        #[cfg(unix)]
        for e in entries.iter() {
            unsafe {
                libc::killpg(e.pgid, libc::SIGKILL);
            }
        }
        entries.clear();
        self.write(&entries);
    }

    /// At launch: ends every engine group from before that's still running. Returns how many.
    pub fn end_leftovers(&self) -> usize {
        let Ok(data) = std::fs::read(&self.file) else { return 0 };
        let _ = std::fs::remove_file(&self.file);
        let Ok(list) = serde_json::from_slice::<Vec<Entry>>(&data) else { return 0 };
        #[cfg(unix)]
        {
            let boot = boot_id();
            let mut ended = 0;
            for entry in list {
                if entry.pgid <= 1 || entry.started == 0 || entry.boot != boot {
                    continue;
                }
                match start_time(entry.pgid) {
                    // The engine itself is still running: only if it's the same process.
                    Some(started) if started != entry.started => continue,
                    Some(_) => {}
                    // The engine is gone but what it started can live on in its group. While any of it is alive the id
                    // isn't reused, so the group is still the engine's. Only processes started after the engine count.
                    None => {
                        if !group_members(entry.pgid).iter().any(|pid| start_time(*pid).map(|s| s >= entry.started).unwrap_or(false)) {
                            continue;
                        }
                    }
                }
                if unsafe { libc::killpg(entry.pgid, libc::SIGKILL) } == 0 {
                    ended += 1;
                }
            }
            ended
        }
        #[cfg(windows)]
        {
            let _ = list;
            0
        }
    }
}

/// When a process started, in the platform's own units (only ever compared with itself).
#[cfg(target_os = "linux")]
pub fn start_time(pid: i32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // The command name can hold spaces and brackets: fields are counted after the last ')'.
    let rest = &stat[stat.rfind(')')? + 2..];
    rest.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(target_os = "linux")]
fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id").map(|s| s.trim().to_string()).unwrap_or_default()
}

#[cfg(target_os = "linux")]
pub fn group_members(pgid: i32) -> Vec<i32> {
    let mut out = vec![];
    if let Ok(dir) = std::fs::read_dir("/proc") {
        for entry in dir.flatten() {
            let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else { continue };
            if unsafe { libc::getpgid(pid) } == pgid {
                out.push(pid);
            }
        }
    }
    out
}

#[cfg(target_os = "macos")]
pub fn start_time(pid: i32) -> Option<u64> {
    unsafe {
        let mut info: libc::proc_bsdinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        let got = libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, size);
        if got == size { Some(info.pbi_start_tvsec) } else { None }
    }
}

#[cfg(target_os = "macos")]
fn boot_id() -> String {
    unsafe {
        let mut boot: libc::timeval = std::mem::zeroed();
        let mut size = std::mem::size_of::<libc::timeval>();
        let mut name = [libc::CTL_KERN, libc::KERN_BOOTTIME];
        if libc::sysctl(name.as_mut_ptr(), 2, &mut boot as *mut _ as *mut libc::c_void, &mut size, std::ptr::null_mut(), 0) == 0 {
            boot.tv_sec.to_string()
        } else {
            String::new()
        }
    }
}

#[cfg(target_os = "macos")]
pub fn group_members(pgid: i32) -> Vec<i32> {
    let mut pids = vec![0i32; 1024];
    let bytes = unsafe { libc::proc_listpids(2 /* PROC_PGRP_ONLY */, pgid as u32, pids.as_mut_ptr() as *mut libc::c_void, (pids.len() * 4) as i32) };
    if bytes <= 0 {
        return vec![];
    }
    pids.truncate(bytes as usize / 4);
    pids.into_iter().filter(|p| *p > 0).collect()
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
pub fn start_time(_pid: i32) -> Option<u64> { None }
#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn boot_id() -> String { String::new() }
#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
pub fn group_members(_pgid: i32) -> Vec<i32> { vec![] }

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn python() -> &'static str { if cfg!(windows) { "python" } else { "python3" } }

    /// A process that starts a grandchild and prints its id, then both sleep.
    async fn family() -> (tokio::process::Child, ProcessTree, u32) {
        let code = "import subprocess,sys,time\np=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\nprint(p.pid, flush=True)\ntime.sleep(60)";
        let mut cmd = tokio::process::Command::new(python());
        cmd.args(["-c", code]).stdout(std::process::Stdio::piped());
        configure(&mut cmd);
        let mut child = cmd.spawn().unwrap();
        let tree = ProcessTree::attach(&child).unwrap();
        use tokio::io::AsyncBufReadExt;
        let mut lines = tokio::io::BufReader::new(child.stdout.take().unwrap()).lines();
        let grandchild: u32 = lines.next_line().await.unwrap().unwrap().trim().parse().unwrap();
        (child, tree, grandchild)
    }

    fn running(pid: u32) -> bool {
        #[cfg(unix)]
        unsafe {
            if libc::kill(pid as i32, 0) != 0 { return false; }
            // A zombie still answers kill(0); ask ps.
            let out = std::process::Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output().unwrap();
            let s = String::from_utf8_lossy(&out.stdout);
            !s.trim().is_empty() && !s.trim().starts_with('Z')
        }
        #[cfg(windows)]
        unsafe {
            use windows_sys::Win32::System::Threading::*;
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if h.is_null() { return false; }
            let mut code = 0u32;
            GetExitCodeProcess(h, &mut code);
            windows_sys::Win32::Foundation::CloseHandle(h);
            code == 259
        }
    }

    #[tokio::test]
    async fn kill_ends_the_whole_tree() {
        let (mut child, tree, grandchild) = family().await;
        assert!(tree.alive());
        assert!(running(grandchild));
        tree.kill();
        tokio::time::timeout(Duration::from_secs(10), child.wait()).await.unwrap().unwrap();
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!running(grandchild), "the grandchild outlived the kill");
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn closing_the_job_ends_the_tree() {
        // What happens when Theo itself dies: its handle to the job closes.
        let (mut child, tree, grandchild) = family().await;
        drop(tree);
        tokio::time::timeout(Duration::from_secs(10), child.wait()).await.unwrap().unwrap();
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!running(grandchild), "the grandchild outlived the job");
    }
}
