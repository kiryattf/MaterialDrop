//! UKEY2 P-256 ECDH handshake, PIN derivation, and SecureMessage AES-256-CBC + HMAC-SHA256 channel.

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use anyhow::{bail, Context, Result};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use num_bigint::BigInt;
use p256::elliptic_curve::rand_core::OsRng;
use p256::elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint};
use p256::{EncodedPoint, PublicKey, SecretKey};
use rand::RngCore;
use sha2::{Digest, Sha256, Sha512};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::proto;

type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;
type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;
type HmacSha256 = Hmac<Sha256>;

pub struct Ukey2Keys {
    pub auth_string: Vec<u8>,
    pub d2d_client_key: Vec<u8>,
    pub d2d_server_key: Vec<u8>,
}

impl Ukey2Keys {
    pub fn pin_code(&self) -> String {
        to_four_digit_pin(&self.auth_string)
    }
}

pub fn to_four_digit_pin(bytes: &[u8]) -> String {
    let mut hash: i32 = 0;
    let mut multiplier: i32 = 1;
    let modulo: i32 = 9973;
    for &raw_byte in bytes {
        let signed = raw_byte as i8 as i32;
        hash = (hash + signed * multiplier).rem_euclid(modulo);
        multiplier = (multiplier * 31).rem_euclid(modulo);
    }
    format!("{:04}", hash.abs() % 10000)
}

fn strip_leading_zero(b: &[u8]) -> Vec<u8> {
    if b.len() > 32 && b[0] == 0 {
        b[b.len() - 32..].to_vec()
    } else {
        b.to_vec()
    }
}

fn pad_to_32(b: &[u8]) -> Vec<u8> {
    let clean = strip_leading_zero(b);
    if clean.len() >= 32 {
        return clean[clean.len() - 32..].to_vec();
    }
    let mut out = vec![0u8; 32 - clean.len()];
    out.extend_from_slice(&clean);
    out
}

fn key_coords_twos_complement(sk: &SecretKey) -> (Vec<u8>, Vec<u8>) {
    let point = sk.public_key().to_encoded_point(false);
    let x = BigInt::from_bytes_be(num_bigint::Sign::Plus, point.x().unwrap()).to_signed_bytes_be();
    let y = BigInt::from_bytes_be(num_bigint::Sign::Plus, point.y().unwrap()).to_signed_bytes_be();
    (x, y)
}

fn parse_peer_p256_key(x: &[u8], y: &[u8]) -> Result<PublicKey> {
    let x32 = pad_to_32(x);
    let y32 = pad_to_32(y);
    let mut uncompressed = Vec::with_capacity(65);
    uncompressed.push(0x04);
    uncompressed.extend_from_slice(&x32);
    uncompressed.extend_from_slice(&y32);
    let ep = EncodedPoint::from_bytes(&uncompressed).context("Bad SEC1 point")?;
    Option::<PublicKey>::from(PublicKey::from_encoded_point(&ep))
        .ok_or_else(|| anyhow::anyhow!("Invalid P-256 public key"))
}

fn derive_ukey2_keys(
    shared_secret: &[u8],
    client_init_raw: &[u8],
    server_init_raw: &[u8],
) -> Result<Ukey2Keys> {
    let mut hasher = Sha256::new();
    hasher.update(shared_secret);
    let derived_secret_hash = hasher.finalize();

    let mut transcript = Vec::with_capacity(client_init_raw.len() + server_init_raw.len());
    transcript.extend_from_slice(client_init_raw);
    transcript.extend_from_slice(server_init_raw);

    let hk_auth = Hkdf::<Sha256>::new(Some(b"UKEY2 v1 auth"), &derived_secret_hash);
    let mut auth_string = vec![0u8; 32];
    hk_auth
        .expand(&transcript, &mut auth_string)
        .map_err(|_| anyhow::anyhow!("HKDF expand auth failed"))?;

    let hk_next = Hkdf::<Sha256>::new(Some(b"UKEY2 v1 next"), &derived_secret_hash);
    let mut next_secret = vec![0u8; 32];
    hk_next
        .expand(&transcript, &mut next_secret)
        .map_err(|_| anyhow::anyhow!("HKDF expand next failed"))?;

    let d2d_salt = Sha256::digest(b"D2D");
    let hk_d2d = Hkdf::<Sha256>::new(Some(&d2d_salt), &next_secret);
    let mut client_key = vec![0u8; 32];
    let mut server_key = vec![0u8; 32];
    hk_d2d
        .expand(b"client", &mut client_key)
        .map_err(|_| anyhow::anyhow!("HKDF expand d2d client failed"))?;
    hk_d2d
        .expand(b"server", &mut server_key)
        .map_err(|_| anyhow::anyhow!("HKDF expand d2d server failed"))?;

    Ok(Ukey2Keys {
        auth_string,
        d2d_client_key: client_key,
        d2d_server_key: server_key,
    })
}

