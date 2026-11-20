package dev.materialdrop.material_drop

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BleProximityManager(
    private val context: Context,
    private val onPeerDiscovered: (Map<String, Any?>) -> Unit,
    private val onGattPayloadReceived: (String) -> Unit,
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("4d440001-7261-6461-722d-6d617464726f")
        val CHAR_HANDSHAKE_UUID: UUID = UUID.fromString("4d440002-7261-6461-722d-6d617464726f")
        const val MANUFACTURER_ID = 0x4D44 // 'MD'
        const val PROTOCOL_VERSION: Byte = 0x01
        private const val RSSI_ALPHA = 0.35
        private const val ROTATION_CHECK_MS = 60_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val btManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter?
        get() = btManager?.adapter

    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var scanning = false
    private var advertising = false
    private var lastAdvertisedHex = ""
    private var capabilityMask: Byte = 0x07 // Bit 0: BLE GATT, Bit 1: Wi-Fi Direct/Hotspot, Bit 2: HCE/NFC

    private val rssiEmaByAddress = ConcurrentHashMap<String, Double>()
    private val rotationRunnable = object : Runnable {
        override fun run() {
            if (advertising) {
                val currentHex = ProximitySessionStore.getEphemeralIdHex()
                if (currentHex != lastAdvertisedHex) {
                    restartAdvertisingPayload()
                }
                mainHandler.postDelayed(this, ROTATION_CHECK_MS)
            }
        }
    }

    fun hasScanPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun hasAdvertisePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_ADVERTISE
            ) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(
                    context, Manifest.permission.BLUETOOTH_CONNECT
                ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun hasConnectPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    fun getStatus(): Map<String, Any?> {
        val hasHardware = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val bt = adapter
        val enabled = bt?.isEnabled == true
        val perms = hasScanPermission() && hasAdvertisePermission()
        val reason = when {
            !hasHardware || bt == null -> "no_ble_hardware"
            !enabled -> "bluetooth_disabled"
            !perms -> "missing_permissions"
            else -> "ready"
        }
        return mapOf(
            "supported" to hasHardware,
            "adapterAvailable" to (hasHardware && bt != null),
            "adapterEnabled" to enabled,
            "permissionsGranted" to perms,
            "scanning" to scanning,
            "advertising" to advertising,
            "reason" to reason,
        )
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertising = true
        }

        override fun onStartFailure(errorCode: Int) {
            advertising = false
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            handleScanResult(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            for (r in results) {
                handleScanResult(r)
            }
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == CHAR_HANDSHAKE_UUID) {
                val allBytes = ProximitySessionStore.buildHandshakeJson()
                    .toByteArray(StandardCharsets.UTF_8)
                val slice = if (offset < allBytes.size) {
                    allBytes.copyOfRange(offset, allBytes.size)
                } else {
                    ByteArray(0)
                }
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
            } else {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (characteristic.uuid == CHAR_HANDSHAKE_UUID && value != null) {
                val jsonStr = String(value, StandardCharsets.UTF_8)
                onGattPayloadReceived(jsonStr)
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
            } else if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun startAdvertising(port: Int, capsMask: Byte = 0x07): Boolean {
        val bt = adapter ?: return false
        if (!bt.isEnabled || !hasAdvertisePermission()) return false
        capabilityMask = capsMask
        ProximitySessionStore.transferPort = port

        ensureGattServer()

        val adv = bt.bluetoothLeAdvertiser ?: return false
        advertiser = adv
        if (advertising) {
            try { adv.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
            advertising = false
        }

        val payload = buildManufacturerPayload(port, capsMask)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val primaryData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(MANUFACTURER_ID, payload)
            .build()

        return try {
            adv.startAdvertising(settings, primaryData, scanResponse, advertiseCallback)
            mainHandler.removeCallbacks(rotationRunnable)
            mainHandler.postDelayed(rotationRunnable, ROTATION_CHECK_MS)
            true
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun restartAdvertisingPayload() {
        val port = ProximitySessionStore.transferPort
        startAdvertising(port, capabilityMask)
    }

    @SuppressLint("MissingPermission")
    fun stopAdvertising() {
        mainHandler.removeCallbacks(rotationRunnable)
        if (advertising && hasAdvertisePermission()) {
            try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        }
        advertising = false
        try {
            if (hasConnectPermission()) gattServer?.close()
        } catch (_: Exception) {}
        gattServer = null
    }

    @SuppressLint("MissingPermission")
    private fun ensureGattServer() {
        if (gattServer != null || !hasConnectPermission()) return
        val server = btManager?.openGattServer(context, gattServerCallback) ?: return
        val service = BluetoothGattService(
            SERVICE_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        val ch = BluetoothGattCharacteristic(
            CHAR_HANDSHAKE_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        service.addCharacteristic(ch)
        server.addService(service)
        gattServer = server
    }

    @SuppressLint("MissingPermission")
    fun startScanning(lowLatency: Boolean = true): Boolean {
        val bt = adapter ?: return false
        if (!bt.isEnabled || !hasScanPermission()) return false
        val leScanner = bt.bluetoothLeScanner ?: return false
        scanner = leScanner
        if (scanning) {
            try { leScanner.stopScan(scanCallback) } catch (_: Exception) {}
        }

        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(
                if (lowLatency) ScanSettings.SCAN_MODE_LOW_LATENCY
                else ScanSettings.SCAN_MODE_BALANCED
            )
            .build()

        return try {
            leScanner.startScan(filters, settings, scanCallback)
            scanning = true
            true
        } catch (_: SecurityException) {
            scanning = false
            false
        } catch (_: Exception) {
            scanning = false
            false
        }
    }

    @SuppressLint("MissingPermission")
    fun stopScanning() {
        if (scanning && hasScanPermission()) {
            try { scanner?.stopScan(scanCallback) } catch (_: Exception) {}
        }
        scanning = false
        rssiEmaByAddress.clear()
    }

    private fun buildManufacturerPayload(port: Int, capsMask: Byte): ByteArray {
        val eph = ProximitySessionStore.getOrRotateEphemeralId()
        lastAdvertisedHex = eph.joinToString("") { "%02X".format(it) }
        val buf = ByteArray(4 + eph.size)
        buf[0] = PROTOCOL_VERSION
        buf[1] = capsMask
        buf[2] = ((port ushr 8) and 0xFF).toByte()
        buf[3] = (port and 0xFF).toByte()
        System.arraycopy(eph, 0, buf, 4, eph.size)
        return buf
    }

    @SuppressLint("MissingPermission")
    private fun handleScanResult(result: ScanResult) {
        val record = result.scanRecord ?: return
        val mfg = record.getManufacturerSpecificData(MANUFACTURER_ID)
        var port = 53317
        var caps = 0
        var ephHex = ""
        if (mfg != null && mfg.size >= 20) {
            caps = mfg[1].toInt() and 0xFF
            port = ((mfg[2].toInt() and 0xFF) shl 8) or (mfg[3].toInt() and 0xFF)
            ephHex = mfg.copyOfRange(4, 20).joinToString("") { "%02X".format(it) }
        }
        if (ephHex == ProximitySessionStore.getEphemeralIdHex()) return

        val addr = result.device?.address ?: return
        val rawRssi = result.rssi.toDouble()
        val prev = rssiEmaByAddress[addr]
        val smoothed = if (prev == null) rawRssi else RSSI_ALPHA * rawRssi + (1.0 - RSSI_ALPHA) * prev
        rssiEmaByAddress[addr] = smoothed
        val rssiInt = smoothed.toInt()
        val zone = when {
            rssiInt >= -55 -> "immediate"
            rssiInt >= -75 -> "near"
            else -> "far"
        }

        val devName = try {
            if (hasConnectPermission()) result.device.name else null
        } catch (_: Exception) {
            null
        } ?: record.deviceName ?: "Nearby Device"

        val key = if (ephHex.isNotEmpty()) ephHex else addr
        mainHandler.post {
            onPeerDiscovered(
                mapOf(
                    "type" to "blePeerFound",
                    "bleAddress" to addr,
                    "ephemeralId" to key,
                    "name" to devName,
                    "port" to port,
                    "capabilities" to caps,
                    "rssi" to rssiInt,
                    "proximityZone" to zone,
                )
            )
        }
    }

    @SuppressLint("MissingPermission")
    fun exchangeGattHandshake(
        bleAddress: String,
        outgoingJson: String?,
        onComplete: (String?, String?) -> Unit,
    ) {
        val bt = adapter
        if (bt == null || !bt.isEnabled || !hasConnectPermission()) {
            onComplete(null, "Bluetooth unavailable or permission missing")
            return
        }
        val device = try {
            bt.getRemoteDevice(bleAddress)
        } catch (e: Exception) {
            onComplete(null, e.message)
            return
        }

        var completed = false
        lateinit var gatt: BluetoothGatt

        val timeoutRunnable = Runnable {
            if (!completed) {
                completed = true
                try { gatt.close() } catch (_: Exception) {}
                onComplete(null, "BLE GATT handshake timed out")
            }
        }
        mainHandler.postDelayed(timeoutRunnable, 10_000L)

        fun finish(payload: String?, err: String?) {
            if (completed) return
            completed = true
            mainHandler.removeCallbacks(timeoutRunnable)
            try { gatt.close() } catch (_: Exception) {}
            onComplete(payload, err)
        }

        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    g.requestMtu(512)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    finish(null, "Disconnected before handshake")
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                g.discoverServices()
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val svc = g.getService(SERVICE_UUID)
                val ch = svc?.getCharacteristic(CHAR_HANDSHAKE_UUID)
                if (ch == null) {
                    finish(null, "Handshake characteristic not found")
                    return
                }
                if (!outgoingJson.isNullOrEmpty()) {
                    val data = outgoingJson.toByteArray(StandardCharsets.UTF_8)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        g.writeCharacteristic(ch, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                    } else {
                        @Suppress("DEPRECATION")
                        ch.value = data
                        @Suppress("DEPRECATION")
                        g.writeCharacteristic(ch)
                    }
                } else {
                    g.readCharacteristic(ch)
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    g.readCharacteristic(characteristic)
                } else {
                    finish(null, "GATT write failed ($status)")
                }
            }

            @Deprecated("Deprecated in API 33")
            override fun onCharacteristicRead(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    @Suppress("DEPRECATION")
                    val bytes = characteristic.value ?: ByteArray(0)
                    finish(String(bytes, StandardCharsets.UTF_8), null)
                } else {
                    finish(null, "GATT read failed ($status)")
                }
            }

            override fun onCharacteristicRead(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int
            ) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    finish(String(value, StandardCharsets.UTF_8), null)
                } else {
                    finish(null, "GATT read failed ($status)")
                }
            }
        }

        gatt = device.connectGatt(context, false, cb, BluetoothDevice.TRANSPORT_LE)
    }

    fun cleanup() {
        stopScanning()
        stopAdvertising()
    }
}
