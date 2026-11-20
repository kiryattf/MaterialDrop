//! Pure Rust Protobuf v2 binary wire codec for Nearby Connections & Quick Share frames.

use anyhow::{bail, Result};

/// Minimal Protobuf v2 binary writer supporting varints and length-delimited fields.
#[derive(Default)]
pub struct ProtoWriter {
    buf: Vec<u8>,
}

impl ProtoWriter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn write_varint(&mut self, mut value: u64) {
        loop {
            if (value & !0x7F) == 0 {
                self.buf.push(value as u8);
                break;
            }
            self.buf.push(((value & 0x7F) as u8) | 0x80);
            value >>= 7;
        }
    }

    pub fn write_tag(&mut self, field_number: u32, wire_type: u8) {
        self.write_varint(((field_number as u64) << 3) | ((wire_type & 0x07) as u64));
    }

    pub fn write_int32(&mut self, field: u32, value: i32) {
        self.write_tag(field, 0);
        self.write_varint(value as i64 as u64);
    }

    pub fn write_int64(&mut self, field: u32, value: i64) {
        self.write_tag(field, 0);
        self.write_varint(value as u64);
    }

    pub fn write_bool(&mut self, field: u32, value: bool) {
        self.write_tag(field, 0);
        self.write_varint(if value { 1 } else { 0 });
    }

    pub fn write_bytes(&mut self, field: u32, data: &[u8]) {
        self.write_tag(field, 2);
        self.write_varint(data.len() as u64);
        self.buf.extend_from_slice(data);
    }

    pub fn write_string(&mut self, field: u32, value: &str) {
        self.write_bytes(field, value.as_bytes());
    }

    pub fn into_vec(self) -> Vec<u8> {
        self.buf
    }
}

/// Minimal Protobuf v2 binary reader.
pub struct ProtoReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> ProtoReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn has_more(&self) -> bool {
        self.pos < self.data.len()
    }

    pub fn read_varint(&mut self) -> Result<u64> {
        let mut result: u64 = 0;
        let mut shift = 0u32;
        loop {
            if self.pos >= self.data.len() {
                bail!("Truncated protobuf varint");
            }
            let b = self.data[self.pos];
            self.pos += 1;
            result |= ((b & 0x7F) as u64) << shift;
            if (b & 0x80) == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift >= 70 {
                bail!("Malformed protobuf varint");
            }
        }
    }

    pub fn read_tag(&mut self) -> Result<(u32, u8)> {
        let key = self.read_varint()?;
        Ok(((key >> 3) as u32, (key & 0x07) as u8))
    }

    pub fn read_bytes(&mut self) -> Result<&'a [u8]> {
        let len = self.read_varint()? as usize;
        if self.pos.saturating_add(len) > self.data.len() {
            bail!("Truncated protobuf bytes field");
        }
        let slice = &self.data[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    pub fn read_string(&mut self) -> Result<String> {
        let b = self.read_bytes()?;
        Ok(String::from_utf8_lossy(b).into_owned())
    }

    pub fn skip_field(&mut self, wire_type: u8) -> Result<()> {
        match wire_type {
            0 => {
                self.read_varint()?;
            }
            1 => {
                if self.pos + 8 > self.data.len() {
                    bail!("Truncated 64-bit protobuf field");
                }
                self.pos += 8;
            }
            2 => {
                let len = self.read_varint()? as usize;
                if self.pos.saturating_add(len) > self.data.len() {
                    bail!("Truncated length-delimited protobuf field");
                }
                self.pos += len;
            }
            5 => {
                if self.pos + 4 > self.data.len() {
                    bail!("Truncated 32-bit protobuf field");
                }
                self.pos += 4;
            }
            _ => bail!("Unsupported protobuf wire type: {wire_type}"),
        }
        Ok(())
    }
}

// --- Frame & Message Builders / Parsers ---

pub const STATUS_ACCEPT: i32 = 1;
pub const STATUS_REJECT: i32 = 2;

