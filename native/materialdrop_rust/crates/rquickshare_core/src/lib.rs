//! Cross-platform pure Rust Quick Share engine (`rquickshare_core`).

pub mod crypto;
pub mod mdns;
pub mod proto;
pub mod transfer;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::mdns::{generate_endpoint_id, DiscoveredQuickSharePeer, MdnsHandle};
use crate::transfer::{ActiveCancellations, PendingResponses};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RqsOutboundFile {
    pub path: String,
    pub name: String,
    pub mime_type: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum RqsEvent {
    #[serde(rename = "rqs_ready")]
    Ready { port: u16 },
    #[serde(rename = "rqs_peer_found")]
    PeerFound { peer: DiscoveredQuickSharePeer },
    #[serde(rename = "rqs_peer_lost")]
    PeerLost { fullname: String },
    #[serde(rename = "rqs_incoming_offer")]
    IncomingOffer {
        id: String,
        sender_name: String,
        sender_ip: String,
        pin_code: String,
        file_names: Vec<String>,
        total_bytes: u64,
    },
    #[serde(rename = "rqs_incoming_progress")]
    IncomingProgress {
        id: String,
        file_name: String,
        received: u64,
        total: u64,
        speed_bps: f64,
    },
    #[serde(rename = "rqs_incoming_completed")]
    IncomingCompleted {
        id: String,
        saved_paths: Vec<String>,
    },
    #[serde(rename = "rqs_incoming_canceled")]
    IncomingCanceled { id: String },
    #[serde(rename = "rqs_outgoing_pin")]
    OutgoingPin { id: String, pin_code: String },
    #[serde(rename = "rqs_outgoing_progress")]
    OutgoingProgress {
        id: String,
        file_name: String,
        sent: u64,
        total: u64,
        speed_bps: f64,
    },
    #[serde(rename = "rqs_outgoing_completed")]
    OutgoingCompleted { id: String },
    #[serde(rename = "rqs_error")]
    TransferError { id: String, message: String },
}

pub struct QuickShareEngine {
    device_name: Arc<Mutex<String>>,
    download_dir: Arc<Mutex<PathBuf>>,
    pending_offers: PendingResponses,
    cancellations: ActiveCancellations,
    mdns: Option<MdnsHandle>,
    ctk: Option<CancellationToken>,
    events: Arc<dyn Fn(RqsEvent) + Send + Sync>,
    bound_port: u16,
}

impl QuickShareEngine {
    pub fn new(
        device_name: String,
        download_dir: PathBuf,
        events: Arc<dyn Fn(RqsEvent) + Send + Sync>,
    ) -> Self {
        Self {
            device_name: Arc::new(Mutex::new(device_name)),
            download_dir: Arc::new(Mutex::new(download_dir)),
            pending_offers: Arc::default(),
            cancellations: Arc::default(),
            mdns: None,
            ctk: None,
            events,
            bound_port: 0,
        }
    }

    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    pub fn update_config(&self, device_name: &str, download_dir: PathBuf) {
        if let Ok(mut dn) = self.device_name.lock() {
            *dn = device_name.to_string();
        }
        if let Ok(mut dd) = self.download_dir.lock() {
            *dd = download_dir;
        }
    }

    pub async fn start(&mut self, handle: tokio::runtime::Handle, visible: bool) -> Result<u16> {
        self.stop();
        let listener = TcpListener::bind("0.0.0.0:0").await?;
        let port = listener.local_addr()?.port();
        self.bound_port = port;

        let ctk = CancellationToken::new();
        self.ctk = Some(ctk.clone());

        let (found_tx, mut found_rx) = mpsc::unbounded_channel();
        let (lost_tx, mut lost_rx) = mpsc::unbounded_channel();

        let dname = self
            .device_name
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| "MaterialDrop".to_string());
        let ep_id = generate_endpoint_id();
        let mdns_handle = MdnsHandle::start(
            ep_id,
            &dname,
            port,
            visible,
            ctk.clone(),
            found_tx,
            lost_tx,
        )?;
        self.mdns = Some(mdns_handle);

        let ev_peers = self.events.clone();
        let ctk_peers = ctk.clone();
        handle.spawn(async move {
            loop {
                tokio::select! {
                    _ = ctk_peers.cancelled() => break,
                    Some(peer) = found_rx.recv() => {
                        ev_peers(RqsEvent::PeerFound { peer });
                    }
                    Some(fullname) = lost_rx.recv() => {
                        ev_peers(RqsEvent::PeerLost { fullname });
                    }
                }
            }
        });

        let server_dname = self.device_name.clone();
        let server_ddir = self.download_dir.clone();
        let server_pending = self.pending_offers.clone();
        let server_cancels = self.cancellations.clone();
        let server_ev = self.events.clone();
        let server_ctk = ctk.clone();
        handle.spawn(async move {
            transfer::run_tcp_server(
                listener,
                server_dname,
                server_ddir,
                server_pending,
                server_cancels,
                server_ev,
                server_ctk,
            )
            .await;
        });

        (self.events)(RqsEvent::Ready { port });
        Ok(port)
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
        ip: String,
        port: u16,
        files: Vec<RqsOutboundFile>,
    ) {
        let local_name = self
            .device_name
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| "MaterialDrop".to_string());
        let cancels = self.cancellations.clone();
        let ev = self.events.clone();
        handle.spawn(async move {
            let _ = transfer::send_files_outbound(
                transfer_id,
                ip,
                port,
                local_name,
                files,
                cancels,
                ev,
            )
            .await;
        });
    }

    pub fn stop(&mut self) {
        if let Some(ctk) = self.ctk.take() {
            ctk.cancel();
        }
        if let Some(mdns) = self.mdns.take() {
            mdns.shutdown();
        }
        self.bound_port = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::{to_four_digit_pin, Ukey2Keys};
    use crate::mdns::{build_endpoint_info, parse_endpoint_info};
    use crate::proto::{build_introduction_frame, parse_sharing_frame, ParsedSharingFrame, SharingFileMeta};

    #[test]
    fn endpoint_info_roundtrip() {
        let bytes = build_endpoint_info("Pixel 9 Pro", 1);
        let (name, dtype) = parse_endpoint_info(&bytes);
        assert_eq!(name.as_deref(), Some("Pixel 9 Pro"));
        assert_eq!(dtype, 1);
    }

    #[test]
    fn secure_channel_encrypt_decrypt_roundtrip() {
        let keys = Ukey2Keys {
            auth_string: vec![1, 2, 3, 4],
            d2d_client_key: vec![0xAA; 32],
            d2d_server_key: vec![0xBB; 32],
        };
        let pin = to_four_digit_pin(&keys.auth_string);
        assert_eq!(pin.len(), 4);

        let mut client = crypto::SecureChannel::from_keys(&keys, false).unwrap();
        let mut server = crypto::SecureChannel::from_keys(&keys, true).unwrap();

        let intro = build_introduction_frame(&[SharingFileMeta {
            payload_id: 42,
            name: "photo.png".to_string(),
            size: 12345,
            mime_type: "image/png".to_string(),
            meta_type: 1,
        }]);
        let enc = client.encrypt(&intro).unwrap();
        let dec = server.decrypt(&enc).unwrap();
        match parse_sharing_frame(&dec).unwrap() {
            ParsedSharingFrame::Introduction { files, .. } => {
                assert_eq!(files.len(), 1);
                assert_eq!(files[0].name, "photo.png");
                assert_eq!(files[0].size, 12345);
            }
            _ => panic!("Expected IntroductionFrame"),
        }
    }
}
