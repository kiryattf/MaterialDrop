package dev.materialdrop.material_drop

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Manages router-free direct Wi-Fi links on Android:
 * - Host mode: LocalOnlyHotspot (primary) or WifiP2pManager group (fallback)
 * - Client mode: WifiNetworkSpecifier + ConnectivityManager.bindProcessToNetwork(network)
 *   so cellular internet stays intact while P2P sockets use the direct Wi-Fi link.
 */
class WifiDirectManager(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val wifiManager: WifiManager? =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val connectivityManager: ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val p2pManager: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager

    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var p2pGroupCreated = false
    private var boundNetworkCallback: ConnectivityManager.NetworkCallback? = null

    fun hasNearbyWifiPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.NEARBY_WIFI_DEVICES
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    @SuppressLint("MissingPermission")
    fun startDirectHost(onComplete: (Map<String, Any?>?, String?) -> Unit) {
        if (!hasNearbyWifiPermission()) {
            onComplete(null, "Missing NEARBY_WIFI_DEVICES / location permission")
            return
        }
        val wm = wifiManager
        if (wm == null) {
            startP2pGroupFallback(onComplete)
            return
        }

        hotspotReservation?.close()
        hotspotReservation = null

        try {
            wm.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation?) {
                        if (reservation == null) {
                            startP2pGroupFallback(onComplete)
                            return
                        }
                        hotspotReservation = reservation
                        val (ssid, pass) = extractHotspotCredentials(reservation)
                        if (ssid.isEmpty() || pass.isEmpty()) {
                            reservation.close()
                            hotspotReservation = null
                            startP2pGroupFallback(onComplete)
                            return
                        }
                        // Allow brief settle for AP interface IP assignment
                        mainHandler.postDelayed({
                            val ip = findDirectInterfaceIp() ?: "192.168.43.1"
                            ProximitySessionStore.updateDirectWifi(ssid, pass, ip)
                            onComplete(
                                mapOf(
                                    "mode" to "hotspot",
                                    "ssid" to ssid,
                                    "passphrase" to pass,
                                    "hostIp" to ip,
                                ),
                                null,
                            )
                        }, 350L)
                    }

                    override fun onFailed(reason: Int) {
                        startP2pGroupFallback(onComplete)
                    }
                },
                mainHandler,
            )
        } catch (_: SecurityException) {
            onComplete(null, "SecurityException starting LocalOnlyHotspot")
        } catch (_: Exception) {
            startP2pGroupFallback(onComplete)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startP2pGroupFallback(onComplete: (Map<String, Any?>?, String?) -> Unit) {
        val p2p = p2pManager
        if (p2p == null || !hasNearbyWifiPermission()) {
            onComplete(null, "Wi-Fi Direct / LocalOnlyHotspot unavailable")
            return
        }
        val channel = p2pChannel ?: p2p.initialize(context, mainHandler.looper, null).also {
            p2pChannel = it
        }
        if (channel == null) {
            onComplete(null, "Failed to initialize WifiP2p channel")
            return
        }
        p2p.createGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                p2pGroupCreated = true
                mainHandler.postDelayed({
                    p2p.requestGroupInfo(channel) { group ->
                        val ssid = group?.networkName ?: ""
                        val pass = group?.passphrase ?: ""
                        if (ssid.isEmpty() || pass.isEmpty()) {
                            onComplete(null, "WifiP2p group created without credentials")
                            return@requestGroupInfo
                        }
                        val ip = findDirectInterfaceIp() ?: "192.168.49.1"
                        ProximitySessionStore.updateDirectWifi(ssid, pass, ip)
                        onComplete(
                            mapOf(
                                "mode" to "wifi_p2p",
                                "ssid" to ssid,
                                "passphrase" to pass,
                                "hostIp" to ip,
                            ),
                            null,
                        )
                    }
                }, 400L)
            }

            override fun onFailure(reason: Int) {
                onComplete(null, "WifiP2p createGroup failed ($reason)")
            }
        })
    }

    @Suppress("DEPRECATION")
    private fun extractHotspotCredentials(
        reservation: WifiManager.LocalOnlyHotspotReservation
    ): Pair<String, String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val softAp = reservation.softApConfiguration
            if (softAp != null) {
                val rawSsid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    softAp.wifiSsid?.bytes?.toString(Charsets.UTF_8)
                        ?: softAp.wifiSsid?.toString()?.removeSurrounding("\"")
                        ?: ""
                } else {
                    softAp.ssid ?: ""
                }
                val pass = softAp.passphrase ?: ""
                return rawSsid to pass
            }
        }
        val legacy = reservation.wifiConfiguration
        val ssid = legacy?.SSID?.removeSurrounding("\"") ?: ""
        val pass = legacy?.preSharedKey ?: ""
        return ssid to pass
    }

    @SuppressLint("MissingPermission")
    fun stopDirectHost() {
        hotspotReservation?.close()
        hotspotReservation = null
        if (p2pGroupCreated && p2pManager != null && p2pChannel != null) {
            try {
                p2pManager.removeGroup(p2pChannel, null)
            } catch (_: Exception) {}
        }
        p2pGroupCreated = false
        ProximitySessionStore.clearDirectWifi()
    }

    /**
     * Connects to a peer's LocalOnlyHotspot / WifiP2p GO SSID on Android 10+ and binds
     * only this process's sockets via ConnectivityManager.bindProcessToNetwork(network)
     * so mobile cellular data remains intact.
     */
    fun connectDirectWifi(
        ssid: String,
        passphrase: String,
        onComplete: (Map<String, Any?>?, String?) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            onComplete(null, "WifiNetworkSpecifier requires Android 10+")
            return
        }
        val cm = connectivityManager
        if (cm == null) {
            onComplete(null, "ConnectivityManager unavailable")
            return
        }
        disconnectDirectWifi()

        var finished = false
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (finished) return
                finished = true
                cm.bindProcessToNetwork(network)
                val gatewayIp = extractGatewayIp(cm.getLinkProperties(network))
                    ?: "192.168.49.1"
                mainHandler.post {
                    onComplete(
                        mapOf(
                            "connected" to true,
                            "gatewayIp" to gatewayIp,
                        ),
                        null,
                    )
                }
            }

            override fun onUnavailable() {
                if (finished) return
                finished = true
                cm.bindProcessToNetwork(null)
                mainHandler.post {
                    onComplete(null, "Direct Wi-Fi connection unavailable")
                }
            }

            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
            }
        }

        boundNetworkCallback = callback
        try {
            cm.requestNetwork(request, callback, 25_000)
        } catch (e: Exception) {
            boundNetworkCallback = null
            onComplete(null, e.message)
        }
    }

    fun disconnectDirectWifi() {
        val cm = connectivityManager ?: return
        cm.bindProcessToNetwork(null)
        val cb = boundNetworkCallback
        boundNetworkCallback = null
        if (cb != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (_: Exception) {}
        }
    }

    private fun extractGatewayIp(props: LinkProperties?): String? {
        if (props == null) return null
        for (route in props.routes) {
            val gw = route.gateway
            if (gw is Inet4Address && !gw.isAnyLocalAddress && !gw.isLoopbackAddress) {
                return gw.hostAddress
            }
        }
        return null
    }

    private fun findDirectInterfaceIp(): String? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
            val candidates = mutableListOf<Pair<String, String>>()
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val ifName = iface.name.lowercase()
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress ?: continue
                        candidates.add(ifName to ip)
                    }
                }
            }
            candidates.firstOrNull { (name, ip) ->
                name.contains("p2p") || name.contains("ap") || ip.startsWith("192.168.49.") || ip.startsWith("192.168.43.")
            }?.second ?: candidates.firstOrNull { (name, _) -> name.contains("wlan") }?.second
        } catch (_: Exception) {
            null
        }
    }

    fun cleanup() {
        disconnectDirectWifi()
        stopDirectHost()
    }
}