pub fn build_connection_request(endpoint_id: &str, endpoint_info: &[u8]) -> Vec<u8> {
    let mut medium_meta = ProtoWriter::new();
    medium_meta.write_bool(1, true); // supports_5ghz
    medium_meta.write_int32(3, 5); // WIFI_LAN = 5

    let mut req = ProtoWriter::new();
    req.write_string(1, endpoint_id);
    req.write_bytes(2, endpoint_info);
    req.write_int32(5, 0);
    req.write_int32(6, 0);
    req.write_bytes(9, &medium_meta.into_vec());

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 2); // CONNECTION_REQUEST = 2
    v1.write_bytes(2, &req.into_vec());

    let mut offline = ProtoWriter::new();
    offline.write_int32(1, 1); // V1 = 1
    offline.write_bytes(2, &v1.into_vec());
    offline.into_vec()
}

pub fn parse_connection_request_endpoint_info(frame: &[u8]) -> Option<Vec<u8>> {
    let mut r = ProtoReader::new(frame);
    while r.has_more() {
        let (f, wt) = r.read_tag().ok()?;
        if f == 2 && wt == 2 {
            let v1_bytes = r.read_bytes().ok()?;
            let mut v1r = ProtoReader::new(v1_bytes);
            while v1r.has_more() {
                let (vf, vwt) = v1r.read_tag().ok()?;
                if vf == 2 && vwt == 2 {
                    let req_bytes = v1r.read_bytes().ok()?;
                    let mut reqr = ProtoReader::new(req_bytes);
                    while reqr.has_more() {
                        let (rf, rwt) = reqr.read_tag().ok()?;
                        if rf == 2 && rwt == 2 {
                            return Some(reqr.read_bytes().ok()?.to_vec());
                        }
                        reqr.skip_field(rwt).ok()?;
                    }
                } else {
                    v1r.skip_field(vwt).ok()?;
                }
            }
        } else {
            r.skip_field(wt).ok()?;
        }
    }
    None
}

pub fn build_offline_connection_response(status: i32) -> Vec<u8> {
    let mut resp = ProtoWriter::new();
    resp.write_int32(1, 0); // deprecated status ACCEPT = 0
    resp.write_int32(3, if status == STATUS_ACCEPT { 0 } else { 1 });

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 3); // CONNECTION_RESPONSE = 3
    v1.write_bytes(3, &resp.into_vec());

    let mut offline = ProtoWriter::new();
    offline.write_int32(1, 1); // V1 = 1
    offline.write_bytes(2, &v1.into_vec());
    offline.into_vec()
}

pub fn build_ukey2_client_init(random: &[u8; 32], commitment: &[u8]) -> Vec<u8> {
    let mut cipher_comm = ProtoWriter::new();
    cipher_comm.write_int32(1, 100); // P256_SHA512 = 100
    cipher_comm.write_bytes(2, commitment);

    let mut ci = ProtoWriter::new();
    ci.write_int32(1, 1); // version = 1
    ci.write_bytes(2, random);
    ci.write_bytes(3, &cipher_comm.into_vec());
    ci.write_string(4, "AES_256_CBC-HMAC_SHA256");

    let mut msg = ProtoWriter::new();
    msg.write_int32(1, 2); // CLIENT_INIT = 2
    msg.write_bytes(2, &ci.into_vec());
    msg.into_vec()
}

pub fn build_ukey2_server_init(
    random: &[u8; 32],
    x_coord: &[u8],
    y_coord: &[u8],
) -> Vec<u8> {
    let gpk = encode_generic_p256_key(x_coord, y_coord);
    let mut si = ProtoWriter::new();
    si.write_int32(1, 1); // version = 1
    si.write_bytes(2, random);
    si.write_int32(3, 100); // P256_SHA512
    si.write_bytes(4, &gpk);

    let mut msg = ProtoWriter::new();
    msg.write_int32(1, 3); // SERVER_INIT = 3
    msg.write_bytes(2, &si.into_vec());
    msg.into_vec()
}

