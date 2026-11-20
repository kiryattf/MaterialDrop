//! C-ABI FFI surface for MaterialDrop's Rust engine (`iroh` QUIC P2P + `rquickshare_core`).

pub mod iroh_node;

use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use once_cell::sync::Lazy;
use tokio::runtime::Runtime;

use crate::iroh_node::{IrohEvent, IrohFileSpec, IrohManager};

#[cfg(any(target_os = "windows", target_os = "linux"))]
use rquickshare_core::{QuickShareEngine, RqsEvent, RqsOutboundFile};

type WakeCallback = extern "C" fn();

struct EngineState {
    runtime: Runtime,
    iroh: IrohManager,
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    rqs: QuickShareEngine,
}

static EVENT_QUEUE: Lazy<Mutex<VecDeque<String>>> = Lazy::new(|| Mutex::new(VecDeque::new()));
static WAKE_CB: Lazy<Mutex<Option<WakeCallback>>> = Lazy::new(|| Mutex::new(None));
static ENGINE: Lazy<Mutex<Option<EngineState>>> = Lazy::new(|| Mutex::new(None));

fn push_event_json(json: String) {
    if let Ok(mut q) = EVENT_QUEUE.lock() {
        q.push_back(json);
    }
    if let Ok(cb_guard) = WAKE_CB.lock() {
        if let Some(cb) = *cb_guard {
            cb();
        }
    }
}

unsafe fn read_c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

fn to_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn md_rust_set_wake_callback(cb: Option<extern "C" fn()>) {
    if let Ok(mut g) = WAKE_CB.lock() {
        *g = cb;
    }
}

#[no_mangle]
pub unsafe extern "C" fn md_rust_init(
    state_dir: *const c_char,
    device_name: *const c_char,
    download_dir: *const c_char,
) -> i32 {
    let sdir = PathBuf::from(read_c_str(state_dir).unwrap_or_else(|| ".".to_string()));
    let dname = read_c_str(device_name).unwrap_or_else(|| "MaterialDrop".to_string());
    let ddir = PathBuf::from(read_c_str(download_dir).unwrap_or_else(|| ".".to_string()));

    let mut eng_guard = match ENGINE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    if let Some(state) = eng_guard.as_mut() {
        state.iroh.update_config(&dname, ddir.clone());
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        state.rqs.update_config(&dname, ddir);
        return 0;
    }

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(4)
        .thread_name("md-rust-rt")
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return -2,
    };

    let iroh_cb: Arc<dyn Fn(IrohEvent) + Send + Sync> = Arc::new(|ev| {
        if let Ok(json) = serde_json::to_string(&ev) {
            push_event_json(json);
        }
    });
    let iroh = IrohManager::new(sdir, dname.clone(), ddir.clone(), iroh_cb);

    #[cfg(any(target_os = "windows", target_os = "linux"))]
    let rqs = {
        let rqs_cb: Arc<dyn Fn(RqsEvent) + Send + Sync> = Arc::new(|ev| {
            if let Ok(json) = serde_json::to_string(&ev) {
                push_event_json(json);
            }
        });
        QuickShareEngine::new(dname, ddir, rqs_cb)
    };

    *eng_guard = Some(EngineState {
        runtime,
        iroh,
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        rqs,
    });
    0
}

#[no_mangle]
pub unsafe extern "C" fn md_rust_update_config(
    device_name: *const c_char,
    download_dir: *const c_char,
) -> i32 {
    let dname = read_c_str(device_name).unwrap_or_else(|| "MaterialDrop".to_string());
    let ddir = PathBuf::from(read_c_str(download_dir).unwrap_or_else(|| ".".to_string()));
    if let Ok(mut guard) = ENGINE.lock() {
        if let Some(state) = guard.as_mut() {
            state.iroh.update_config(&dname, ddir.clone());
            #[cfg(any(target_os = "windows", target_os = "linux"))]
            state.rqs.update_config(&dname, ddir);
            return 0;
        }
    }
    -1
}

#[no_mangle]
pub extern "C" fn md_rust_poll_event() -> *mut c_char {
    if let Ok(mut q) = EVENT_QUEUE.lock() {
        if let Some(next) = q.pop_front() {
            return to_c_string(next);
        }
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn md_rust_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[no_mangle]
pub extern "C" fn md_rust_shutdown() {
    if let Ok(mut cb) = WAKE_CB.lock() {
        *cb = None;
    }
    if let Ok(mut guard) = ENGINE.lock() {
        if let Some(mut state) = guard.take() {
            #[cfg(any(target_os = "windows", target_os = "linux"))]
            state.rqs.stop();
            let handle = state.runtime.handle().clone();
            handle.block_on(async {
                state.iroh.stop().await;
            });
            drop(state);
        }
    }
}

#[no_mangle]
pub extern "C" fn md_iroh_start() -> i32 {
    let mut guard = match ENGINE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let Some(state) = guard.as_mut() else {
        return -1;
    };
    let handle = state.runtime.handle().clone();
    match state.runtime.block_on(state.iroh.start(handle)) {
        Ok(_) => 0,
        Err(e) => {
            if let Ok(json) = serde_json::to_string(&IrohEvent::TransferError {
                id: "iroh_start".to_string(),
                message: e.to_string(),
            }) {
                push_event_json(json);
            }
            -2
        }
    }
}

#[no_mangle]
pub extern "C" fn md_iroh_stop() -> i32 {
    if let Ok(mut guard) = ENGINE.lock() {
        if let Some(state) = guard.as_mut() {
            let rt = state.runtime.handle().clone();
            rt.block_on(state.iroh.stop());
            return 0;
        }
    }
    -1
}

#[no_mangle]
pub extern "C" fn md_iroh_get_ticket() -> *mut c_char {
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            return to_c_string(state.iroh.current_ticket());
        }
    }
    to_c_string(String::new())
}