/// Paired encrypt/decrypt SecureMessage session channel.
pub struct SecureChannel {
    encrypt_aes_key: Vec<u8>,
    encrypt_hmac_key: Vec<u8>,
    decrypt_aes_key: Vec<u8>,
    decrypt_hmac_key: Vec<u8>,
    send_seq: i32,
    recv_seq: i32,
}

impl SecureChannel {
    pub fn from_keys(keys: &Ukey2Keys, is_server: bool) -> Result<Self> {
        let salt = Sha256::digest(b"SecureMessage");
        let derive = |key_material: &[u8]| -> Result<(Vec<u8>, Vec<u8>)> {
            let hk = Hkdf::<Sha256>::new(Some(&salt), key_material);
            let mut aes_key = vec![0u8; 32];
            let mut hmac_key = vec![0u8; 32];
            hk.expand(b"ENC:2", &mut aes_key)
                .map_err(|_| anyhow::anyhow!("HKDF ENC:2 failed"))?;
            hk.expand(b"SIG:1", &mut hmac_key)
                .map_err(|_| anyhow::anyhow!("HKDF SIG:1 failed"))?;
            Ok((aes_key, hmac_key))
        };

        let (c_aes, c_hmac) = derive(&keys.d2d_client_key)?;
        let (s_aes, s_hmac) = derive(&keys.d2d_server_key)?;

        Ok(if is_server {
            Self {
                encrypt_aes_key: s_aes,
                encrypt_hmac_key: s_hmac,
                decrypt_aes_key: c_aes,
                decrypt_hmac_key: c_hmac,
                send_seq: 0,
                recv_seq: 0,
            }
        } else {
            Self {
                encrypt_aes_key: c_aes,
                encrypt_hmac_key: c_hmac,
                decrypt_aes_key: s_aes,
                decrypt_hmac_key: s_hmac,
                send_seq: 0,
                recv_seq: 0,
            }
        })
    }

    pub fn encrypt(&mut self, payload: &[u8]) -> Result<Vec<u8>> {
        self.send_seq += 1;
        let d2d = proto::build_device_to_device_message(payload, self.send_seq);

        let mut iv = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut iv);

        let mut buf = vec![0u8; d2d.len() + 16];
        buf[..d2d.len()].copy_from_slice(&d2d);
        let encrypted = Aes256CbcEnc::new_from_slices(&self.encrypt_aes_key, &iv)
            .map_err(|e| anyhow::anyhow!("AES init: {e:?}"))?
            .encrypt_padded_mut::<Pkcs7>(&mut buf, d2d.len())
            .map_err(|e| anyhow::anyhow!("AES encrypt: {e:?}"))?;