pub fn build_ukey2_client_finished(x_coord: &[u8], y_coord: &[u8]) -> Vec<u8> {
    let gpk = encode_generic_p256_key(x_coord, y_coord);
    let mut cf = ProtoWriter::new();
    cf.write_bytes(1, &gpk);

    let mut msg = ProtoWriter::new();
    msg.write_int32(1, 4); // CLIENT_FINISH = 4
    msg.write_bytes(2, &cf.into_vec());
    msg.into_vec()
}

fn encode_generic_p256_key(x_coord: &[u8], y_coord: &[u8]) -> Vec<u8> {
    let mut ec = ProtoWriter::new();
    ec.write_bytes(1, x_coord);
    ec.write_bytes(2, y_coord);

    let mut gpk = ProtoWriter::new();
    gpk.write_int32(1, 1); // EC_P256 = 1
    gpk.write_bytes(2, &ec.into_vec());
    gpk.into_vec()
}

pub fn parse_ukey2_client_init_commitment(msg_bytes: &[u8]) -> Result<Vec<u8>> {
    let data = extract_ukey2_inner(msg_bytes, 2)?;
    let mut r = ProtoReader::new(&data);
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        if f == 3 && wt == 2 {
            let cc_bytes = r.read_bytes()?;
            let mut ccr = ProtoReader::new(cc_bytes);
            let mut cipher_ok = false;
            let mut comm = Vec::new();
            while ccr.has_more() {
                let (cf, cwt) = ccr.read_tag()?;
                match (cf, cwt) {
                    (1, 0) => {
                        if ccr.read_varint()? == 100 {
                            cipher_ok = true;
                        }
                    }
                    (2, 2) => {
                        comm = ccr.read_bytes()?.to_vec();
                    }
                    _ => ccr.skip_field(cwt)?,
                }
            }
            if cipher_ok && !comm.is_empty() {
                return Ok(comm);
            }
        } else {
            r.skip_field(wt)?;
        }
    }
    bail!("Missing P256_SHA512 commitment in Ukey2ClientInit")
}

pub fn parse_ukey2_server_init_key(msg_bytes: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let data = extract_ukey2_inner(msg_bytes, 3)?;
    let mut r = ProtoReader::new(&data);
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        if f == 4 && wt == 2 {
            let pk_bytes = r.read_bytes()?;
            return decode_generic_p256_key(pk_bytes);
        }
        r.skip_field(wt)?;
    }
    bail!("Missing public key in Ukey2ServerInit")
}

pub fn parse_ukey2_client_finished_key(msg_bytes: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let data = extract_ukey2_inner(msg_bytes, 4)?;
    let mut r = ProtoReader::new(&data);
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        if f == 1 && wt == 2 {
            let pk_bytes = r.read_bytes()?;
            return decode_generic_p256_key(pk_bytes);
        }
        r.skip_field(wt)?;
    }
    bail!("Missing public key in Ukey2ClientFinished")
}

fn extract_ukey2_inner(msg_bytes: &[u8], expected_type: u64) -> Result<Vec<u8>> {
    let mut r = ProtoReader::new(msg_bytes);
    let mut msg_type = 0u64;
    let mut data = None;
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        match (f, wt) {
            (1, 0) => msg_type = r.read_varint()?,
            (2, 2) => data = Some(r.read_bytes()?.to_vec()),
            _ => r.skip_field(wt)?,
        }
    }
    if msg_type != expected_type {
        bail!("Unexpected UKEY2 message type: expected {expected_type}, got {msg_type}");
    }
    data.ok_or_else(|| anyhow::anyhow!("Empty UKEY2 message data"))
}

