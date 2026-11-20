//! Async TCP inbound receiver and outbound sender for Quick Share transfers.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyhow::{bail, Result};
use tokio::fs::File;
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use crate::crypto::{read_frame, run_client_handshake, run_server_handshake, write_frame};
use crate::mdns::{build_endpoint_info, parse_endpoint_info};
use crate::proto;
use crate::{RqsEvent, RqsOutboundFile};

pub type PendingResponses = Arc<Mutex<HashMap<String, oneshot::Sender<bool>>>>;
pub type ActiveCancellations = Arc<Mutex<HashMap<String, CancellationToken>>>;

pub async fn run_tcp_server(
    listener: TcpListener,
    device_name: Arc<Mutex<String>>,
    download_dir: Arc<Mutex<PathBuf>>,
    pending_offers: PendingResponses,
    cancellations: ActiveCancellations,
    events: Arc<dyn Fn(RqsEvent) + Send + Sync>,
    ctk: CancellationToken,
) {
    loop {
        tokio::select! {
            _ = ctk.cancelled() => break,
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, addr)) => {
                        let dname = device_name.clone();
                        let ddir = download_dir.clone();
                        let pending = pending_offers.clone();
                        let cancels = cancellations.clone();
                        let ev = events.clone();
                        let child_ctk = ctk.child_token();
                        tokio::spawn(async move {
                            let peer_ip = addr.ip().to_string();
                            if let Err(err) = handle_inbound(
                                stream,
                                &peer_ip,
                                dname,
                                ddir,
                                pending,
                                cancels,
                                ev.as_ref(),
                                child_ctk,
                            ).await {
                                ev(RqsEvent::TransferError {
                                    id: peer_ip,
                                    message: err.to_string(),
                                });
                            }
                        });
                    }
                    Err(_) => break,
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_inbound(
    mut stream: TcpStream,
    peer_ip: &str,
    device_name: Arc<Mutex<String>>,
    download_dir: Arc<Mutex<PathBuf>>,
    pending_offers: PendingResponses,
    cancellations: ActiveCancellations,
    events: &(dyn Fn(RqsEvent) + Send + Sync),
    ctk: CancellationToken,
) -> Result<()> {
    let conn_req = read_frame(&mut stream).await?;
    let sender_name = proto::parse_connection_request_endpoint_info(&conn_req)
        .and_then(|bytes| parse_endpoint_info(&bytes).0)
        .unwrap_or_else(|| format!("Quick Share ({peer_ip})"));

    let (keys, mut channel) = run_server_handshake(&mut stream).await?;
    let pin_code = keys.pin_code();

    // Paired ConnectionResponse plaintext frame exchange
    let _client_conn_resp = read_frame(&mut stream).await?;
    write_frame(&mut stream, &proto::build_offline_connection_response(proto::STATUS_ACCEPT)).await?;

    // Exchange PairedKeyEncryption & PairedKeyResult encrypted inside UKEY2 SecureMessage
    let pke = proto::build_paired_key_encryption(&[0u8; 32], &[0u8; 64]);
    let enc_pke = channel.encrypt(&pke)?;
    write_frame(
        &mut stream,
        &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc_pke),
    )
    .await?;

    let intro_files;
    loop {
        if ctk.is_cancelled() {
            bail!("Receiver stopped");
        }
        let raw = read_frame(&mut stream).await?;
        let proto::ParsedOfflineFrame::PayloadChunk(chunk) = proto::parse_offline_frame(&raw)? else {
            continue;
        };
        if chunk.payload_type != 1 {
            continue;
        }
        let plain = channel.decrypt(&chunk.data)?;
        match proto::parse_sharing_frame(&plain)? {
            proto::ParsedSharingFrame::PairedKeyEncryption => {
                let res_frame = proto::build_paired_key_result(3); // UNABLE
                let enc = channel.encrypt(&res_frame)?;
                write_frame(
                    &mut stream,
                    &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc),
                )
                .await?;
            }
            proto::ParsedSharingFrame::PairedKeyResult(_) => {}
            proto::ParsedSharingFrame::Introduction { files, .. } => {
                intro_files = files;
                break;
            }
            proto::ParsedSharingFrame::Cancel => {
                events(RqsEvent::IncomingCanceled {
                    id: peer_ip.to_string(),
                });
                return Ok(());
            }
            proto::ParsedSharingFrame::ConnectionResponse(_) | proto::ParsedSharingFrame::Other => {}
        }
    }

    if intro_files.is_empty() {
        let resp = proto::build_sharing_connection_response(proto::STATUS_REJECT);
        let enc = channel.encrypt(&resp)?;
        let _ = write_frame(
            &mut stream,
            &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc),
        )
        .await;
        return Ok(());
    }

    let offer_id = format!("rqs_{}", uuid::Uuid::new_v4());
    let total_bytes: u64 = intro_files.iter().map(|f| f.size.max(0) as u64).sum();
    let file_names: Vec<String> = intro_files.iter().map(|f| f.name.clone()).collect();
    let _local_name = device_name.lock().map(|g| g.clone()).unwrap_or_default();

    let (tx, rx) = oneshot::channel::<bool>();
    pending_offers
        .lock()
        .map_err(|_| anyhow::anyhow!("Offer lock poisoned"))?
        .insert(offer_id.clone(), tx);

    let transfer_ctk = ctk.child_token();
    cancellations
        .lock()
        .map_err(|_| anyhow::anyhow!("Cancel lock poisoned"))?
        .insert(offer_id.clone(), transfer_ctk.clone());

    events(RqsEvent::IncomingOffer {
        id: offer_id.clone(),
        sender_name: sender_name.clone(),
        sender_ip: peer_ip.to_string(),
        pin_code: pin_code.clone(),
        file_names,
        total_bytes,
    });

    let accepted = tokio::select! {
        _ = transfer_ctk.cancelled() => false,
        res = rx => res.unwrap_or(false),
    };
    if let Ok(mut map) = pending_offers.lock() {
        map.remove(&offer_id);
    }

    let resp_status = if accepted {
        proto::STATUS_ACCEPT
    } else {
        proto::STATUS_REJECT
    };
    let resp = proto::build_sharing_connection_response(resp_status);
    let enc_resp = channel.encrypt(&resp)?;
    write_frame(
        &mut stream,
        &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc_resp),
    )
    .await?;

    if !accepted {
        if let Ok(mut map) = cancellations.lock() {
            map.remove(&offer_id);
        }
        events(RqsEvent::IncomingCanceled { id: offer_id });
        return Ok(());
    }

    let base_dir = download_dir
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| PathBuf::from("."));
    std::fs::create_dir_all(&base_dir)?;

    struct OpenTarget {
        name: String,
        final_path: PathBuf,
        part_path: PathBuf,
        file: std::fs::File,
        received: u64,
    }

    let mut targets: HashMap<i64, OpenTarget> = HashMap::new();
    for f in &intro_files {
        let safe_name = sanitize_file_name(&f.name);
        let final_path = unique_dest_path(&base_dir, &safe_name);
        let part_path = PathBuf::from(format!("{}.mdpart", final_path.to_string_lossy()));
        let file = std::fs::File::create(&part_path)?;
        targets.insert(
            f.payload_id,
            OpenTarget {
                name: safe_name,
                final_path,
                part_path,
                file,
                received: 0,
            },
        );
    }

    let started = Instant::now();
    let mut total_received = 0u64;
    let mut completed_paths = Vec::new();
    let mut remaining = targets.len();

    while remaining > 0 {
        if transfer_ctk.is_cancelled() {
            if let Ok(mut map) = cancellations.lock() {
                map.remove(&offer_id);
            }
            for (_, t) in targets {
                drop(t.file);
                let _ = std::fs::remove_file(&t.part_path);
            }
            events(RqsEvent::IncomingCanceled { id: offer_id });
            return Ok(());
        }
        let raw = read_frame(&mut stream).await?;
        let parsed = proto::parse_offline_frame(&raw)?;
        match parsed {
            proto::ParsedOfflineFrame::Disconnection => break,
            proto::ParsedOfflineFrame::KeepAlive | proto::ParsedOfflineFrame::Other => continue,
            proto::ParsedOfflineFrame::PayloadChunk(chunk) => {
                if chunk.payload_type == 1 {
                    if let Ok(plain) = channel.decrypt(&chunk.data) {
                        if let Ok(proto::ParsedSharingFrame::Cancel) = proto::parse_sharing_frame(&plain) {
                            events(RqsEvent::IncomingCanceled { id: offer_id });
                            return Ok(());
                        }
                    }
                    continue;
                }
                if let Some(target) = targets.get_mut(&chunk.payload_id) {
                    if !chunk.data.is_empty() {
                        target.file.write_all(&chunk.data)?;
                        target.received += chunk.data.len() as u64;
                        total_received += chunk.data.len() as u64;
                        let elapsed = started.elapsed().as_secs_f64().max(0.05);
                        events(RqsEvent::IncomingProgress {
                            id: offer_id.clone(),
                            file_name: target.name.clone(),
                            received: total_received,
                            total: total_bytes.max(total_received),
                            speed_bps: (total_received as f64) / elapsed,
                        });
                    }
                    if (chunk.flags & 1) != 0 {
                        remaining = remaining.saturating_sub(1);
                    }
                }
            }
        }
    }

    for (_, target) in targets {
        target.file.sync_all().ok();
        drop(target.file);
        std::fs::rename(&target.part_path, &target.final_path)?;
        completed_paths.push(target.final_path.to_string_lossy().into_owned());
    }
    if let Ok(mut map) = cancellations.lock() {
        map.remove(&offer_id);
    }

    events(RqsEvent::IncomingCompleted {
        id: offer_id,
        saved_paths: completed_paths,
    });
    Ok(())
}