        let hb = proto::build_header_and_body(&iv, encrypted);
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&self.encrypt_hmac_key)?;
        mac.update(&hb);
        let sig = mac.finalize().into_bytes();

        Ok(proto::build_secure_message(&hb, &sig))
    }

    pub fn decrypt(&mut self, secure_msg_bytes: &[u8]) -> Result<Vec<u8>> {
        let (hb, sig) = proto::parse_secure_message(secure_msg_bytes)?;
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&self.decrypt_hmac_key)?;
        mac.update(&hb);
        mac.verify_slice(&sig)
            .map_err(|_| anyhow::anyhow!("SecureMessage HMAC verification failed"))?;

        let (iv, body) = proto::parse_header_and_body(&hb)?;
        let mut dec_buf = body;
        let plain = Aes256CbcDec::new_from_slices(&self.decrypt_aes_key, &iv)
            .map_err(|e| anyhow::anyhow!("AES dec init: {e:?}"))?
            .decrypt_padded_mut::<Pkcs7>(&mut dec_buf)
            .map_err(|e| anyhow::anyhow!("AES decrypt: {e:?}"))?;

        let (inner_msg, seq) = proto::parse_device_to_device_message(plain)?;
        self.recv_seq += 1;
        if seq != self.recv_seq {
            bail!("SecureMessage sequence mismatch: expected {}, got {seq}", self.recv_seq);
        }
        Ok(inner_msg)
    }
}

pub async fn write_frame(stream: &mut TcpStream, data: &[u8]) -> Result<()> {
    let len_bytes = (data.len() as u32).to_be_bytes();
    stream.write_all(&len_bytes).await?;
    stream.write_all(data).await?;
    stream.flush().await?;
    Ok(())
}

pub async fn read_frame(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > 8 * 1024 * 1024 {
        bail!("Invalid frame length: {len}");
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).await?;
    Ok(buf)
}

pub async fn run_server_handshake(stream: &mut TcpStream) -> Result<(Ukey2Keys, SecureChannel)> {
    let client_init_bytes = read_frame(stream).await?;
    let expected_commitment = proto::parse_ukey2_client_init_commitment(&client_init_bytes)?;

    let sk = SecretKey::random(&mut OsRng);
    let (x, y) = key_coords_twos_complement(&sk);
    let mut random = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut random);

    let server_init_bytes = proto::build_ukey2_server_init(&random, &x, &y);
    write_frame(stream, &server_init_bytes).await?;

    let client_finished_bytes = read_frame(stream).await?;
    let actual_commitment = Sha512::digest(&client_finished_bytes);
    if actual_commitment.as_slice() != expected_commitment.as_slice() {
        bail!("UKEY2 SHA-512 commitment mismatch");
    }

    let (px, py) = proto::parse_ukey2_client_finished_key(&client_finished_bytes)?;
    let peer_pk = parse_peer_p256_key(&px, &py)?;
    let shared = p256::ecdh::diffie_hellman(sk.to_nonzero_scalar(), peer_pk.as_affine());
    let keys = derive_ukey2_keys(
        shared.raw_secret_bytes().as_slice(),
        &client_init_bytes,
        &server_init_bytes,
    )?;
    let channel = SecureChannel::from_keys(&keys, true)?;
    Ok((keys, channel))
}

pub async fn run_client_handshake(stream: &mut TcpStream) -> Result<(Ukey2Keys, SecureChannel)> {
    let sk = SecretKey::random(&mut OsRng);
    let (x, y) = key_coords_twos_complement(&sk);
    let client_finished_bytes = proto::build_ukey2_client_finished(&x, &y);
    let commitment = Sha512::digest(&client_finished_bytes);

    let mut random = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut random);
    let client_init_bytes = proto::build_ukey2_client_init(&random, commitment.as_slice());
    write_frame(stream, &client_init_bytes).await?;

    let server_init_bytes = read_frame(stream).await?;
    let (px, py) = proto::parse_ukey2_server_init_key(&server_init_bytes)?;
    write_frame(stream, &client_finished_bytes).await?;

    let peer_pk = parse_peer_p256_key(&px, &py)?;
    let shared = p256::ecdh::diffie_hellman(sk.to_nonzero_scalar(), peer_pk.as_affine());
    let keys = derive_ukey2_keys(
        shared.raw_secret_bytes().as_slice(),
        &client_init_bytes,
        &server_init_bytes,
    )?;
    let channel = SecureChannel::from_keys(&keys, false)?;
    Ok((keys, channel))
}
