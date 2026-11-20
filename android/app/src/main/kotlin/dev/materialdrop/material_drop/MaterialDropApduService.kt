package dev.materialdrop.material_drop

import android.nfc.cardemulation.HostApduService
import android.os.Bundle
import java.nio.charset.StandardCharsets

/**
 * Android NFC HCE service enabling Tap-to-Share session & ECDH/Wi-Fi handshake
 * when another Android device touches this device in reader mode.
 */
class MaterialDropApduService : HostApduService() {
    companion object {
        val AID = byteArrayOf(
            0xF0.toByte(), 0x4D, 0x41, 0x54, 0x44, 0x52, 0x4F, 0x50 // F0MATDROP
        )

        private val SW_OK = byteArrayOf(0x90.toByte(), 0x00)
        private val SW_WRONG_LENGTH = byteArrayOf(0x67, 0x00)
        private val SW_INS_NOT_SUPPORTED = byteArrayOf(0x6D, 0x00)
        private val SW_FILE_NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())

        const val CLA_CUSTOM: Byte = 0x80.toByte()
        const val INS_EXCHANGE_HELLO: Byte = 0xCA.toByte()
        const val INS_PUSH_CREDENTIALS: Byte = 0xCB.toByte()
        const val CHUNK_SIZE = 200
    }

    private var cachedResponseBytes: ByteArray = ByteArray(0)

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        if (commandApdu == null || commandApdu.size < 4) {
            return SW_WRONG_LENGTH
        }

        // Handle ISO 7816 SELECT AID: 00 A4 04 00 <Lc> <AID> [<Le>]
        if (commandApdu[0] == 0x00.toByte() &&
            commandApdu[1] == 0xA4.toByte() &&
            commandApdu[2] == 0x04.toByte() &&
            commandApdu[3] == 0x00.toByte()
        ) {
            if (commandApdu.size < 5) return SW_WRONG_LENGTH
            val lc = commandApdu[4].toInt() and 0xFF
            if (commandApdu.size < 5 + lc) return SW_WRONG_LENGTH
            val aid = commandApdu.copyOfRange(5, 5 + lc)
            return if (aid.contentEquals(AID)) {
                cachedResponseBytes =
                    ProximitySessionStore.buildHandshakeJson().toByteArray(StandardCharsets.UTF_8)
                SW_OK
            } else {
                SW_FILE_NOT_FOUND
            }
        }

        val cla = commandApdu[0]
        val ins = commandApdu[1]
        val p1 = commandApdu[2].toInt() and 0xFF
        val p2 = commandApdu[3].toInt() and 0xFF

        if (cla != CLA_CUSTOM) {
            return SW_INS_NOT_SUPPORTED
        }

        if (ins == INS_EXCHANGE_HELLO) {
            if (p1 == 0x00) {
                val payload = extractPayload(commandApdu)
                if (payload.isNotEmpty()) {
                    ProximitySessionStore.parseAndNotifyHandshake(
                        "nfc_hce",
                        String(payload, StandardCharsets.UTF_8)
                    )
                }
                cachedResponseBytes =
                    ProximitySessionStore.buildHandshakeJson().toByteArray(StandardCharsets.UTF_8)
                return encodeChunkResponse(0)
            } else if (p1 == 0x01) {
                // Chunk index passed in P2
                return encodeChunkResponse(p2)
            }
        }

        if (ins == INS_PUSH_CREDENTIALS) {
            val payload = extractPayload(commandApdu)
            if (payload.isNotEmpty()) {
                ProximitySessionStore.parseAndNotifyHandshake(
                    "nfc_hce_link",
                    String(payload, StandardCharsets.UTF_8)
                )
            }
            return SW_OK
        }

        return SW_INS_NOT_SUPPORTED
    }

    private fun extractPayload(apdu: ByteArray): ByteArray {
        if (apdu.size <= 5) return ByteArray(0)
        val lc = apdu[4].toInt() and 0xFF
        if (lc == 0 || apdu.size < 5 + lc) return ByteArray(0)
        return apdu.copyOfRange(5, 5 + lc)
    }

    private fun encodeChunkResponse(chunkIndex: Int): ByteArray {
        val offset = chunkIndex * CHUNK_SIZE
        if (offset >= cachedResponseBytes.size) {
            return SW_OK
        }
        val end = minOf(offset + CHUNK_SIZE, cachedResponseBytes.size)
        val slice = cachedResponseBytes.copyOfRange(offset, end)
        val moreRemaining = end < cachedResponseBytes.size
        // SW1=0x61, SW2=nextChunkIndex when more chunks follow; 90 00 on final chunk
        val sw = if (moreRemaining) {
            byteArrayOf(0x61, (chunkIndex + 1).toByte())
        } else {
            SW_OK
        }
        return slice + sw
    }

    override fun onDeactivated(reason: Int) {
        cachedResponseBytes = ByteArray(0)
    }
}
