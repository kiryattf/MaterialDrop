//! Iroh QUIC P2P endpoint manager and streaming file/folder transfer implementation.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use iroh::endpoint::{presets, Connection};
use iroh::{Endpoint, EndpointAddr, RelayMode, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use iroh_tickets::Ticket;
use serde::{Deserialize, Serialize};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

pub const MD_IROH_ALPN: &[u8] = b"/materialdrop/p2p/1";
const CHUNK_SIZE: usize = 64 * 1024;
const MAX_CONTROL_JSON: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IrohFileSpec {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub mime_type: String,
    pub relative_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ControlFileEntry {
    name: String,
    size: u64,
    mime_type: String,
    relative_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind")]
enum ControlFrame {
    #[serde(rename = "offer")]
    Offer {
        sender_name: String,
        files: Vec<ControlFileEntry>,
        total_bytes: u64,
    },
    #[serde(rename = "response")]
    Response { accepted: bool, reason: Option<String> },
    #[serde(rename = "complete_ack")]
    CompleteAck { saved_count: usize },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IrohEvent {
    #[serde(rename = "iroh_ready")]
    Ready {
        node_id: String,
        ticket: String,
        deep_link: String,
    },
    #[serde(rename = "iroh_incoming_offer")]
    IncomingOffer {
        id: String,
        sender_name: String,
        sender_node_id: String,
        files: Vec<ControlFileEntrySerializable>,
        total_bytes: u64,
    },
    #[serde(rename = "iroh_incoming_progress")]
    IncomingProgress {
        id: String,
        file_name: String,
        received: u64,
        total: u64,
        speed_bps: f64,
    },
    #[serde(rename = "iroh_incoming_completed")]
    IncomingCompleted {
        id: String,
        saved_paths: Vec<String>,
    },
    #[serde(rename = "iroh_incoming_canceled")]
    IncomingCanceled { id: String },
    #[serde(rename = "iroh_outgoing_progress")]
    OutgoingProgress {
        id: String,
        file_name: String,
        sent: u64,
        total: u64,
        speed_bps: f64,
    },
    #[serde(rename = "iroh_outgoing_completed")]
    OutgoingCompleted { id: String },
    #[serde(rename = "iroh_error")]
    TransferError { id: String, message: String },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ControlFileEntrySerializable {
    pub name: String,
    pub size: u64,
    pub mime_type: String,
    pub relative_path: Option<String>,
}

impl From<ControlFileEntry> for ControlFileEntrySerializable {
    fn from(v: ControlFileEntry) -> Self {
        Self {
            name: v.name,
            size: v.size,
            mime_type: v.mime_type,
            relative_path: v.relative_path,
        }
    }
}

pub fn build_deep_link(ticket: &str, device_name: &str, node_id: &str) -> String {
    format!(
        "materialdrop://iroh/{}?name={}&node={}",
        urlencoding::encode(ticket),
        urlencoding::encode(device_name),
        urlencoding::encode(node_id)
    )
}

/// Extracts an `EndpointTicket` from either a `materialdrop://iroh/...` deep link or a raw ticket string.
pub fn parse_ticket_or_link(raw: &str) -> Result<EndpointTicket> {
    let trimmed = raw.trim();
    let ticket_candidate = if let Some(rest) = trimmed.strip_prefix("materialdrop://iroh/") {
        let before_q = rest.split('?').next().unwrap_or(rest).trim_matches('/');
        urlencoding::decode(before_q)
            .map(|c| c.into_owned())
            .unwrap_or_else(|_| before_q.to_string())
    } else if let Some(rest) = trimmed.strip_prefix("materialdrop://") {
        let before_q = rest.split('?').next().unwrap_or(rest).trim_matches('/');
        let path_part = before_q.strip_prefix("iroh/").unwrap_or(before_q);
        urlencoding::decode(path_part)
            .map(|c| c.into_owned())
            .unwrap_or_else(|_| path_part.to_string())
    } else {
        trimmed.to_string()
    };

    EndpointTicket::from_str(ticket_candidate.trim())
        .map_err(|e| anyhow::anyhow!("Invalid iroh ticket: {e}"))
}

pub struct IrohManager {
    state_dir: PathBuf,
    device_name: Arc<Mutex<String>>,
    download_dir: Arc<Mutex<PathBuf>>,
    endpoint: Option<Endpoint>,
    node_id: Arc<Mutex<String>>,
    current_ticket: Arc<Mutex<String>>,
    pending_offers: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>,
    cancellations: Arc<Mutex<HashMap<String, CancellationToken>>>,
    ctk: Option<CancellationToken>,
    events: Arc<dyn Fn(IrohEvent) + Send + Sync>,
}

impl IrohManager {
    pub fn new(
        state_dir: PathBuf,
        device_name: String,
        download_dir: PathBuf,
        events: Arc<dyn Fn(IrohEvent) + Send + Sync>,
    ) -> Self {
        Self {
            state_dir,
            device_name: Arc::new(Mutex::new(device_name)),
            download_dir: Arc::new(Mutex::new(download_dir)),
            endpoint: None,
            node_id: Arc::new(Mutex::new(String::new())),
            current_ticket: Arc::new(Mutex::new(String::new())),
            pending_offers: Arc::default(),
            cancellations: Arc::default(),
            ctk: None,
            events,
        }
    }

    pub fn update_config(&self, device_name: &str, download_dir: PathBuf) {
        if let Ok(mut dn) = self.device_name.lock() {
            *dn = device_name.to_string();
        }
        if let Ok(mut dd) = self.download_dir.lock() {
            *dd = download_dir;
        }
    }

    pub fn current_ticket(&self) -> String {
        self.current_ticket
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    pub fn current_node_id(&self) -> String {
        self.node_id.lock().map(|g| g.clone()).unwrap_or_default()
    }

    pub async fn start(&mut self, handle: tokio::runtime::Handle) -> Result<()> {
        self.stop().await;
        let secret_key = load_or_create_secret_key(&self.state_dir)?;
        let endpoint = Endpoint::builder(presets::N0)
            .secret_key(secret_key)
            .alpns(vec![MD_IROH_ALPN.to_vec()])
            .relay_mode(RelayMode::Default)
            .bind()
            .await
            .context("Failed to bind iroh Endpoint")?;

        endpoint.online().await;

        let node_id_str = endpoint.id().to_string();
        let addr = endpoint.addr();
        let ticket_str = EndpointTicket::new(addr).encode_string();

        if let Ok(mut g) = self.node_id.lock() {
            *g = node_id_str.clone();
        }
        if let Ok(mut g) = self.current_ticket.lock() {
            *g = ticket_str.clone();
        }

        let dev_name = self
            .device_name
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| "MaterialDrop".to_string());
        let deep_link = build_deep_link(&ticket_str, &dev_name, &node_id_str);

        (self.events)(IrohEvent::Ready {
            node_id: node_id_str,
            ticket: ticket_str,
            deep_link,
        });

        let ctk = CancellationToken::new();
        self.ctk = Some(ctk.clone());
        self.endpoint = Some(endpoint.clone());

        // Accept loop for incoming QUIC transfers
        let accept_ep = endpoint.clone();
        let ddir = self.download_dir.clone();
        let pending = self.pending_offers.clone();
        let cancels = self.cancellations.clone();
        let ev = self.events.clone();
        let accept_ctk = ctk.clone();

        handle.spawn(async move {
            loop {
                tokio::select! {
                    _ = accept_ctk.cancelled() => break,
                    incoming_opt = accept_ep.accept() => {
                        let Some(incoming) = incoming_opt else { break };
                        let mut accepting = match incoming.accept() {
                            Ok(a) => a,
                            Err(_) => continue,
                        };
                        let alpn = match accepting.alpn().await {
                            Ok(a) => a,
                            Err(_) => continue,
                        };
                        if alpn.as_slice() != MD_IROH_ALPN {
                            continue;
                        }
                        let conn = match accepting.await {
                            Ok(c) => c,
                            Err(_) => continue,
                        };
                        let ddir_c = ddir.clone();
                        let pending_c = pending.clone();
                        let cancels_c = cancels.clone();
                        let ev_c = ev.clone();
                        let conn_ctk = accept_ctk.child_token();
                        tokio::spawn(async move {
                            let peer_id = conn.remote_id().to_string();
                            if let Err(err) = handle_incoming_conn(
                                conn,
                                ddir_c,
                                pending_c,
                                cancels_c,
                                ev_c.as_ref(),
                                conn_ctk,
                            )
                            .await
                            {
                                ev_c(IrohEvent::TransferError {
                                    id: peer_id,
                                    message: err.to_string(),
                                });
                            }
                        });
                    }
                }
            }
        });

        Ok(())
    }

    pub fn respond_offer(&self, offer_id: &str, accept: bool) -> bool {
        if let Ok(mut map) = self.pending_offers.lock() {
            if let Some(tx) = map.remove(offer_id) {
                return tx.send(accept).is_ok();
            }
        }
        false
    }

    pub fn cancel_transfer(&self, transfer_id: &str) -> bool {
        if let Ok(map) = self.cancellations.lock() {
            if let Some(ctk) = map.get(transfer_id) {
                ctk.cancel();
                return true;
            }
        }
        false
    }

    pub fn send_files(
        &self,
        handle: &tokio::runtime::Handle,
        transfer_id: String,
        ticket_or_link: String,
        files: Vec<IrohFileSpec>,
    ) -> Result<()> {
        let Some(endpoint) = self.endpoint.clone() else {
            bail!("Iroh endpoint is not started");
        };
        let ticket = parse_ticket_or_link(&ticket_or_link)?;
        let addr: EndpointAddr = ticket.into();
        let sender_name = self
            .device_name
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| "MaterialDrop".to_string());

        let ctk = CancellationToken::new();
        if let Ok(mut map) = self.cancellations.lock() {
            map.insert(transfer_id.clone(), ctk.clone());
        }
        let cancels = self.cancellations.clone();
        let ev = self.events.clone();

        handle.spawn(async move {
            let res = send_files_over_iroh(
                &endpoint,
                addr,
                &transfer_id,
                &sender_name,
                &files,
                ctk,
                ev.as_ref(),
            )
            .await;
            if let Ok(mut map) = cancels.lock() {
                map.remove(&transfer_id);
            }
            if let Err(err) = res {
                ev(IrohEvent::TransferError {
                    id: transfer_id,
                    message: err.to_string(),
                });
            }
        });

        Ok(())
    }

    pub async fn stop(&mut self) {
        if let Some(ctk) = self.ctk.take() {
            ctk.cancel();
        }
        if let Some(ep) = self.endpoint.take() {
            ep.close().await;
        }
    }
}

fn load_or_create_secret_key(state_dir: &Path) -> Result<SecretKey> {
    std::fs::create_dir_all(state_dir).ok();
    let key_file = state_dir.join("iroh_node.key");
    if let Ok(bytes) = std::fs::read(&key_file) {
        if bytes.len() == 32 {
            let arr: [u8; 32] = bytes.try_into().unwrap();
            return Ok(SecretKey::from_bytes(&arr));
        }
    }
    let key = SecretKey::generate();
    let _ = std::fs::write(&key_file, key.to_bytes());
    Ok(key)
}

async fn write_control_frame<W: AsyncWriteExt + Unpin>(
    send: &mut W,
    frame: &ControlFrame,
) -> Result<()> {
    let json = serde_json::to_vec(frame)?;
    send.write_u32(json.len() as u32).await?;
    send.write_all(&json).await?;
    send.flush().await?;
    Ok(())
}

async fn read_control_frame<R: AsyncReadExt + Unpin>(recv: &mut R) -> Result<ControlFrame> {
    let len = recv.read_u32().await? as usize;
    if len == 0 || len > MAX_CONTROL_JSON {
        bail!("Invalid iroh control frame length: {len}");
    }
    let mut buf = vec![0u8; len];
    recv.read_exact(&mut buf).await?;
    Ok(serde_json::from_slice(&buf)?)
}

async fn handle_incoming_conn(
    conn: Connection,
    download_dir: Arc<Mutex<PathBuf>>,
    pending_offers: Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>,
    cancellations: Arc<Mutex<HashMap<String, CancellationToken>>>,
    events: &(dyn Fn(IrohEvent) + Send + Sync),
    ctk: CancellationToken,
) -> Result<()> {
    let peer_node_id = conn.remote_id().to_string();
    let (mut send, mut recv) = conn.accept_bi().await?;

    let ControlFrame::Offer {
        sender_name,
        files,
        total_bytes,
    } = read_control_frame(&mut recv).await?
    else {
        bail!("Expected initial offer frame");
    };

    if files.is_empty() {
        write_control_frame(
            &mut send,
            &ControlFrame::Response {
                accepted: false,
                reason: Some("Empty offer".to_string()),
            },
        )
        .await?;
        let _ = send.finish();
        return Ok(());
    }

    let offer_id = format!("iroh_{}_{}", peer_node_id.chars().take(8).collect::<String>(), rand::random::<u32>());
    let (tx, rx) = oneshot::channel::<bool>();
    if let Ok(mut map) = pending_offers.lock() {
        map.insert(offer_id.clone(), tx);
    }

    let transfer_ctk = ctk.child_token();
    if let Ok(mut map) = cancellations.lock() {
        map.insert(offer_id.clone(), transfer_ctk.clone());
    }

    events(IrohEvent::IncomingOffer {
        id: offer_id.clone(),
        sender_name,
        sender_node_id: peer_node_id,
        files: files.iter().cloned().map(Into::into).collect(),
        total_bytes,
    });

    let accepted = tokio::select! {
        _ = transfer_ctk.cancelled() => false,
        res = rx => res.unwrap_or(false),
    };
    if let Ok(mut map) = pending_offers.lock() {
        map.remove(&offer_id);
    }

    write_control_frame(
        &mut send,
        &ControlFrame::Response {
            accepted,
            reason: if accepted { None } else { Some("Declined".to_string()) },
        },
    )
    .await?;

    if !accepted {
        let _ = send.finish();
        if let Ok(mut map) = cancellations.lock() {
            map.remove(&offer_id);
        }
        events(IrohEvent::IncomingCanceled { id: offer_id });
        return Ok(());
    }

    let base_dir = download_dir
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| PathBuf::from("."));
    std::fs::create_dir_all(&base_dir)?;

    let started = Instant::now();
    let mut total_received = 0u64;
    let mut saved_paths = Vec::with_capacity(files.len());
    let mut buf = vec![0u8; CHUNK_SIZE];

    for entry in &files {
        let dest_path = resolve_safe_dest(&base_dir, &entry.name, entry.relative_path.as_deref())?;
        if let Some(parent) = dest_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let part_path = PathBuf::from(format!("{}.mdpart", dest_path.to_string_lossy()));
        let mut out_file = File::create(&part_path).await?;
        let mut file_left = entry.size;

        while file_left > 0 {
            if transfer_ctk.is_cancelled() {
                drop(out_file);
                let _ = std::fs::remove_file(&part_path);
                let _ = send.finish();
                events(IrohEvent::IncomingCanceled { id: offer_id });
                return Ok(());
            }
            let want = (file_left as usize).min(buf.len());
            let n = recv.read(&mut buf[..want]).await?;
            let Some(n) = n else {
                drop(out_file);
                let _ = std::fs::remove_file(&part_path);
                bail!("Unexpected EOF while receiving {}", entry.name);
            };
            if n == 0 {
                bail!("Zero-byte EOF while receiving {}", entry.name);
            }
            out_file.write_all(&buf[..n]).await?;
            file_left -= n as u64;
            total_received += n as u64;

            let elapsed = started.elapsed().as_secs_f64().max(0.05);
            events(IrohEvent::IncomingProgress {
                id: offer_id.clone(),
                file_name: entry.name.clone(),
                received: total_received,
                total: total_bytes.max(total_received),
                speed_bps: (total_received as f64) / elapsed,
            });
        }
        out_file.flush().await?;
        drop(out_file);
        std::fs::rename(&part_path, &dest_path)?;
        saved_paths.push(dest_path.to_string_lossy().into_owned());
    }

    write_control_frame(
        &mut send,
        &ControlFrame::CompleteAck {
            saved_count: saved_paths.len(),
        },
    )
    .await?;
    let _ = send.finish();

    if let Ok(mut map) = cancellations.lock() {
        map.remove(&offer_id);
    }

    events(IrohEvent::IncomingCompleted {
        id: offer_id,
        saved_paths,
    });
    Ok(())
}

async fn send_files_over_iroh(
    endpoint: &Endpoint,
    addr: EndpointAddr,
    transfer_id: &str,
    sender_name: &str,
    files: &[IrohFileSpec],
    ctk: CancellationToken,
    events: &(dyn Fn(IrohEvent) + Send + Sync),
) -> Result<()> {
    let conn = tokio::select! {
        _ = ctk.cancelled() => bail!("Canceled before connect"),
        res = endpoint.connect(addr, MD_IROH_ALPN) => res.context("Failed to connect to iroh peer")?,
    };

    let (mut send, mut recv) = conn.open_bi().await?;
    let mut entries = Vec::with_capacity(files.len());
    let mut total_bytes = 0u64;
    for f in files {
        let sz = std::fs::metadata(&f.path).map(|m| m.len()).unwrap_or(f.size);
        total_bytes += sz;
        entries.push(ControlFileEntry {
            name: f.name.clone(),
            size: sz,
            mime_type: f.mime_type.clone(),
            relative_path: f.relative_path.clone(),
        });
    }

    write_control_frame(
        &mut send,
        &ControlFrame::Offer {
            sender_name: sender_name.to_string(),
            files: entries.clone(),
            total_bytes,
        },
    )
    .await?;

    let resp = tokio::select! {
        _ = ctk.cancelled() => bail!("Canceled while awaiting acceptance"),
        res = read_control_frame(&mut recv) => res?,
    };
    match resp {
        ControlFrame::Response { accepted: true, .. } => {}
        ControlFrame::Response {
            accepted: false,
            reason,
        } => bail!("{}", reason.unwrap_or_else(|| "Declined by receiver".to_string())),
        _ => bail!("Unexpected response frame"),
    }

    let started = Instant::now();
    let mut total_sent = 0u64;
    let mut buf = vec![0u8; CHUNK_SIZE];

    for (spec, entry) in files.iter().zip(entries.iter()) {
        let mut f = File::open(&spec.path).await?;
        let mut left = entry.size;
        while left > 0 {
            if ctk.is_cancelled() {
                bail!("Canceled by user");
            }
            let want = (left as usize).min(buf.len());
            let n = f.read(&mut buf[..want]).await?;
            if n == 0 {
                bail!("Unexpected EOF reading {}", spec.path);
            }
            send.write_all(&buf[..n]).await?;
            left -= n as u64;
            total_sent += n as u64;

            let elapsed = started.elapsed().as_secs_f64().max(0.05);
            events(IrohEvent::OutgoingProgress {
                id: transfer_id.to_string(),
                file_name: entry.name.clone(),
                sent: total_sent,
                total: total_bytes.max(total_sent),
                speed_bps: (total_sent as f64) / elapsed,
            });
        }
    }
    send.finish()?;

    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        read_control_frame(&mut recv),
    )
    .await;

    events(IrohEvent::OutgoingCompleted {
        id: transfer_id.to_string(),
    });
    Ok(())
}

fn sanitize_component(raw: &str) -> String {
    raw.chars()
        .map(|c| {
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') {
                '_'
            } else {
                c
            }
        })
        .collect()
}

fn resolve_safe_dest(
    base_dir: &Path,
    file_name: &str,
    relative_path: Option<&str>,
) -> Result<PathBuf> {
    let mut rel_parts = Vec::new();
    if let Some(rel) = relative_path {
        let normalized = rel.replace('\\', "/");
        for part in normalized.split('/') {
            let trimmed = part.trim();
            if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
                continue;
            }
            rel_parts.push(sanitize_component(trimmed));
        }
    }

    let mut path = base_dir.to_path_buf();
    if rel_parts.is_empty() {
        let safe_name = sanitize_component(
            Path::new(file_name)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("file"),
        );
        path.push(if safe_name.is_empty() { "file" } else { &safe_name });
    } else {
        for p in rel_parts {
            path.push(p);
        }
    }

    if !path.exists() {
        return Ok(path);
    }

    let parent = path.parent().unwrap_or(base_dir);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
    for i in 1..10000 {
        let candidate = if ext.is_empty() {
            parent.join(format!("{stem} ({i})"))
        } else {
            parent.join(format!("{stem} ({i}).{ext}"))
        };
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::{EndpointAddr, SecretKey, TransportAddr};
    use std::net::{Ipv4Addr, SocketAddr};

    #[test]
    fn parse_deep_link_and_raw_ticket_roundtrip() {
        let pk = SecretKey::from_bytes(&[7u8; 32]).public();
        let addr = EndpointAddr::from_parts(
            pk,
            [TransportAddr::Ip(SocketAddr::from((Ipv4Addr::LOCALHOST, 4444)))],
        );
        let ticket = EndpointTicket::new(addr);
        let raw_ticket = ticket.encode_string();

        let deep_link = build_deep_link(&raw_ticket, "My Laptop", &pk.to_string());
        assert!(deep_link.starts_with("materialdrop://iroh/endpoint"));

        let parsed_from_link = parse_ticket_or_link(&deep_link).unwrap();
        assert_eq!(parsed_from_link.encode_string(), raw_ticket);

        let parsed_from_raw = parse_ticket_or_link(&raw_ticket).unwrap();
        assert_eq!(parsed_from_raw.encode_string(), raw_ticket);
    }
}