pub async fn send_files_outbound(
    transfer_id: String,
    ip: String,
    port: u16,
    local_device_name: String,
    files: Vec<RqsOutboundFile>,
    cancellations: ActiveCancellations,
    events: Arc<dyn Fn(RqsEvent) + Send + Sync>,
) -> Result<()> {
    let ctk = CancellationToken::new();
    cancellations
        .lock()
        .map_err(|_| anyhow::anyhow!("Cancel lock poisoned"))?
        .insert(transfer_id.clone(), ctk.clone());

    let res = send_files_inner(
        &transfer_id,
        &ip,
        port,
        &local_device_name,
        &files,
        ctk,
        events.as_ref(),
    )
    .await;

    if let Ok(mut map) = cancellations.lock() {
        map.remove(&transfer_id);
    }
    if let Err(err) = res {
        events(RqsEvent::TransferError {
            id: transfer_id,
            message: err.to_string(),
        });
    }
    Ok(())
}

async fn send_files_inner(
    transfer_id: &str,
    ip: &str,
    port: u16,
    local_device_name: &str,
    files: &[RqsOutboundFile],
    ctk: CancellationToken,
    events: &(dyn Fn(RqsEvent) + Send + Sync),
) -> Result<()> {
    let mut stream = TcpStream::connect(format!("{ip}:{port}")).await?;
    stream.set_nodelay(true)?;

    let ep_id = crate::mdns::generate_endpoint_id();
    let ep_str = String::from_utf8_lossy(&ep_id).into_owned();
    let ep_info = build_endpoint_info(local_device_name, 3);
    write_frame(&mut stream, &proto::build_connection_request(&ep_str, &ep_info)).await?;

    let (keys, mut channel) = run_client_handshake(&mut stream).await?;
    write_frame(
        &mut stream,
        &proto::build_offline_connection_response(proto::STATUS_ACCEPT),
    )
    .await?;
    let _server_resp = read_frame(&mut stream).await?;

    let pke = proto::build_paired_key_encryption(&[0u8; 32], &[0u8; 64]);
    let enc_pke = channel.encrypt(&pke)?;
    write_frame(
        &mut stream,
        &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc_pke),
    )
    .await?;

    let mut metas = Vec::with_capacity(files.len());
    let mut total_bytes = 0u64;
    for f in files {
        let meta = std::fs::metadata(&f.path)?;
        let size = meta.len() as i64;
        total_bytes += meta.len();
        let pid = rand::random::<i64>().abs().max(1);
        let mtype = if f.mime_type.starts_with("image/") {
            1
        } else if f.mime_type.starts_with("video/") {
            2
        } else if f.mime_type.starts_with("audio/") {
            4
        } else {
            0
        };
        metas.push(proto::SharingFileMeta {
            payload_id: pid,
            name: f.name.clone(),
            size,
            mime_type: f.mime_type.clone(),
            meta_type: mtype,
        });
    }

    let pkr = proto::build_paired_key_result(3);
    let enc_pkr = channel.encrypt(&pkr)?;
    write_frame(
        &mut stream,
        &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc_pkr),
    )
    .await?;

    let intro = proto::build_introduction_frame(&metas);
    let enc_intro = channel.encrypt(&intro)?;
    write_frame(
        &mut stream,
        &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &enc_intro),
    )
    .await?;

    events(RqsEvent::OutgoingPin {
        id: transfer_id.to_string(),
        pin_code: keys.pin_code(),
    });

    // Wait for ConnectionResponse ACCEPT / REJECT
    loop {
        if ctk.is_cancelled() {
            let cancel = channel.encrypt(&proto::build_sharing_cancel())?;
            let _ = write_frame(
                &mut stream,
                &proto::build_payload_transfer_bytes(rand::random::<i64>().abs(), &cancel),
            )
            .await;
            bail!("Canceled by user");
        }
        let raw = read_frame(&mut stream).await?;
        let proto::ParsedOfflineFrame::PayloadChunk(chunk) = proto::parse_offline_frame(&raw)? else {
            continue;
        };
        if chunk.payload_type != 1 {
            continue;
        }
        let plain = channel.decrypt(&chunk.data)?;
        if let Ok(proto::ParsedSharingFrame::ConnectionResponse(status)) =
            proto::parse_sharing_frame(&plain)
        {
            if status != proto::STATUS_ACCEPT {
                bail!("Declined by receiver");
            }
            break;
        }
    }

    let started = Instant::now();
    let mut total_sent = 0u64;
    let mut buf = vec![0u8; 64 * 1024];

    for (item, meta) in files.iter().zip(metas.iter()) {
        let mut f = File::open(&item.path).await?;
        let mut offset = 0i64;
        loop {
            if ctk.is_cancelled() {
                bail!("Canceled by user");
            }
            let n = f.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            let frame = proto::build_payload_chunk(
                meta.payload_id,
                2,
                meta.size,
                offset,
                &buf[..n],
                0,
            );
            write_frame(&mut stream, &frame).await?;
            offset += n as i64;
            total_sent += n as u64;
            let elapsed = started.elapsed().as_secs_f64().max(0.05);
            events(RqsEvent::OutgoingProgress {
                id: transfer_id.to_string(),
                file_name: meta.name.clone(),
                sent: total_sent,
                total: total_bytes.max(total_sent),
                speed_bps: (total_sent as f64) / elapsed,
            });
        }
        let end_frame = proto::build_payload_chunk(meta.payload_id, 2, meta.size, offset, &[], 1);
        write_frame(&mut stream, &end_frame).await?;
    }

    events(RqsEvent::OutgoingCompleted {
        id: transfer_id.to_string(),
    });
    Ok(())
}

fn sanitize_file_name(name: &str) -> String {
    let base = Path::new(name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("file");
    let clean: String = base
        .chars()
        .map(|c| if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') { '_' } else { c })
        .collect();
    if clean.is_empty() {
        "file".to_string()
    } else {
        clean
    }
}

fn unique_dest_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
    for i in 1..10000 {
        let next = if ext.is_empty() {
            dir.join(format!("{stem} ({i})"))
        } else {
            dir.join(format!("{stem} ({i}).{ext}"))
        };
        if !next.exists() {
            return next;
        }
    }
    candidate
}
