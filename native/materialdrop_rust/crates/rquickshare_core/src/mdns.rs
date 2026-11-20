//! Cross-platform mDNS advertiser and discovery browser for Quick Share (`_FC9F5ED42C8A._tcp.local.`).

use std::collections::HashMap;
use std::net::IpAddr;

use anyhow::Result;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use rand::distributions::Alphanumeric;
use rand::Rng;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const SERVICE_TYPE: &str = "_FC9F5ED42C8A._tcp.local.";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiscoveredQuickSharePeer {
    pub fullname: String,
    pub id: String,
    pub name: String,
    pub ip: String,
    pub port: u16,
    pub device_type: u8,
}

pub fn generate_endpoint_id() -> [u8; 4] {
    let mut rng = rand::thread_rng();
    let mut out = [0u8; 4];
    for b in &mut out {
        *b = rng.sample(Alphanumeric);
    }
    out
}

pub fn build_service_instance_name(endpoint_id: [u8; 4]) -> String {
    let mut raw = Vec::with_capacity(10);
    raw.push(0x23); // PCP_P2P_POINT_TO_POINT
    raw.extend_from_slice(&endpoint_id);
    raw.extend_from_slice(&[0xFC, 0x9F, 0x5E]);
    raw.push(0);
    raw.push(0);
    URL_SAFE_NO_PAD.encode(&raw)
}

pub fn build_endpoint_info(device_name: &str, device_type: u8) -> Vec<u8> {
    let mut info = Vec::new();
    let header_byte = ((device_type & 0x07) << 1) & 0x0E;
    info.push(header_byte);
    let mut rng = rand::thread_rng();
    for _ in 0..16 {
        info.push(rng.gen());
    }
    let name_bytes = device_name.as_bytes();
    let len = name_bytes.len().min(255);
    info.push(len as u8);
    info.extend_from_slice(&name_bytes[..len]);
    info
}

pub fn parse_endpoint_info(bytes: &[u8]) -> (Option<String>, u8) {
    if bytes.len() < 18 {
        return (None, 0);
    }
    let device_type = (bytes[0] >> 1) & 0x07;
    let name_len = bytes[17] as usize;
    if 18 + name_len <= bytes.len() && name_len > 0 {
        let name = String::from_utf8_lossy(&bytes[18..18 + name_len]).into_owned();
        (Some(name), device_type)
    } else {
        (None, device_type)
    }
}

fn collect_local_ipv4s() -> Vec<IpAddr> {
    let mut ips = Vec::new();
    if let Ok(ifaces) = get_if_addrs::get_if_addrs() {
        for iface in ifaces {
            if let IpAddr::V4(v4) = iface.ip() {
                if !v4.is_loopback() && !v4.is_link_local() {
                    ips.push(IpAddr::V4(v4));
                }
            }
        }
    }
    ips
}

fn is_self_ip(ip_str: &str, local_ips: &[IpAddr]) -> bool {
    ip_str
        .parse::<IpAddr>()
        .map(|addr| addr.is_loopback() || local_ips.contains(&addr))
        .unwrap_or(false)
}

pub struct MdnsHandle {
    daemon: ServiceDaemon,
    fullname: String,
}

impl MdnsHandle {
    pub fn start(
        endpoint_id: [u8; 4],
        device_name: &str,
        port: u16,
        visible: bool,
        ctk: CancellationToken,
        on_peer_found: mpsc::UnboundedSender<DiscoveredQuickSharePeer>,
        on_peer_lost: mpsc::UnboundedSender<String>,
    ) -> Result<Self> {
        let daemon = ServiceDaemon::new()?;
        let instance_name = build_service_instance_name(endpoint_id);
        let endpoint_info_b64 = URL_SAFE_NO_PAD.encode(build_endpoint_info(device_name, 3));
        let host_raw = hostname::get()
            .ok()
            .and_then(|s| s.into_string().ok())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "materialdrop".to_string());
        let host_label = format!("{}.local.", host_raw.trim_end_matches(".local.").trim_end_matches('.'));

        let ips = collect_local_ipv4s();
        let mut props = HashMap::new();
        props.insert("n".to_string(), endpoint_info_b64);

        let info = ServiceInfo::new(
            SERVICE_TYPE,
            &instance_name,
            &host_label,
            ips.as_slice(),
            port,
            Some(props),
        )?;
        let fullname = info.get_fullname().to_string();
        if visible {
            daemon.register(info)?;
        }

        let receiver = daemon.browse(SERVICE_TYPE)?;
        let own_fullname = fullname.clone();
        std::thread::Builder::new()
            .name("rqs-mdns-browse".to_string())
            .spawn(move || {
                let mut cache: HashMap<String, DiscoveredQuickSharePeer> = HashMap::new();
                loop {
                    if ctk.is_cancelled() {
                        break;
                    }
                    match receiver.recv_timeout(std::time::Duration::from_millis(400)) {
                        Ok(ServiceEvent::ServiceResolved(resolved)) => {
                            if resolved.fullname == own_fullname {
                                continue;
                            }
                            let local_ips = collect_local_ipv4s();
                            let ip_opt = resolved
                                .get_addresses_v4()
                                .into_iter()
                                .map(|ip| ip.to_string())
                                .find(|ip| !is_self_ip(ip, &local_ips));
                            let Some(ip) = ip_opt else {
                                continue;
                            };
                            let (name_opt, dev_type) = resolved
                                .get_property("n")
                                .and_then(|prop| prop.val())
                                .and_then(|raw| URL_SAFE_NO_PAD.decode(raw).ok())
                                .map(|decoded| parse_endpoint_info(&decoded))
                                .unwrap_or((None, 0));

                            let id = resolved
                                .fullname
                                .split('.')
                                .next()
                                .unwrap_or(&resolved.fullname)
                                .to_string();
                            let peer = DiscoveredQuickSharePeer {
                                fullname: resolved.fullname.clone(),
                                id,
                                name: name_opt.unwrap_or_else(|| "Nearby Device".to_string()),
                                ip,
                                port: resolved.port,
                                device_type: dev_type,
                            };
                            cache.insert(resolved.fullname.clone(), peer.clone());
                            let _ = on_peer_found.send(peer);
                        }
                        Ok(ServiceEvent::ServiceRemoved(_, fullname)) => {
                            if cache.remove(&fullname).is_some() {
                                let _ = on_peer_lost.send(fullname);
                            }
                        }
                        Ok(_) => {}
                        Err(flume_or_timeout) => {
                            let msg = flume_or_timeout.to_string();
                            if !msg.contains("timed out") {
                                break;
                            }
                        }
                    }
                }
            })?;

        Ok(Self { daemon, fullname })
    }

    pub fn shutdown(self) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}