fn decode_generic_p256_key(gpk_bytes: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut r = ProtoReader::new(gpk_bytes);
    let mut x = Vec::new();
    let mut y = Vec::new();
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        if f == 2 && wt == 2 {
            let ec_bytes = r.read_bytes()?;
            let mut ecr = ProtoReader::new(ec_bytes);
            while ecr.has_more() {
                let (ef, ewt) = ecr.read_tag()?;
                match (ef, ewt) {
                    (1, 2) => x = ecr.read_bytes()?.to_vec(),
                    (2, 2) => y = ecr.read_bytes()?.to_vec(),
                    _ => ecr.skip_field(ewt)?,
                }
            }
        } else {
            r.skip_field(wt)?;
        }
    }
    if x.is_empty() || y.is_empty() {
        bail!("Invalid EcP256PublicKey");
    }
    Ok((x, y))
}

pub fn build_device_to_device_message(body: &[u8], seq: i32) -> Vec<u8> {
    let mut m = ProtoWriter::new();
    m.write_bytes(1, body);
    m.write_int32(2, seq);
    m.into_vec()
}

pub fn parse_device_to_device_message(data: &[u8]) -> Result<(Vec<u8>, i32)> {
    let mut r = ProtoReader::new(data);
    let mut msg = Vec::new();
    let mut seq = 0i32;
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        match (f, wt) {
            (1, 2) => msg = r.read_bytes()?.to_vec(),
            (2, 0) => seq = r.read_varint()? as i32,
            _ => r.skip_field(wt)?,
        }
    }
    Ok((msg, seq))
}

pub fn build_header_and_body(iv: &[u8], body: &[u8]) -> Vec<u8> {
    let mut meta = ProtoWriter::new();
    meta.write_int32(1, 100); // Type::DeviceToDeviceMessage = 100
    meta.write_int32(2, 1); // version = 1

    let mut hdr = ProtoWriter::new();
    hdr.write_int32(1, 1); // HMAC_SHA256 = 1
    hdr.write_int32(2, 2); // AES_256_CBC = 2
    hdr.write_bytes(4, iv);
    hdr.write_bytes(5, &meta.into_vec());

    let mut hb = ProtoWriter::new();
    hb.write_bytes(1, &hdr.into_vec());
    hb.write_bytes(2, body);
    hb.into_vec()
}

pub fn parse_header_and_body(data: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut r = ProtoReader::new(data);
    let mut iv = Vec::new();
    let mut body = Vec::new();
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        match (f, wt) {
            (1, 2) => {
                let hdr_bytes = r.read_bytes()?;
                let mut hr = ProtoReader::new(hdr_bytes);
                while hr.has_more() {
                    let (hf, hwt) = hr.read_tag()?;
                    if hf == 4 && hwt == 2 {
                        iv = hr.read_bytes()?.to_vec();
                    } else {
                        hr.skip_field(hwt)?;
                    }
                }
            }
            (2, 2) => body = r.read_bytes()?.to_vec(),
            _ => r.skip_field(wt)?,
        }
    }
    Ok((iv, body))
}

pub fn build_secure_message(header_and_body: &[u8], sig: &[u8]) -> Vec<u8> {
    let mut sm = ProtoWriter::new();
    sm.write_bytes(1, header_and_body);
    sm.write_bytes(2, sig);
    sm.into_vec()
}

pub fn parse_secure_message(data: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut r = ProtoReader::new(data);
    let mut hb = Vec::new();
    let mut sig = Vec::new();
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        match (f, wt) {
            (1, 2) => hb = r.read_bytes()?.to_vec(),
            (2, 2) => sig = r.read_bytes()?.to_vec(),
            _ => r.skip_field(wt)?,
        }
    }
    Ok((hb, sig))
}

pub fn build_payload_transfer_bytes(payload_id: i64, payload: &[u8]) -> Vec<u8> {
    build_payload_chunk(payload_id, 1, payload.len() as i64, 0, payload, 1)
}

