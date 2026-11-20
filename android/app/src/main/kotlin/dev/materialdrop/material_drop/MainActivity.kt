package dev.materialdrop.material_drop

import android.Manifest
import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private val platformChannelName = "dev.materialdrop.flutter/platform"
    private val shareEventChannelName = "dev.materialdrop.flutter/share_events"
    private val nsdEventChannelName = "dev.materialdrop.flutter/nsd_events"
    private val proximityChannelName = "dev.materialdrop.flutter/proximity"
    private val proximityEventChannelName = "dev.materialdrop.flutter/proximity_events"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()

    private var multicastLock: WifiManager.MulticastLock? = null
    private var initialSharePayload: Map<String, Any?>? = null
    private var shareEventSink: EventChannel.EventSink? = null
    private var nsdEventSink: EventChannel.EventSink? = null
    private var proximityEventSink: EventChannel.EventSink? = null

    private lateinit var bleManager: BleProximityManager
    private lateinit var wifiDirectManager: WifiDirectManager
    private var nfcAdapter: NfcAdapter? = null
    private var nfcReaderRequested = false
    private var pendingPermResult: MethodChannel.Result? = null

    private val openStreams = ConcurrentHashMap<Int, InputStream>()
    private val streamIdGen = AtomicInteger(1)

    // NSD state
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    @Volatile
    private var registeredNsdName: String? = null
    private val resolveQueue = ConcurrentLinkedQueue<NsdServiceInfo>()
    private val isResolving = AtomicBoolean(false)
    private val isNsdDiscovering = AtomicBoolean(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        bleManager = BleProximityManager(
            context = applicationContext,
            onPeerDiscovered = { eventMap ->
                mainHandler.post { proximityEventSink?.success(eventMap) }
            },
            onGattPayloadReceived = { jsonStr ->
                ProximitySessionStore.parseAndNotifyHandshake("ble_gatt", jsonStr)
            },
        )
        wifiDirectManager = WifiDirectManager(applicationContext)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
        ProximitySessionStore.onPeerHandshakeListener = { source, peerMap ->
            mainHandler.post {
                proximityEventSink?.success(
                    hashMapOf<String, Any?>(
                        "type" to "handshake",
                        "source" to source,
                        "peer" to peerMap,
                    )
                )
            }
        }

        if (initialSharePayload == null) {
            initialSharePayload = parseShareIntent(intent)
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, proximityEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    proximityEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    proximityEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, proximityChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getProximityStatus" -> {
                        val bleStatus = bleManager.getStatus()
                        val nfcSupported = packageManager.hasSystemFeature(PackageManager.FEATURE_NFC)
                        val nfcEnabled = nfcAdapter?.isEnabled == true
                        val wifiP2pSupported = packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
                        result.success(
                            mapOf(
                                "supported" to true,
                                "ble" to bleStatus,
                                "nfcSupported" to nfcSupported,
                                "nfcEnabled" to nfcEnabled,
                                "nfcReaderActive" to nfcReaderRequested,
                                "wifiDirectSupported" to wifiP2pSupported,
                                "wifiDirectPermissionsGranted" to wifiDirectManager.hasNearbyWifiPermission(),
                                "ephemeralId" to ProximitySessionStore.getEphemeralIdHex(),
                            )
                        )
                    }

                    "requestProximityPermissions" -> {
                        requestProximityPermissionsInternal(result)
                    }

                    "updateSessionMetadata" -> {
                        call.argument<String>("deviceName")?.let {
                            ProximitySessionStore.deviceName = it
                        }
                        call.argument<Int>("port")?.let {
                            ProximitySessionStore.transferPort = it
                        }
                        call.argument<String>("fingerprint")?.let {
                            ProximitySessionStore.tlsFingerprint = it
                        }
                        call.argument<String>("irohTicket")?.let {
                            ProximitySessionStore.irohTicket = it
                        }
                        result.success(true)
                    }

                    "startBleDiscovery" -> {
                        val port = call.argument<Int>("port") ?: 53317
                        val lowLatency = call.argument<Boolean>("lowLatency") ?: true
                        val advOk = bleManager.startAdvertising(port)
                        val scanOk = bleManager.startScanning(lowLatency)
                        result.success(
                            mapOf(
                                "advertising" to advOk,
                                "scanning" to scanOk,
                            )
                        )
                    }

                    "stopBleDiscovery" -> {
                        bleManager.stopScanning()
                        bleManager.stopAdvertising()
                        result.success(true)
                    }

                    "exchangeGattHandshake" -> {
                        val addr = call.argument<String>("bleAddress") ?: ""
                        val outgoingJson = call.argument<String>("outgoingJson")
                        if (addr.isEmpty()) {
                            result.error("INVALID_ADDR", "BLE address is empty", null)
                            return@setMethodCallHandler
                        }
                        bleManager.exchangeGattHandshake(addr, outgoingJson) { payload, err ->
                            mainHandler.post {
                                if (payload != null) {
                                    result.success(payload)
                                } else {
                                    result.error("GATT_ERROR", err ?: "GATT failed", null)
                                }
                            }
                        }
                    }

                    "setNfcReaderEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        nfcReaderRequested = enabled
                        if (enabled) enableNfcReaderMode() else disableNfcReaderMode()
                        result.success(nfcAdapter?.isEnabled == true)
                    }

                    "startDirectWifiHost" -> {
                        wifiDirectManager.startDirectHost { info, err ->
                            mainHandler.post {
                                if (info != null) {
                                    result.success(info)
                                } else {
                                    result.error("WIFI_HOST_ERROR", err ?: "Host failed", null)
                                }
                            }
                        }
                    }

                    "stopDirectWifiHost" -> {
                        wifiDirectManager.stopDirectHost()
                        result.success(true)
                    }

                    "connectDirectWifi" -> {
                        val ssid = call.argument<String>("ssid") ?: ""
                        val pass = call.argument<String>("passphrase") ?: ""
                        if (ssid.isEmpty() || pass.isEmpty()) {
                            result.error("INVALID_CREDS", "Missing SSID/passphrase", null)
                            return@setMethodCallHandler
                        }
                        wifiDirectManager.connectDirectWifi(ssid, pass) { resMap, err ->
                            if (resMap != null) {
                                result.success(resMap)
                            } else {
                                result.error("WIFI_CONNECT_ERROR", err ?: "Connect failed", null)
                            }
                        }
                    }

                    "disconnectDirectWifi" -> {
                        wifiDirectManager.disconnectDirectWifi()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, shareEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    shareEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    shareEventSink = null
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, nsdEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    nsdEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    nsdEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, platformChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceInfo" -> {
                        result.success(
                            mapOf(
                                "model" to (Build.MODEL ?: "Android Phone"),
                                "manufacturer" to (Build.MANUFACTURER ?: "Android"),
                                "sdkInt" to Build.VERSION.SDK_INT
                            )
                        )
                    }

                    "acquireMulticastLock" -> {
                        try {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                            if (multicastLock == null) {
                                multicastLock = wifi?.createMulticastLock("MaterialDropMulticast")
                                multicastLock?.setReferenceCounted(false)
                            }
                            if (multicastLock?.isHeld == false) {
                                multicastLock?.acquire()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "releaseMulticastLock" -> {
                        try {
                            if (multicastLock?.isHeld == true) {
                                multicastLock?.release()
                            }
                        } catch (_: Exception) {}
                        result.success(true)
                    }

                    "getInitialSharedFiles" -> {
                        val payload = initialSharePayload
                        initialSharePayload = null
                        result.success(payload)
                    }

                    "openContentStream" -> {
                        val uriStr = call.argument<String>("uri")
                        if (uriStr.isNullOrEmpty()) {
                            result.error("INVALID_URI", "URI is empty", null)
                            return@setMethodCallHandler
                        }
                        ioExecutor.execute {
                            try {
                                val uri = Uri.parse(uriStr)
                                val stream = if (uri.scheme == "file") {
                                    FileInputStream(File(uri.path ?: ""))
                                } else {
                                    contentResolver.openInputStream(uri)
                                }
                                if (stream == null) {
                                    mainHandler.post {
                                        result.error("OPEN_FAILED", "Unable to open input stream", null)
                                    }
                                } else {
                                    val id = streamIdGen.getAndIncrement()
                                    openStreams[id] = stream
                                    mainHandler.post { result.success(id) }
                                }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("OPEN_FAILED", e.message, null)
                                }
                            }
                        }
                    }

                    "readContentChunk" -> {
                        val handleId = call.argument<Int>("handleId") ?: -1
                        val maxBytes = (call.argument<Int>("maxBytes") ?: 65536).coerceIn(1024, 262144)
                        val stream = openStreams[handleId]
                        if (stream == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        ioExecutor.execute {
                            try {
                                val buf = ByteArray(maxBytes)
                                val read = stream.read(buf, 0, maxBytes)
                                if (read <= 0) {
                                    try { stream.close() } catch (_: Exception) {}
                                    openStreams.remove(handleId)
                                    mainHandler.post { result.success(null) }
                                } else {
                                    val out = if (read == buf.size) buf else buf.copyOf(read)
                                    mainHandler.post { result.success(out) }
                                }
                            } catch (e: Exception) {
                                try { stream.close() } catch (_: Exception) {}
                                openStreams.remove(handleId)
                                mainHandler.post {
                                    result.error("READ_FAILED", e.message, null)
                                }
                            }
                        }
                    }

                    "closeContentStream" -> {
                        val handleId = call.argument<Int>("handleId") ?: -1
                        val stream = openStreams.remove(handleId)
                        try { stream?.close() } catch (_: Exception) {}
                        result.success(true)
                    }

                    "saveToDownloads" -> {
                        val tempPath = call.argument<String>("tempPath")
                        val fileName = call.argument<String>("fileName") ?: "file"
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        if (tempPath.isNullOrEmpty()) {
                            result.error("INVALID_PATH", "tempPath is empty", null)
                            return@setMethodCallHandler
                        }
                        ioExecutor.execute {
                            try {
                                val saved = saveFileToDownloads(File(tempPath), fileName, mimeType)
                                mainHandler.post { result.success(saved) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("SAVE_FAILED", e.message, null)
                                }
                            }
                        }
                    }

                    "openFile" -> {
                        val pathOrUri = call.argument<String>("pathOrUri") ?: ""
                        val mimeType = call.argument<String>("mimeType") ?: "*/*"
                        try {
                            openFileExternal(pathOrUri, mimeType)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FILE_FAILED", e.message, null)
                        }
                    }

                    "openDownloadsFolder" -> {
                        try {
                            val intent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val granted = ContextCompat.checkSelfPermission(
                                this, Manifest.permission.POST_NOTIFICATIONS
                            ) == PackageManager.PERMISSION_GRANTED
                            if (!granted) {
                                ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                    2001
                                )
                            }
                            result.success(granted)
                        } else {
                            result.success(true)
                        }
                    }

                    "startForegroundTransfer" -> {
                        val title = call.argument<String>("title") ?: "MaterialDrop"
                        val text = call.argument<String>("text") ?: "Transferring files…"
                        try {
                            val svcIntent = Intent(this, TransferForegroundService::class.java).apply {
                                putExtra(TransferForegroundService.EXTRA_TITLE, title)
                                putExtra(TransferForegroundService.EXTRA_TEXT, text)
                            }
                            ContextCompat.startForegroundService(this, svcIntent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "stopForegroundTransfer" -> {
                        try {
                            stopService(Intent(this, TransferForegroundService::class.java))
                        } catch (_: Exception) {}
                        result.success(true)
                    }

                    "startNsdDiscovery" -> {
                        startNsdDiscoveryInternal()
                        result.success(true)
                    }

                    "stopNsdDiscovery" -> {
                        stopNsdDiscoveryInternal()
                        result.success(true)
                    }

                    "registerNsdService" -> {
                        val instanceName = call.argument<String>("instanceName") ?: ""
                        val port = call.argument<Int>("port") ?: 0
                        val txtN = call.argument<String>("txtN") ?: ""
                        val txtIpv4 = call.argument<String>("txtIpv4") ?: ""
                        registerNsdServiceInternal(instanceName, port, txtN, txtIpv4)
                        result.success(true)
                    }

                    "unregisterNsdService" -> {
                        unregisterNsdServiceInternal()
                        result.success(true)
                    }

                    "finishActivity" -> {
                        finish()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = parseShareIntent(intent)
        if (payload != null) {
            if (shareEventSink != null) {
                mainHandler.post { shareEventSink?.success(payload) }
            } else {
                initialSharePayload = payload
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (nfcReaderRequested) {
            enableNfcReaderMode()
        }
    }

    override fun onPause() {
        disableNfcReaderMode()
        super.onPause()
    }

    override fun onDestroy() {
        disableNfcReaderMode()
        if (::bleManager.isInitialized) bleManager.cleanup()
        if (::wifiDirectManager.isInitialized) wifiDirectManager.cleanup()
        ProximitySessionStore.onPeerHandshakeListener = null
        stopNsdDiscoveryInternal()
        unregisterNsdServiceInternal()
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {}
        for ((_, s) in openStreams) {
            try { s.close() } catch (_: Exception) {}
        }
        openStreams.clear()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun parseShareIntent(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return null
        }

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            val streamUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            if (streamUri != null) {
                uris.add(streamUri)
            } else {
                intent.clipData?.let { cd ->
                    if (cd.itemCount > 0) {
                        cd.getItemAt(0).uri?.let { uris.add(it) }
                    }
                }
            }
            if (uris.isEmpty() && intent.data != null) {
                uris.add(intent.data!!)
            }
        } else {
            val streamList = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            }
            if (!streamList.isNullOrEmpty()) {
                uris.addAll(streamList)
            } else {
                intent.clipData?.let { cd ->
                    for (i in 0 until cd.itemCount) {
                        cd.getItemAt(i).uri?.let { uris.add(it) }
                    }
                }
            }
        }

        val fileMaps = uris.mapNotNull { queryUriMetadata(it) }
        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)

        if (fileMaps.isEmpty() && sharedText.isNullOrEmpty()) {
            return null
        }

        return mapOf(
            "isShareSheet" to true,
            "files" to fileMaps,
            "sharedText" to sharedText
        )
    }

    private fun queryUriMetadata(uri: Uri): Map<String, Any?>? {
        return try {
            var name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
            var size = 0L
            val mime = contentResolver.getType(uri) ?: "application/octet-stream"
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val ni = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val si = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (ni != -1) name = cursor.getString(ni) ?: name
                    if (si != -1) size = cursor.getLong(si)
                }
            }
            if (size == 0L && uri.scheme == "file") {
                uri.path?.let { p ->
                    val f = File(p)
                    if (f.exists()) size = f.length()
                }
            }
            mapOf(
                "uri" to uri.toString(),
                "name" to name,
                "size" to size,
                "mimeType" to mime
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun saveFileToDownloads(tempFile: File, fileName: String, mimeType: String): String {
        val safeName = fileName.ifEmpty { "unnamed_file" }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                if (mimeType.isNotEmpty() && mimeType != "application/octet-stream") {
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                }
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Failed to insert MediaStore download entry")
            try {
                contentResolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(tempFile).use { input ->
                        input.copyTo(out, 64 * 1024)
                    }
                    out.flush()
                } ?: throw IllegalStateException("Failed to open MediaStore output stream")

                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                tempFile.delete()
                uri.toString()
            } catch (e: Exception) {
                try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
        } else {
            @Suppress("DEPRECATION")
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            downloadsDir.mkdirs()
            val destFile = uniqueLocalFile(downloadsDir, safeName)
            FileInputStream(tempFile).use { input ->
                FileOutputStream(destFile).use { out ->
                    input.copyTo(out, 64 * 1024)
                    out.flush()
                }
            }
            tempFile.delete()
            MediaScannerConnection.scanFile(this, arrayOf(destFile.absolutePath), null, null)
            destFile.absolutePath
        }
    }

    private fun uniqueLocalFile(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dotIdx = name.lastIndexOf('.')
        val stem = if (dotIdx > 0) name.substring(0, dotIdx) else name
        val ext = if (dotIdx > 0) name.substring(dotIdx) else ""
        var i = 1
        while (candidate.exists()) {
            candidate = File(dir, "$stem ($i)$ext")
            i++
        }
        return candidate
    }

    private fun openFileExternal(pathOrUri: String, mimeType: String) {
        val uri = if (pathOrUri.startsWith("content://") || pathOrUri.startsWith("file://")) {
            Uri.parse(pathOrUri)
        } else {
            FileProvider.getUriForFile(this, "$packageName.files", File(pathOrUri))
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType.ifEmpty { "*/*" })
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(Intent.createChooser(intent, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        } catch (_: Exception) {
            intent.setDataAndType(uri, "*/*")
            startActivity(intent)
        }
    }

    private fun ensureNsdManager(): NsdManager {
        if (nsdManager == null) {
            nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
        }
        return nsdManager!!
    }

    private fun startNsdDiscoveryInternal() {
        if (isNsdDiscovering.getAndSet(true)) return
        val manager = ensureNsdManager()
        val serviceType = "_FC9F5ED42C8A._tcp."

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}

            override fun onServiceFound(service: NsdServiceInfo) {
                val ownName = registeredNsdName
                if (ownName != null && service.serviceName == ownName) return
                if (service.serviceType.contains("FC9F5ED42C8A", ignoreCase = true)) {
                    resolveQueue.offer(service)
                    drainResolveQueue()
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                mainHandler.post {
                    nsdEventSink?.success(
                        mapOf(
                            "type" to "lost",
                            "instanceName" to service.serviceName
                        )
                    )
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                isNsdDiscovering.set(false)
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                isNsdDiscovering.set(false)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                isNsdDiscovering.set(false)
            }
        }
        discoveryListener = listener
        try {
            manager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            isNsdDiscovering.set(false)
            discoveryListener = null
        }
    }

    @Suppress("DEPRECATION")
    private fun drainResolveQueue() {
        if (!isNsdDiscovering.get()) return
        if (!isResolving.compareAndSet(false, true)) return
        val next = resolveQueue.poll()
        if (next == null) {
            isResolving.set(false)
            return
        }
        val manager = ensureNsdManager()
        try {
            manager.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    isResolving.set(false)
                    drainResolveQueue()
                }

                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    val hostAddr = resolved.host?.hostAddress ?: ""
                    val attrs = resolved.attributes
                    val txtN = attrs["n"]?.let { String(it, Charsets.UTF_8) } ?: ""
                    val txtIpv4 = attrs["IPv4"]?.let { String(it, Charsets.UTF_8) } ?: ""

                    mainHandler.post {
                        nsdEventSink?.success(
                            mapOf(
                                "type" to "found",
                                "instanceName" to resolved.serviceName,
                                "host" to hostAddr,
                                "port" to resolved.port,
                                "txtN" to txtN,
                                "txtIpv4" to txtIpv4
                            )
                        )
                    }
                    isResolving.set(false)
                    drainResolveQueue()
                }
            })
        } catch (_: Exception) {
            isResolving.set(false)
            drainResolveQueue()
        }
    }

    private fun stopNsdDiscoveryInternal() {
        isNsdDiscovering.set(false)
        resolveQueue.clear()
        val listener = discoveryListener
        discoveryListener = null
        if (listener != null) {
            try {
                nsdManager?.stopServiceDiscovery(listener)
            } catch (_: Exception) {}
        }
    }

    private fun registerNsdServiceInternal(instanceName: String, port: Int, txtN: String, txtIpv4: String) {
        unregisterNsdServiceInternal()
        if (instanceName.isEmpty() || port <= 0) return
        val manager = ensureNsdManager()
        val info = NsdServiceInfo().apply {
            serviceName = instanceName
            serviceType = "_FC9F5ED42C8A._tcp."
            setPort(port)
            if (txtN.isNotEmpty()) setAttribute("n", txtN)
            if (txtIpv4.isNotEmpty()) setAttribute("IPv4", txtIpv4)
        }
        registeredNsdName = instanceName
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                registeredNsdName = serviceInfo.serviceName
            }
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                registeredNsdName = null
            }
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        registrationListener = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            registrationListener = null
            registeredNsdName = null
        }
    }

    private fun requestProximityPermissionsInternal(result: MethodChannel.Result) {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            needed.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            needed.add(Manifest.permission.BLUETOOTH_SCAN)
            needed.add(Manifest.permission.BLUETOOTH_ADVERTISE)
            needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingPermResult?.success(false)
        pendingPermResult = result
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), 2002)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 2002) {
            val allGranted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            val cb = pendingPermResult
            pendingPermResult = null
            cb?.success(allGranted)
        }
    }

    private fun enableNfcReaderMode() {
        val adapter = nfcAdapter ?: return
        if (!adapter.isEnabled) return
        val flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        try {
            adapter.enableReaderMode(this, { tag -> handleNfcTagDiscovered(tag) }, flags, null)
        } catch (_: Exception) {}
    }

    private fun disableNfcReaderMode() {
        try {
            nfcAdapter?.disableReaderMode(this)
        } catch (_: Exception) {}
    }

    private fun handleNfcTagDiscovered(tag: Tag) {
        val isoDep = IsoDep.get(tag) ?: return
        ioExecutor.execute {
            try {
                isoDep.connect()
                isoDep.timeout = 4000

                // 1. SELECT AID: F04D415444524F50
                val aid = MaterialDropApduService.AID
                val selectApdu = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, aid.size.toByte()) + aid + byteArrayOf(0x00)
                val selectResp = isoDep.transceive(selectApdu)
                if (!isStatusOk(selectResp)) return@execute

                // 2. EXCHANGE_HELLO (with automatic chunked continuation on 0x61 <idx>)
                val localHello = ProximitySessionStore.buildHandshakeJson().toByteArray(StandardCharsets.UTF_8)
                val body = if (localHello.size <= 240) localHello else localHello.copyOf(240)
                val exchangeApdu = byteArrayOf(
                    MaterialDropApduService.CLA_CUSTOM,
                    MaterialDropApduService.INS_EXCHANGE_HELLO,
                    0x00,
                    0x00,
                    body.size.toByte()
                ) + body + byteArrayOf(0x00)

                val full = ByteArrayOutputStream()
                var resp = isoDep.transceive(exchangeApdu)
                while (resp.size >= 2) {
                    val sw1 = resp[resp.size - 2].toInt() and 0xFF
                    val sw2 = resp[resp.size - 1].toInt() and 0xFF
                    full.write(resp, 0, resp.size - 2)
                    if (sw1 == 0x90 && sw2 == 0x00) {
                        break
                    } else if (sw1 == 0x61) {
                        val nextApdu = byteArrayOf(
                            MaterialDropApduService.CLA_CUSTOM,
                            MaterialDropApduService.INS_EXCHANGE_HELLO,
                            0x01,
                            sw2.toByte(),
                            0x00
                        )
                        resp = isoDep.transceive(nextApdu)
                    } else {
                        return@execute
                    }
                }
                val remoteJson = String(full.toByteArray(), StandardCharsets.UTF_8)
                if (remoteJson.isNotEmpty()) {
                    ProximitySessionStore.parseAndNotifyHandshake("nfc_reader", remoteJson)
                }
            } catch (_: Exception) {
            } finally {
                try { isoDep.close() } catch (_: Exception) {}
            }
        }
    }

    private fun isStatusOk(apduResp: ByteArray): Boolean {
        return apduResp.size >= 2 &&
            (apduResp[apduResp.size - 2].toInt() and 0xFF) == 0x90 &&
            (apduResp[apduResp.size - 1].toInt() and 0xFF) == 0x00
    }

    private fun unregisterNsdServiceInternal() {
        registeredNsdName = null
        val listener = registrationListener
        registrationListener = null
        if (listener != null) {
            try {
                nsdManager?.unregisterService(listener)
            } catch (_: Exception) {}
        }
    }
}
