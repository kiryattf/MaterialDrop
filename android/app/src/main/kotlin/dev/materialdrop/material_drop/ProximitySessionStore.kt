package dev.materialdrop.material_drop

import android.util.Base64
import org.json.JSONObject
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * Process-wide thread-safe proximity session state shared between
 * MainActivity, BleProximityManager, MaterialDropApduService (NFC HCE), and WifiDirectManager.
 */
object ProximitySessionStore {
    private const val ROTATION_INTERVAL_MS = 15L * 60L * 1000L

    private val rng = SecureRandom()
    private val lock = Any()

    private var ephemeralIdBytes: ByteArray = generateRandomId()
    private var lastRotationMs: Long = System.currentTimeMillis()
    private var ecKeyPair: KeyPair = generateEcdhKeyPair()

    @Volatile
    var deviceName: String = "MaterialDrop"

    @Volatile
    var transferPort: Int = 53317

    @Volatile
    var tlsFingerprint: String = ""

    @Volatile
    var activeHotspotSsid: String = ""

    @Volatile
    var activeHotspotPass: String = ""

    @Volatile
    var activeHotspotHostIp: String = ""

    @Volatile
    var irohTicket: String = ""

    @Volatile
    var onPeerHandshakeListener: ((source: String, peerMap: Map<String, Any?>) -> Unit)? = null

    private fun generateRandomId(): ByteArray {
        val bytes = ByteArray(16)
        rng.nextBytes(bytes)
        return bytes
    }

    private fun generateEcdhKeyPair(): KeyPair {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"), rng)
        return gen.generateKeyPair()
    }

    fun getOrRotateEphemeralId(): ByteArray {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            if (now - lastRotationMs >= ROTATION_INTERVAL_MS) {
                ephemeralIdBytes = generateRandomId()
                ecKeyPair = generateEcdhKeyPair()
                lastRotationMs = now
            }
            return ephemeralIdBytes.copyOf()
        }
    }

    fun forceRotateEphemeralId(): ByteArray {
        synchronized(lock) {
            ephemeralIdBytes = generateRandomId()
            ecKeyPair = generateEcdhKeyPair()
            lastRotationMs = System.currentTimeMillis()
            return ephemeralIdBytes.copyOf()
        }
    }

    fun getEphemeralIdHex(): String {
        val bytes = getOrRotateEphemeralId()
        return bytes.joinToString("") { "%02X".format(it) }
    }

    /** Returns 65-byte uncompressed ANSI X9.62 P-256 public point (0x04 || X || Y) Base64-encoded. */
    fun getLocalEcdhPublicKeyB64(): String {
        val pub = synchronized(lock) { ecKeyPair.public as ECPublicKey }
        val point = pub.w
        val x = bigIntTo32(point.affineX)
        val y = bigIntTo32(point.affineY)
        val uncompressed = ByteArray(65)
        uncompressed[0] = 0x04
        System.arraycopy(x, 0, uncompressed, 1, 32)
        System.arraycopy(y, 0, uncompressed, 33, 32)
        return Base64.encodeToString(uncompressed, Base64.NO_WRAP)
    }

    private fun bigIntTo32(value: java.math.BigInteger): ByteArray {
        val raw = value.toByteArray()
        val out = ByteArray(32)
        if (raw.size >= 32) {
            System.arraycopy(raw, raw.size - 32, out, 0, 32)
        } else {
            System.arraycopy(raw, 0, out, 32 - raw.size, raw.size)
        }
        return out
    }

    fun updateDirectWifi(ssid: String, pass: String, hostIp: String) {
        activeHotspotSsid = ssid
        activeHotspotPass = pass
        activeHotspotHostIp = hostIp
    }

    fun clearDirectWifi() {
        activeHotspotSsid = ""
        activeHotspotPass = ""
        activeHotspotHostIp = ""
    }

    fun buildHandshakeJson(includeWifiCredentials: Boolean = true): String {
        val obj = JSONObject()
        obj.put("n", deviceName.take(32))
        obj.put("e", getEphemeralIdHex())
        obj.put("k", getLocalEcdhPublicKeyB64())
        obj.put("p", transferPort)
        if (tlsFingerprint.isNotEmpty()) {
            obj.put("f", tlsFingerprint)
        }
        if (includeWifiCredentials && activeHotspotSsid.isNotEmpty()) {
            obj.put("s", activeHotspotSsid)
            obj.put("w", activeHotspotPass)
            if (activeHotspotHostIp.isNotEmpty()) {
                obj.put("i", activeHotspotHostIp)
            }
        }
        if (irohTicket.isNotEmpty()) {
            obj.put("t", irohTicket)
        }
        return obj.toString()
    }

    fun parseAndNotifyHandshake(source: String, jsonStr: String) {
        try {
            val obj = JSONObject(jsonStr)
            val map = hashMapOf<String, Any?>(
                "name" to obj.optString("n", "Nearby Device"),
                "ephemeralId" to obj.optString("e", ""),
                "ecPubB64" to obj.optString("k", ""),
                "port" to obj.optInt("p", 53317),
                "fingerprint" to obj.optString("f", ""),
                "wifiSsid" to obj.optString("s", ""),
                "wifiPass" to obj.optString("w", ""),
                "wifiIp" to obj.optString("i", ""),
                "irohTicket" to obj.optString("t", ""),
            )
            onPeerHandshakeListener?.invoke(source, map)
        } catch (_: Exception) {}
    }
}