pub fn build_payload_chunk(
    payload_id: i64,
    payload_type: i32,
    total_size: i64,
    offset: i64,
    chunk_data: &[u8],
    flags: i32,
) -> Vec<u8> {
    let mut hdr = ProtoWriter::new();
    hdr.write_int64(1, payload_id);
    hdr.write_int32(2, payload_type); // 1 = BYTES, 2 = FILE
    hdr.write_int64(3, total_size);

    let mut chunk = ProtoWriter::new();
    chunk.write_int32(1, flags); // 0 = chunk, 1 = last_chunk
    chunk.write_int64(2, offset);
    chunk.write_bytes(3, chunk_data);

    let mut ptf = ProtoWriter::new();
    ptf.write_int32(1, 0); // DATA = 0
    ptf.write_bytes(2, &hdr.into_vec());
    ptf.write_bytes(3, &chunk.into_vec());

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 4); // PAYLOAD_TRANSFER = 4
    v1.write_bytes(4, &ptf.into_vec());

    let mut offline = ProtoWriter::new();
    offline.write_int32(1, 1); // V1 = 1
    offline.write_bytes(2, &v1.into_vec());
    offline.into_vec()
}

pub struct ParsedPayloadChunk {
    pub payload_id: i64,
    pub payload_type: i32,
    pub total_size: i64,
    pub flags: i32,
    pub offset: i64,
    pub data: Vec<u8>,
}

pub enum ParsedOfflineFrame {
    PayloadChunk(ParsedPayloadChunk),
    KeepAlive,
    Disconnection,
    Other,
}

pub fn parse_offline_frame(data: &[u8]) -> Result<ParsedOfflineFrame> {
    let mut r = ProtoReader::new(data);
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        if f == 2 && wt == 2 {
            let v1_bytes = r.read_bytes()?;
            let mut v1r = ProtoReader::new(v1_bytes);
            let mut frame_type = 0i32;
            let mut payload_transfer = None;
            while v1r.has_more() {
                let (vf, vwt) = v1r.read_tag()?;
                match (vf, vwt) {
                    (1, 0) => frame_type = v1r.read_varint()? as i32,
                    (4, 2) => payload_transfer = Some(v1r.read_bytes()?.to_vec()),
                    _ => v1r.skip_field(vwt)?,
                }
            }
            if frame_type == 5 {
                return Ok(ParsedOfflineFrame::Disconnection);
            }
            if frame_type == 7 {
                return Ok(ParsedOfflineFrame::KeepAlive);
            }
            if frame_type == 4 {
                if let Some(ptf) = payload_transfer {
                    return Ok(ParsedOfflineFrame::PayloadChunk(parse_payload_transfer(&ptf)?));
                }
            }
            return Ok(ParsedOfflineFrame::Other);
        } else {
            r.skip_field(wt)?;
        }
    }
    Ok(ParsedOfflineFrame::Other)
}

fn parse_payload_transfer(ptf: &[u8]) -> Result<ParsedPayloadChunk> {
    let mut r = ProtoReader::new(ptf);
    let mut payload_id = 0i64;
    let mut payload_type = 1i32;
    let mut total_size = 0i64;
    let mut flags = 0i32;
    let mut offset = 0i64;
    let mut data = Vec::new();
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        match (f, wt) {
            (2, 2) => {
                let hb = r.read_bytes()?;
                let mut hr = ProtoReader::new(hb);
                while hr.has_more() {
                    let (hf, hwt) = hr.read_tag()?;
                    match (hf, hwt) {
                        (1, 0) => payload_id = hr.read_varint()? as i64,
                        (2, 0) => payload_type = hr.read_varint()? as i32,
                        (3, 0) => total_size = hr.read_varint()? as i64,
                        _ => hr.skip_field(hwt)?,
                    }
                }
            }
            (3, 2) => {
                let cb = r.read_bytes()?;
                let mut cr = ProtoReader::new(cb);
                while cr.has_more() {
                    let (cf, cwt) = cr.read_tag()?;
                    match (cf, cwt) {
                        (1, 0) => flags = cr.read_varint()? as i32,
                        (2, 0) => offset = cr.read_varint()? as i64,
                        (3, 2) => data = cr.read_bytes()?.to_vec(),
                        _ => cr.skip_field(cwt)?,
                    }
                }
            }
            _ => r.skip_field(wt)?,
        }
    }
    Ok(ParsedPayloadChunk {
        payload_id,
        payload_type,
        total_size,
        flags,
        offset,
        data,
    })
}