#[no_mangle]
pub extern "C" fn md_iroh_get_node_id() -> *mut c_char {
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            return to_c_string(state.iroh.current_node_id());
        }
    }
    to_c_string(String::new())
}

#[no_mangle]
pub unsafe extern "C" fn md_iroh_send_files(
    transfer_id: *const c_char,
    ticket_or_link: *const c_char,
    files_json: *const c_char,
) -> i32 {
    let Some(tid) = read_c_str(transfer_id) else {
        return -1;
    };
    let Some(ticket) = read_c_str(ticket_or_link) else {
        return -1;
    };
    let Some(fjson) = read_c_str(files_json) else {
        return -1;
    };
    let Ok(files) = serde_json::from_str::<Vec<IrohFileSpec>>(&fjson) else {
        return -2;
    };
    let Ok(guard) = ENGINE.lock() else {
        return -1;
    };
    let Some(state) = guard.as_ref() else {
        return -1;
    };
    let handle = state.runtime.handle().clone();
    match state.iroh.send_files(&handle, tid, ticket, files) {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

#[no_mangle]
pub unsafe extern "C" fn md_iroh_respond_offer(offer_id: *const c_char, accept: i32) -> i32 {
    let Some(oid) = read_c_str(offer_id) else {
        return -1;
    };
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            return if state.iroh.respond_offer(&oid, accept != 0) {
                0
            } else {
                -2
            };
        }
    }
    -1
}

#[no_mangle]
pub unsafe extern "C" fn md_iroh_cancel_transfer(transfer_id: *const c_char) -> i32 {
    let Some(tid) = read_c_str(transfer_id) else {
        return -1;
    };
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            return if state.iroh.cancel_transfer(&tid) { 0 } else { -2 };
        }
    }
    -1
}

// --- Desktop Quick Share (`rquickshare_core`) FFI ---

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[no_mangle]
pub extern "C" fn md_rqs_start(visible: i32) -> i32 {
    let mut guard = match ENGINE.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    let Some(state) = guard.as_mut() else {
        return -1;
    };
    let handle = state.runtime.handle().clone();
    match state
        .runtime
        .block_on(state.rqs.start(handle, visible != 0))
    {
        Ok(port) => port as i32,
        Err(_) => -2,
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
#[no_mangle]
pub extern "C" fn md_rqs_start(_visible: i32) -> i32 {
    -1
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[no_mangle]
pub extern "C" fn md_rqs_stop() -> i32 {
    if let Ok(mut guard) = ENGINE.lock() {
        if let Some(state) = guard.as_mut() {
            state.rqs.stop();
            return 0;
        }
    }
    -1
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
#[no_mangle]
pub extern "C" fn md_rqs_stop() -> i32 {
    -1
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[no_mangle]
pub unsafe extern "C" fn md_rqs_send_files(
    transfer_id: *const c_char,
    ip: *const c_char,
    port: u16,
    files_json: *const c_char,
) -> i32 {
    let Some(tid) = read_c_str(transfer_id) else {
        return -1;
    };
    let Some(ip_str) = read_c_str(ip) else {
        return -1;
    };
    let Some(fjson) = read_c_str(files_json) else {
        return -1;
    };
    let Ok(files) = serde_json::from_str::<Vec<RqsOutboundFile>>(&fjson) else {
        return -2;
    };
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            let handle = state.runtime.handle().clone();
            state.rqs.send_files(&handle, tid, ip_str, port, files);
            return 0;
        }
    }
    -1
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
#[no_mangle]
pub unsafe extern "C" fn md_rqs_send_files(
    _transfer_id: *const c_char,
    _ip: *const c_char,
    _port: u16,
    _files_json: *const c_char,
) -> i32 {
    -1
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[no_mangle]
pub unsafe extern "C" fn md_rqs_respond_offer(offer_id: *const c_char, accept: i32) -> i32 {
    let Some(oid) = read_c_str(offer_id) else {
        return -1;
    };
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            return if state.rqs.respond_offer(&oid, accept != 0) {
                0
            } else {
                -2
            };
        }
    }
    -1
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
#[no_mangle]
pub unsafe extern "C" fn md_rqs_respond_offer(_offer_id: *const c_char, _accept: i32) -> i32 {
    -1
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[no_mangle]
pub unsafe extern "C" fn md_rqs_cancel_transfer(transfer_id: *const c_char) -> i32 {
    let Some(tid) = read_c_str(transfer_id) else {
        return -1;
    };
    if let Ok(guard) = ENGINE.lock() {
        if let Some(state) = guard.as_ref() {
            return if state.rqs.cancel_transfer(&tid) { 0 } else { -2 };
        }
    }
    -1
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
#[no_mangle]
pub unsafe extern "C" fn md_rqs_cancel_transfer(_transfer_id: *const c_char) -> i32 {
    -1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_queue_roundtrip() {
        push_event_json("{\"type\":\"test\"}".to_string());
        let ptr = md_rust_poll_event();
        assert!(!ptr.is_null());
        unsafe {
            let s = CStr::from_ptr(ptr).to_str().unwrap().to_string();
            md_rust_free_string(ptr);
            assert_eq!(s, "{\"type\":\"test\"}");
        }
    }
}