pub fn build_paired_key_encryption(secret_id_hash: &[u8], signed_data: &[u8]) -> Vec<u8> {
    let mut pke = ProtoWriter::new();
    pke.write_bytes(1, signed_data);
    pke.write_bytes(2, secret_id_hash);

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 2); // PAIRED_KEY_ENCRYPTION = 2
    v1.write_bytes(3, &pke.into_vec());

    let mut frame = ProtoWriter::new();
    frame.write_int32(1, 1); // V1 = 1
    frame.write_bytes(2, &v1.into_vec());
    frame.into_vec()
}

pub fn build_paired_key_result(status: i32) -> Vec<u8> {
    let mut pkr = ProtoWriter::new();
    pkr.write_int32(1, status); // UNKNOWN=0, SUCCESS=1, FAIL=2, UNABLE=3

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 3); // PAIRED_KEY_RESULT = 3
    v1.write_bytes(4, &pkr.into_vec());

    let mut frame = ProtoWriter::new();
    frame.write_int32(1, 1); // V1 = 1
    frame.write_bytes(2, &v1.into_vec());
    frame.into_vec()
}

#[derive(Clone, Debug)]
pub struct SharingFileMeta {
    pub payload_id: i64,
    pub name: String,
    pub size: i64,
    pub mime_type: String,
    pub meta_type: i32,
}

#[derive(Clone, Debug)]
pub struct SharingTextMeta {
    pub payload_id: i64,
    pub title: String,
    pub size: i64,
    pub text_type: i32,
}

pub enum ParsedSharingFrame {
    PairedKeyEncryption,
    PairedKeyResult(i32),
    Introduction {
        files: Vec<SharingFileMeta>,
        texts: Vec<SharingTextMeta>,
    },
    ConnectionResponse(i32),
    Cancel,
    Other,
}

pub fn build_introduction_frame(files: &[SharingFileMeta]) -> Vec<u8> {
    let mut intro = ProtoWriter::new();
    for f in files {
        let mut fm = ProtoWriter::new();
        fm.write_string(1, &f.name);
        fm.write_int32(2, f.meta_type);
        fm.write_int64(3, f.size);
        fm.write_string(4, &f.mime_type);
        fm.write_int64(5, f.payload_id);
        intro.write_bytes(1, &fm.into_vec());
    }

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 1); // INTRODUCTION = 1
    v1.write_bytes(2, &intro.into_vec());

    let mut frame = ProtoWriter::new();
    frame.write_int32(1, 1); // V1 = 1
    frame.write_bytes(2, &v1.into_vec());
    frame.into_vec()
}

pub fn build_sharing_connection_response(status: i32) -> Vec<u8> {
    let mut cr = ProtoWriter::new();
    cr.write_int32(1, status);

    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 5); // RESPONSE = 5
    v1.write_bytes(5, &cr.into_vec());

    let mut frame = ProtoWriter::new();
    frame.write_int32(1, 1); // V1 = 1
    frame.write_bytes(2, &v1.into_vec());
    frame.into_vec()
}

pub fn build_sharing_cancel() -> Vec<u8> {
    let mut v1 = ProtoWriter::new();
    v1.write_int32(1, 6); // CANCEL = 6

    let mut frame = ProtoWriter::new();
    frame.write_int32(1, 1);
    frame.write_bytes(2, &v1.into_vec());
    frame.into_vec()
}

pub fn parse_sharing_frame(data: &[u8]) -> Result<ParsedSharingFrame> {
    let mut r = ProtoReader::new(data);
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        if f == 2 && wt == 2 {
            let v1_bytes = r.read_bytes()?;
            let mut vr = ProtoReader::new(v1_bytes);
            let mut ftype = 0i32;
            let mut intro_bytes = None;
            let mut pkr_bytes = None;
            let mut resp_bytes = None;
            while vr.has_more() {
                let (vf, vwt) = vr.read_tag()?;
                match (vf, vwt) {
                    (1, 0) => ftype = vr.read_varint()? as i32,
                    (2, 2) => intro_bytes = Some(vr.read_bytes()?.to_vec()),
                    (4, 2) => pkr_bytes = Some(vr.read_bytes()?.to_vec()),
                    (5, 2) => resp_bytes = Some(vr.read_bytes()?.to_vec()),
                    _ => vr.skip_field(vwt)?,
                }
            }
            return match ftype {
                1 => {
                    let ib = intro_bytes.unwrap_or_default();
                    Ok(parse_introduction(&ib)?)
                }
                2 => Ok(ParsedSharingFrame::PairedKeyEncryption),
                3 => {
                    let status = pkr_bytes
                        .as_deref()
                        .and_then(parse_single_int32_field)
                        .unwrap_or(0);
                    Ok(ParsedSharingFrame::PairedKeyResult(status))
                }
                5 => {
                    let status = resp_bytes
                        .as_deref()
                        .and_then(parse_single_int32_field)
                        .unwrap_or(0);
                    Ok(ParsedSharingFrame::ConnectionResponse(status))
                }
                6 => Ok(ParsedSharingFrame::Cancel),
                _ => Ok(ParsedSharingFrame::Other),
            };
        } else {
            r.skip_field(wt)?;
        }
    }
    Ok(ParsedSharingFrame::Other)
}

fn parse_single_int32_field(bytes: &[u8]) -> Option<i32> {
    let mut r = ProtoReader::new(bytes);
    while r.has_more() {
        let (f, wt) = r.read_tag().ok()?;
        if f == 1 && wt == 0 {
            return Some(r.read_varint().ok()? as i32);
        }
        r.skip_field(wt).ok()?;
    }
    None
}

fn parse_introduction(bytes: &[u8]) -> Result<ParsedSharingFrame> {
    let mut r = ProtoReader::new(bytes);
    let mut files = Vec::new();
    let mut texts = Vec::new();
    while r.has_more() {
        let (f, wt) = r.read_tag()?;
        match (f, wt) {
            (1, 2) => {
                let fb = r.read_bytes()?;
                let mut fr = ProtoReader::new(fb);
                let mut fm = SharingFileMeta {
                    payload_id: 0,
                    name: String::from("file"),
                    size: 0,
                    mime_type: String::from("application/octet-stream"),
                    meta_type: 0,
                };
                while fr.has_more() {
                    let (ff, fwt) = fr.read_tag()?;
                    match (ff, fwt) {
                        (1, 2) => fm.name = fr.read_string()?,
                        (2, 0) => fm.meta_type = fr.read_varint()? as i32,
                        (3, 0) => fm.size = fr.read_varint()? as i64,
                        (4, 2) => fm.mime_type = fr.read_string()?,
                        (5, 0) => fm.payload_id = fr.read_varint()? as i64,
                        _ => fr.skip_field(fwt)?,
                    }
                }
                files.push(fm);
            }
            (2, 2) => {
                let tb = r.read_bytes()?;
                let mut tr = ProtoReader::new(tb);
                let mut tm = SharingTextMeta {
                    payload_id: 0,
                    title: String::from("Text"),
                    size: 0,
                    text_type: 0,
                };
                while tr.has_more() {
                    let (tf, twt) = tr.read_tag()?;
                    match (tf, twt) {
                        (1, 2) => tm.title = tr.read_string()?,
                        (2, 0) => tm.text_type = tr.read_varint()? as i32,
                        (3, 0) => tm.payload_id = tr.read_varint()? as i64,
                        (4, 0) => tm.size = tr.read_varint()? as i64,
                        _ => tr.skip_field(twt)?,
                    }
                }
                texts.push(tm);
            }
            _ => r.skip_field(wt)?,
        }
    }
    Ok(ParsedSharingFrame::Introduction { files, texts })
}
