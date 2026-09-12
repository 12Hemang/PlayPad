package com.example.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

@SuppressLint("MissingPermission")
class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val METHOD_CHANNEL = "com.example.ble/gamepad"
        private const val EVENT_CHANNEL = "com.example.ble/events"
        private const val PREFS_NAME = "ble_gamepad_prefs"
        private const val KEY_LAST_DEVICE_ADDR = "last_device_address"
        private const val KEY_LAST_DEVICE_NAME = "last_device_name"
        private const val PERMISSION_REQUEST_CODE = 1001
        private const val REQUEST_CODE_PICK_ROM = 1002

        // Standard USB HID Gamepad Report Descriptor (NES/N64 fallback)
        private val DEFAULT_NES_DESCRIPTOR = byteArrayOf(
            0x05.toByte(), 0x01.toByte(), // USAGE_PAGE (Generic Desktop)
            0x09.toByte(), 0x05.toByte(), // USAGE (Game Pad)
            0xA1.toByte(), 0x01.toByte(), // COLLECTION (Application)
            0x85.toByte(), 0x01.toByte(), //   REPORT_ID (1)

            // X, Y Axes (Left Stick / Direction)
            0x05.toByte(), 0x01.toByte(),
            0x09.toByte(), 0x30.toByte(),
            0x09.toByte(), 0x31.toByte(),
            0x15.toByte(), 0x00.toByte(),
            0x26.toByte(), 0xFF.toByte(), 0x00.toByte(),
            0x75.toByte(), 0x08.toByte(),
            0x95.toByte(), 0x02.toByte(),
            0x81.toByte(), 0x02.toByte(),

            // Hat Switch (D-Pad)
            0x05.toByte(), 0x01.toByte(),
            0x09.toByte(), 0x39.toByte(),
            0x15.toByte(), 0x01.toByte(),
            0x25.toByte(), 0x08.toByte(),
            0x35.toByte(), 0x00.toByte(),
            0x46.toByte(), 0x3B.toByte(), 0x01.toByte(),
            0x65.toByte(), 0x14.toByte(),
            0x75.toByte(), 0x04.toByte(),
            0x95.toByte(), 0x01.toByte(),
            0x81.toByte(), 0x42.toByte(),
            0x75.toByte(), 0x04.toByte(),
            0x95.toByte(), 0x01.toByte(),
            0x81.toByte(), 0x03.toByte(),

            // 16 Buttons
            0x05.toByte(), 0x09.toByte(),
            0x19.toByte(), 0x01.toByte(),
            0x29.toByte(), 0x10.toByte(),
            0x15.toByte(), 0x00.toByte(),
            0x25.toByte(), 0x01.toByte(),
            0x75.toByte(), 0x01.toByte(),
            0x95.toByte(), 0x10.toByte(),
            0x81.toByte(), 0x02.toByte(),

            0xC0.toByte() // END_COLLECTION
        )
    }

    private var methodChannel: MethodChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPickRomResult: MethodChannel.Result? = null

    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var hidDevice: BluetoothHidDevice? = null
    private var connectedHost: BluetoothDevice? = null
    private var isAppRegistered = false

    // Cached descriptor and name for persistent auto-registration (initialized with standard NES descriptor)
    private var cachedDescriptor: ByteArray? = DEFAULT_NES_DESCRIPTOR
    private var cachedAppName: String = "NES Gamepad"

    private lateinit var prefs: SharedPreferences

    private val serviceListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
            if (profile == BluetoothProfile.HID_DEVICE) {
                hidDevice = proxy as? BluetoothHidDevice
                log("INFO", "HID", "Bluetooth HID Device profile proxy connected and ready for user registration.")
                sendEvent(mapOf("event" to "hid_proxy_connected"))
            }
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile == BluetoothProfile.HID_DEVICE) {
                hidDevice = null
                isAppRegistered = false
                log("WARN", "HID", "Bluetooth HID Device profile proxy disconnected.")
                sendEvent(mapOf("event" to "hid_proxy_disconnected"))
            }
        }
    }

    private val hidCallback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            isAppRegistered = registered
            val status = if (registered) "REGISTERED" else "UNREGISTERED"
            log("INFO", "HID", "HID Gamepad App status changed: $status")
            sendEvent(
                mapOf(
                    "event" to "app_status",
                    "registered" to registered
                )
            )
        }

        override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
            val devName = device?.name ?: "Unknown"
            val devAddr = device?.address ?: "N/A"
            val stateStr = when (state) {
                BluetoothProfile.STATE_CONNECTED -> "connected"
                BluetoothProfile.STATE_CONNECTING -> "connecting"
                BluetoothProfile.STATE_DISCONNECTING -> "disconnecting"
                BluetoothProfile.STATE_DISCONNECTED -> "disconnected"
                else -> "unknown ($state)"
            }
            log("INFO", "HID", "[HID Event] Host connection state changed for '$devName' ($devAddr): $stateStr")

            if (state == BluetoothProfile.STATE_CONNECTED) {
                connectedHost = device
                if (device != null) {
                    saveLastDevice(device)
                }
            } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                if (connectedHost?.address == device?.address) {
                    connectedHost = null
                }
            }

            sendEvent(
                mapOf(
                    "event" to "connection_state",
                    "state" to when (state) {
                        BluetoothProfile.STATE_CONNECTED -> "connected"
                        BluetoothProfile.STATE_CONNECTING -> "connecting"
                        BluetoothProfile.STATE_DISCONNECTING -> "disconnecting"
                        else -> "disconnected"
                    },
                    "deviceName" to devName,
                    "deviceAddress" to devAddr
                )
            )
        }

        override fun onGetReport(device: BluetoothDevice?, type: Byte, id: Byte, bufferSize: Int) {
            log("DEBUG", "HID", "onGetReport: type=$type id=$id bufferSize=$bufferSize")
            hidDevice?.replyReport(device, type, id, ByteArray(bufferSize))
        }

        override fun onSetReport(device: BluetoothDevice?, type: Byte, id: Byte, data: ByteArray?) {
            log("DEBUG", "HID", "onSetReport: type=$type id=$id dataSize=${data?.size ?: 0}")
            hidDevice?.reportError(device, BluetoothHidDevice.ERROR_RSP_SUCCESS)
        }

        override fun onSetProtocol(device: BluetoothDevice?, protocol: Byte) {
            log("DEBUG", "HID", "onSetProtocol: protocol=$protocol")
            hidDevice?.reportError(device, BluetoothHidDevice.ERROR_RSP_SUCCESS)
        }

        override fun onInterruptData(device: BluetoothDevice?, reportId: Byte, data: ByteArray?) {
            log("DEBUG", "HID", "onInterruptData: reportId=$reportId")
        }
    }

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                    when (state) {
                        BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                            log("WARN", "BT", "Bluetooth adapter turned OFF externally! Cleaning up proxy and state...")
                            connectedHost = null
                            hidDevice = null
                            isAppRegistered = false
                            sendEvent(mapOf("event" to "bt_state", "enabled" to false))
                            sendEvent(mapOf(
                                "event" to "connection_state",
                                "state" to "disconnected",
                                "deviceName" to "",
                                "deviceAddress" to ""
                            ))
                            sendEvent(mapOf(
                                "event" to "app_status",
                                "registered" to false
                            ))
                        }
                        BluetoothAdapter.STATE_ON -> {
                            log("INFO", "BT", "Bluetooth adapter turned ON externally! Re-initializing HID proxy...")
                            sendEvent(mapOf("event" to "bt_state", "enabled" to true))
                            initHidProxy()
                        }
                    }
                }

                BluetoothAdapter.ACTION_DISCOVERY_STARTED -> {
                    log("INFO", "SCAN", "Bluetooth scan discovery started...")
                    sendEvent(mapOf("event" to "discovery_started"))
                }

                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                    log("INFO", "SCAN", "Bluetooth scan discovery finished.")
                    sendEvent(mapOf("event" to "discovery_finished"))
                }

                BluetoothDevice.ACTION_FOUND -> {
                    val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt()
                    val btClass: BluetoothClass? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_CLASS, BluetoothClass::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_CLASS)
                    }

                    if (device != null) {
                        val info = parseDeviceInfo(device, rssi, btClass)
                        log("DEBUG", "SCAN", "Discovered: '${info["name"]}' (${info["address"]}) RSSI: $rssi")
                        sendEvent(mapOf(
                            "event" to "device_found",
                            "device" to info
                        ))
                    }
                }

                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                    val prevBond = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
                    val devName = device?.name ?: "Unknown"
                    val devAddr = device?.address ?: "N/A"

                    val bondStr = bondStateToTag(bondState)
                    val prevBondStr = bondStateToTag(prevBond)
                    log("INFO", "BOND", "[Pairing] '$devName' ($devAddr) transition: $prevBondStr -> $bondStr")

                    if (bondState == BluetoothDevice.BOND_BONDED && device != null) {
                        saveLastDevice(device)
                        log("INFO", "BOND", "Device '$devName' ($devAddr) successfully paired! Initiating HID connection...")
                        connectDevice(device.address)
                    }

                    sendEvent(
                        mapOf(
                            "event" to "bond_state",
                            "bondState" to bondStr,
                            "deviceName" to devName,
                            "deviceAddress" to devAddr
                        )
                    )
                }

                BluetoothDevice.ACTION_ACL_CONNECTED -> {
                    val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    log("INFO", "ACL", "Bluetooth ACL base link connected: '${device?.name ?: "Unknown"}' (${device?.address})")
                }

                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    log("WARN", "ACL", "Bluetooth ACL base link disconnected: '${device?.name ?: "Unknown"}' (${device?.address})")
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)

        val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)

        registerReceivers()
        if (getMissingPermissions().isEmpty()) {
            initHidProxy()
        }
    }

    private fun getMissingPermissions(): List<String> {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.BLUETOOTH_SCAN)
            }
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) {
                missing.add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
        }
        return missing
    }

    private fun isLocationPermissionGranted(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationServicesOn(): Boolean {
        val locManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val isGps = locManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true
        val isNetwork = locManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
        return isGps || isNetwork
    }

    private fun initHidProxy() {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            log("ERROR", "BT", "Bluetooth adapter not found on this device")
            return
        }
        if (adapter.isEnabled) {
            val success = adapter.getProfileProxy(applicationContext, serviceListener, BluetoothProfile.HID_DEVICE)
            log("INFO", "HID", "Requesting HID_DEVICE profile proxy, success=$success")
        } else {
            log("WARN", "BT", "Bluetooth is currently disabled")
        }
    }

    private fun registerReceivers() {
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        registerReceiver(bluetoothReceiver, filter)
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(bluetoothReceiver)
        } catch (_: Exception) {}

        hidDevice?.let { hid ->
            try {
                if (isAppRegistered) {
                    hid.unregisterApp()
                }
                bluetoothAdapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, hid)
            } catch (_: Exception) {}
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermissions" -> {
                val isBtEnabled = bluetoothAdapter?.isEnabled == true
                val isLocOn = isLocationServicesOn()
                val missing = getMissingPermissions()
                val granted = missing.isEmpty()
                log("INFO", "PERM", "checkPermissions: btEnabled=$isBtEnabled, locServicesOn=$isLocOn, missingBt=[${missing.joinToString()}]")
                result.success(
                    mapOf(
                        "bluetoothEnabled" to isBtEnabled,
                        "locationEnabled" to isLocOn,
                        "permissionsGranted" to granted,
                        "missingPermissions" to missing
                    )
                )
            }

            "checkLocationPermission" -> {
                result.success(isLocationPermissionGranted())
            }

            "isLocationServicesEnabled" -> {
                result.success(isLocationServicesOn())
            }

            "requestLocationPermission" -> {
                if (isLocationPermissionGranted()) {
                    result.success(true)
                } else {
                    pendingPermissionResult = result
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                        PERMISSION_REQUEST_CODE
                    )
                }
            }

            "syncConnectionState" -> {
                val adapter = bluetoothAdapter
                val isEnabled = adapter?.isEnabled == true
                val hid = hidDevice
                var connectedName: String? = null
                var connectedAddr: String? = null
                var isConnected = false

                if (hid != null && isEnabled) {
                    val devices = hid.connectedDevices
                    if (devices != null && devices.isNotEmpty()) {
                        val dev = devices.first()
                        connectedHost = dev
                        connectedName = dev.name ?: "Connected Device"
                        connectedAddr = dev.address
                        isConnected = true
                    } else if (connectedHost != null) {
                        val st = hid.getConnectionState(connectedHost)
                        if (st == BluetoothProfile.STATE_CONNECTED) {
                            connectedName = connectedHost?.name ?: "Connected Device"
                            connectedAddr = connectedHost?.address
                            isConnected = true
                        } else {
                            connectedHost = null
                        }
                    }
                } else {
                    connectedHost = null
                }

                result.success(
                    mapOf(
                        "isBluetoothEnabled" to isEnabled,
                        "isHidRegistered" to isAppRegistered,
                        "isConnected" to isConnected,
                        "deviceName" to (connectedName ?: ""),
                        "deviceAddress" to (connectedAddr ?: "")
                    )
                )
            }

            "openLocationSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    log("ERROR", "SETTINGS", "Failed to open location settings: ${e.message}")
                    result.error("ERROR", e.message, null)
                }
            }

            "requestPermissions" -> {
                val missing = getMissingPermissions()
                if (missing.isEmpty()) {
                    initHidProxy()
                    result.success(true)
                } else {
                    pendingPermissionResult = result
                    ActivityCompat.requestPermissions(this, missing.toTypedArray(), PERMISSION_REQUEST_CODE)
                }
            }

            "enableBluetooth" -> {
                val adapter = bluetoothAdapter
                if (adapter == null) {
                    result.error("NO_ADAPTER", "Bluetooth adapter not found", null)
                    return
                }
                if (adapter.isEnabled) {
                    sendEvent(mapOf("event" to "bt_state", "enabled" to true))
                    result.success(true)
                    return
                }
                try {
                    @Suppress("DEPRECATION")
                    val ok = adapter.enable()
                    if (ok) {
                        log("INFO", "BT", "Bluetooth enabled programmatically.")
                        sendEvent(mapOf("event" to "bt_state", "enabled" to true))
                        result.success(true)
                    } else {
                        // Launch system dialog overlay (stays on same screen)
                        val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(enableBtIntent)
                        result.success(true)
                    }
                } catch (e: Exception) {
                    log("WARN", "BT", "Exception enabling Bluetooth: ${e.message}")
                    try {
                        val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(enableBtIntent)
                        result.success(true)
                    } catch (e2: Exception) {
                        log("ERROR", "BT", "Failed to request Bluetooth enable: ${e2.message}")
                        result.error("ERROR", e2.message, null)
                    }
                }
            }

            "disableBluetooth" -> {
                val adapter = bluetoothAdapter
                if (adapter == null) {
                    result.error("NO_ADAPTER", "Bluetooth adapter not found", null)
                    return
                }
                if (!adapter.isEnabled) {
                    sendEvent(mapOf("event" to "bt_state", "enabled" to false))
                    result.success(true)
                    return
                }
                try {
                    @Suppress("DEPRECATION")
                    val ok = adapter.disable()
                    if (ok) {
                        log("INFO", "BT", "Bluetooth disabled programmatically in same screen.")
                        sendEvent(mapOf("event" to "bt_state", "enabled" to false))
                        result.success(true)
                    } else {
                        // OS blocked programmatic disable (e.g. Android 13/14).
                        // Do NOT auto-redirect! Return false so Flutter can handle in same screen.
                        log("WARN", "BT", "adapter.disable() returned false (Android security restriction). Not redirecting automatically.")
                        result.success(false)
                    }
                } catch (e: Exception) {
                    log("WARN", "BT", "Exception disabling Bluetooth: ${e.message}")
                    result.success(false)
                }
            }

            "openBluetoothSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    log("ERROR", "BT", "Failed to open Bluetooth settings: ${e.message}")
                    result.error("ERROR", e.message, null)
                }
            }

            "openAppSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.fromParts("package", packageName, null)
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    log("ERROR", "SETTINGS", "Failed to open app settings: ${e.message}")
                    result.error("ERROR", e.message, null)
                }
            }

            "makeDiscoverable" -> {
                try {
                    val duration = call.argument<Int>("duration") ?: 300
                    log("INFO", "BT", "Requesting device discoverable for ${duration}s...")
                    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                        putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, duration)
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    log("ERROR", "BT", "Failed to request discoverable: ${e.message}")
                    result.error("ERROR", e.message, null)
                }
            }

            "startDiscovery" -> {
                val adapter = bluetoothAdapter
                if (adapter == null || !adapter.isEnabled) {
                    log("ERROR", "SCAN", "Cannot scan: Bluetooth adapter is null or disabled")
                    result.error("BT_OFF", "Bluetooth is disabled", null)
                    return
                }
                try {
                    val locManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                    val isGps = locManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true
                    val isNetwork = locManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
                    val isLocOn = isGps || isNetwork
                    if (!isLocOn) {
                        log("WARN", "SCAN", "Location (GPS) is OFF in phone settings. Turn ON Location if devices are not detected.")
                    }

                    if (adapter.isDiscovering) {
                        adapter.cancelDiscovery()
                        Thread.sleep(150)
                    }
                    val ok = adapter.startDiscovery()
                    log("INFO", "SCAN", "adapter.startDiscovery() returned: $ok (Location services: ${if (isLocOn) "ON" else "OFF"})")
                    result.success(ok)
                } catch (e: SecurityException) {
                    log("ERROR", "SCAN", "SecurityException during startDiscovery: ${e.message}")
                    result.error("SECURITY_ERR", e.message, null)
                } catch (e: Exception) {
                    log("ERROR", "SCAN", "Exception during startDiscovery: ${e.message}")
                    result.error("SCAN_ERR", e.message, null)
                }
            }

            "stopDiscovery" -> {
                val ok = bluetoothAdapter?.cancelDiscovery() == true
                log("INFO", "SCAN", "cancelDiscovery invoked, success=$ok")
                result.success(ok)
            }

            "isDiscovering" -> {
                result.success(bluetoothAdapter?.isDiscovering == true)
            }

            "pairDevice" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("INVALID_ARGS", "Address required", null)
                    return
                }
                val success = pairDevice(address)
                result.success(success)
            }

            "unpairDevice" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("INVALID_ARGS", "Address required", null)
                    return
                }
                val success = unpairDevice(address)
                result.success(success)
            }

            "isBluetoothEnabled" -> {
                result.success(bluetoothAdapter?.isEnabled == true)
            }

            "isHidRegistered" -> {
                result.success(isAppRegistered)
            }

            "getAdapterInfo" -> {
                val adapter = bluetoothAdapter
                if (adapter == null) {
                    result.success(null)
                    return
                }
                result.success(
                    mapOf(
                        "name" to (adapter.name ?: "Android Device"),
                        "address" to (adapter.address ?: ""),
                        "isEnabled" to adapter.isEnabled,
                        "isDiscovering" to adapter.isDiscovering,
                        "isHidRegistered" to isAppRegistered,
                        "connectedHost" to (connectedHost?.name ?: connectedHost?.address ?: "")
                    )
                )
            }

            "getBondedDevices" -> {
                val list = mutableListOf<Map<String, Any?>>()
                bluetoothAdapter?.bondedDevices?.forEach { device ->
                    list.add(parseDeviceInfo(device, 0, device.bluetoothClass))
                }
                log("INFO", "CONN", "Retrieved ${list.size} bonded devices")
                result.success(list)
            }

            "registerHidDevice" -> {
                val descriptorList = call.argument<List<Int>>("descriptor")
                val deviceName = call.argument<String>("name") ?: "NES Gamepad"
                if (descriptorList == null) {
                    result.error("INVALID_ARGS", "Missing HID descriptor", null)
                    return
                }
                val descriptorBytes = ByteArray(descriptorList.size) { descriptorList[it].toByte() }
                cachedDescriptor = descriptorBytes
                cachedAppName = deviceName

                val registered = registerHidApp(deviceName, descriptorBytes)
                result.success(registered)
            }

            "unregisterHidDevice" -> {
                val hid = hidDevice
                if (hid != null && isAppRegistered) {
                    hid.unregisterApp()
                    isAppRegistered = false
                    log("INFO", "HID", "Unregistered HID App")
                    result.success(true)
                } else {
                    result.success(false)
                }
            }

            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("INVALID_ARGS", "Device address required", null)
                    return
                }
                val success = connectDevice(address)
                result.success(success)
            }

            "disconnect" -> {
                val success = disconnectDevice()
                result.success(success)
            }

            "reconnect" -> {
                val success = reconnectLastDevice()
                result.success(success)
            }

            "sendReport" -> {
                val reportId = call.argument<Int>("reportId") ?: 1
                val dataList = call.argument<List<Int>>("data")
                if (dataList == null) {
                    result.error("INVALID_ARGS", "Data required", null)
                    return
                }
                val reportData = ByteArray(dataList.size) { dataList[it].toByte() }
                val success = sendHidReport(reportId.toByte(), reportData)
                result.success(success)
            }

            "getLastConnectedDevice" -> {
                val addr = prefs.getString(KEY_LAST_DEVICE_ADDR, null)
                val name = prefs.getString(KEY_LAST_DEVICE_NAME, null)
                if (addr != null) {
                    result.success(mapOf("name" to (name ?: "Unknown"), "address" to addr))
                } else {
                    result.success(null)
                }
            }

            "savePreference" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key != null && value != null) {
                    prefs.edit().putString(key, value).apply()
                    result.success(true)
                } else {
                    result.success(false)
                }
            }

            "getPreference" -> {
                val key = call.argument<String>("key")
                if (key != null) {
                    val value = prefs.getString(key, null)
                    result.success(value)
                } else {
                    result.success(null)
                }
            }

            "getRomsDirectory" -> {
                val dir = File(context.getExternalFilesDir(null) ?: context.filesDir, "roms")
                if (!dir.exists()) {
                    dir.mkdirs()
                }
                result.success(dir.absolutePath)
            }

            "pickRomFile" -> {
                if (pendingPickRomResult != null) {
                    result.error("ALREADY_PICKING", "File picker is already active", null)
                } else {
                    pendingPickRomResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                                "application/octet-stream",
                                "application/x-nes-rom",
                                "application/zip",
                                "application/x-zip-compressed",
                                "*/*"
                            ))
                        }
                        startActivityForResult(intent, REQUEST_CODE_PICK_ROM)
                    } catch (e: Exception) {
                        pendingPickRomResult = null
                        result.error("PICK_FAILED", "Failed to launch file picker: ${e.message}", null)
                    }
                }
            }

            "pushRomToDevice" -> {
                val filePath = call.argument<String>("filePath")
                val deviceAddress = call.argument<String>("deviceAddress")
                val deviceName = call.argument<String>("deviceName") ?: "Android TV"

                if (filePath == null) {
                    result.error("INVALID_ARGS", "filePath must not be null", null)
                } else {
                    val file = File(filePath)
                    if (!file.exists()) {
                        result.error("NOT_FOUND", "File not found at $filePath", null)
                    } else {
                        try {
                            val contentUri: Uri = FileProvider.getUriForFile(
                                this,
                                "${applicationContext.packageName}.fileprovider",
                                file
                            )

                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "*/*"
                                putExtra(Intent.EXTRA_STREAM, contentUri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                setPackage("com.android.bluetooth")

                                if (!deviceAddress.isNullOrEmpty() && bluetoothAdapter != null) {
                                    try {
                                        val targetDevice = bluetoothAdapter?.getRemoteDevice(deviceAddress)
                                        putExtra("android.bluetooth.device.extra.DEVICE", targetDevice)
                                    } catch (e: Exception) {
                                        log("WARN", "BT_PUSH", "Could not attach extra device: ${e.message}")
                                    }
                                }
                            }

                            if (intent.resolveActivity(packageManager) != null) {
                                startActivity(intent)
                            } else {
                                val chooser = Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                                    type = "*/*"
                                    putExtra(Intent.EXTRA_STREAM, contentUri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }, "Send ROM to $deviceName")
                                chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(chooser)
                            }

                            log("INFO", "ROM_PUSH", "Initiated Bluetooth ROM push of ${file.name} to $deviceName ($deviceAddress)")
                            result.success(mapOf(
                                "success" to true,
                                "fileName" to file.name,
                                "fileSize" to file.length(),
                                "targetDevice" to deviceName
                            ))
                        } catch (e: Exception) {
                            log("ERROR", "ROM_PUSH", "Failed to push ROM: ${e.message}")
                            result.error("PUSH_ERROR", "Failed to initiate push: ${e.message}", null)
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PICK_ROM) {
            val pending = pendingPickRomResult
            pendingPickRomResult = null
            if (pending == null) return

            if (resultCode == Activity.RESULT_OK && data != null && data.data != null) {
                val uri = data.data!!
                try {
                    var displayName = "rom_${System.currentTimeMillis()}"
                    var size: Long = 0
                    contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (cursor.moveToFirst()) {
                            if (nameIndex != -1) {
                                displayName = cursor.getString(nameIndex) ?: displayName
                            }
                            if (sizeIndex != -1) {
                                size = cursor.getLong(sizeIndex)
                            }
                        }
                    }

                    val romsDir = File(context.getExternalFilesDir(null) ?: context.filesDir, "roms")
                    if (!romsDir.exists()) {
                        romsDir.mkdirs()
                    }

                    val sanitizedName = displayName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
                    val targetFile = File(romsDir, sanitizedName)

                    contentResolver.openInputStream(uri)?.use { inputStream ->
                        targetFile.outputStream().use { outputStream ->
                            inputStream.copyTo(outputStream)
                        }
                    }

                    val actualSize = targetFile.length()
                    log("INFO", "ROM_PICK", "Picked and imported ROM: $sanitizedName ($actualSize bytes)")

                    pending.success(mapOf(
                        "path" to targetFile.absolutePath,
                        "name" to sanitizedName,
                        "size" to actualSize
                    ))
                } catch (e: Exception) {
                    log("ERROR", "ROM_PICK", "Failed to copy picked ROM: ${e.message}")
                    pending.error("COPY_FAILED", "Failed to copy picked file: ${e.message}", null)
                }
            } else {
                pending.success(null) // User cancelled
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val allGranted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            log("INFO", "PERM", "Permissions result: allGranted=$allGranted")
            pendingPermissionResult?.success(allGranted)
            pendingPermissionResult = null
            if (allGranted) {
                initHidProxy()
            }
        }
    }

    private fun registerHidApp(name: String, descriptor: ByteArray): Boolean {
        val hid = hidDevice
        if (hid == null) {
            log("WARN", "HID", "HID profile proxy not connected yet. Will auto-register upon proxy connection.")
            initHidProxy()
            return false
        }
        if (isAppRegistered) {
            log("INFO", "HID", "HID App is already registered.")
            return true
        }

        try {
            log("INFO", "HID", "Registering SDP (subclass=GAMEPAD, descSize=${descriptor.size}B)...")
            val sdp = BluetoothHidDeviceAppSdpSettings(
                name,
                "Bluetooth Gamepad",
                "Android",
                BluetoothHidDevice.SUBCLASS2_GAMEPAD,
                descriptor
            )

            val executor = Executors.newSingleThreadExecutor()
            // Pass null for inQos and outQos for maximum hardware & OEM compatibility (OnePlus/Oppo/Samsung/Pixel)
            val syncResult = hid.registerApp(sdp, null, null, executor, hidCallback)
            log("INFO", "HID", "registerApp returned: $syncResult")
            return syncResult
        } catch (e: Exception) {
            log("ERROR", "HID", "Exception during registerApp: ${e.message}")
            return false
        }
    }

    private fun connectDevice(address: String): Boolean {
        log("INFO", "CONN", "==================================================")
        log("INFO", "CONN", "[CONNECT] Step 1/6: Validating Bluetooth and HID state for $address...")

        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            log("ERROR", "CONN", "[CONNECT FAIL] Bluetooth adapter is null or disabled!")
            return false
        }

        val hid = hidDevice
        if (hid == null) {
            log("ERROR", "CONN", "[CONNECT FAIL] BluetoothHidDevice proxy is null! Requesting proxy...")
            initHidProxy()
            return false
        }

        // Check if HID profile is registered
        if (!isAppRegistered) {
            log("WARN", "CONN", "[CONNECT FAIL] HID App is not registered yet! Please tap 'Register Gamepad' first.")
            return false
        }

        log("INFO", "CONN", "[CONNECT] Step 2/6: Resolving remote device object...")
        val device: BluetoothDevice
        try {
            device = adapter.getRemoteDevice(address)
        } catch (e: Exception) {
            log("ERROR", "CONN", "[CONNECT FAIL] Invalid Bluetooth address '$address': ${e.message}")
            return false
        }

        val devName = device.name ?: "Unknown Device"
        log("INFO", "CONN", "[CONNECT] Step 3/6: Target device: '$devName' ($address), Type=${deviceTypeToString(device.type)}")

        log("INFO", "CONN", "[CONNECT] Step 4/6: Checking pairing bond state: ${bondStateToTag(device.bondState)}")
        if (device.bondState == BluetoothDevice.BOND_NONE) {
            log("WARN", "CONN", "[CONNECT] Device '$devName' is NOT paired! Initiating bond request (createBond)...")
            val bondTriggered = device.createBond()
            log("INFO", "CONN", "[CONNECT] createBond() returned: $bondTriggered. Please confirm pairing dialog on your TV.")
            return false
        } else if (device.bondState == BluetoothDevice.BOND_BONDING) {
            log("INFO", "CONN", "[CONNECT] Device '$devName' is currently pairing. Please wait for pairing to complete.")
            return false
        }

        val currentHidState = hid.getConnectionState(device)
        log("INFO", "CONN", "[CONNECT] Step 5/6: Current HID connection state with target: ${connectionStateToString(currentHidState)}")
        if (currentHidState == BluetoothProfile.STATE_CONNECTED) {
            log("INFO", "CONN", "[CONNECT] Already connected to '$devName'!")
            connectedHost = device
            saveLastDevice(device)
            return true
        }

        log("INFO", "CONN", "[CONNECT] Step 6/6: Invoking hidDevice.connect('$devName')...")
        return try {
            val success = hid.connect(device)
            log("INFO", "CONN", "[CONNECT RESULT] hidDevice.connect() returned: $success")
            if (!success) {
                log("WARN", "CONN", "==================================================")
                log("WARN", "CONN", "Connection request was rejected by Android Bluetooth stack.")
                log("WARN", "CONN", "DIAGNOSTICS:")
                log("WARN", "CONN", "1. Android TV often connects as Host to the Gamepad.")
                log("WARN", "CONN", "2. Tap 'Make Discoverable' in the app and select 'NES Gamepad' on your Android TV.")
                log("WARN", "CONN", "3. If stale bond persists, tap 'Unpair' here and forget device on TV.")
                log("WARN", "CONN", "==================================================")
            }
            success
        } catch (e: Exception) {
            log("ERROR", "CONN", "[CONNECT EXCEPTION] Failed calling connect: ${e.message}")
            false
        }
    }

    private fun pairDevice(address: String): Boolean {
        log("INFO", "BOND", "Initiating pairing with $address...")
        val adapter = bluetoothAdapter ?: return false
        return try {
            val device = adapter.getRemoteDevice(address)
            val ok = device.createBond()
            log("INFO", "BOND", "createBond() for '${device.name ?: "Device"}' ($address) returned: $ok")
            ok
        } catch (e: Exception) {
            log("ERROR", "BOND", "Failed to pair $address: ${e.message}")
            false
        }
    }

    private fun unpairDevice(address: String): Boolean {
        log("INFO", "BOND", "Unpairing device: $address...")
        val adapter = bluetoothAdapter ?: return false
        return try {
            val device = adapter.getRemoteDevice(address)
            val devName = device.name ?: "Device"
            val method = device.javaClass.getMethod("removeBond")
            val result = method.invoke(device) as Boolean
            log("INFO", "BOND", "removeBond() for '$devName' ($address) returned: $result")
            result
        } catch (e: Exception) {
            log("ERROR", "BOND", "Failed to unpair $address: ${e.message}")
            false
        }
    }

    private fun disconnectDevice(): Boolean {
        val hid = hidDevice
        val host = connectedHost
        if (hid == null || host == null) {
            log("WARN", "CONN", "No device connected to disconnect")
            return false
        }
        log("INFO", "CONN", "Disconnecting from '${host.name ?: "Unknown"}' (${host.address})")
        return hid.disconnect(host)
    }

    private fun reconnectLastDevice(): Boolean {
        val addr = prefs.getString(KEY_LAST_DEVICE_ADDR, null)
        val name = prefs.getString(KEY_LAST_DEVICE_NAME, "Device")
        if (addr == null) {
            log("WARN", "CONN", "[RECONNECT] No previous device stored in cache to reconnect")
            return false
        }
        log("INFO", "CONN", "[RECONNECT] Reconnecting to last device: '$name' ($addr)")
        return connectDevice(addr)
    }

    private fun sendHidReport(reportId: Byte, data: ByteArray): Boolean {
        val hid = hidDevice
        if (hid == null) {
            log("WARN", "HID", "sendReport: BluetoothHidDevice proxy is null")
            return false
        }
        var host = connectedHost
        if (host == null) {
            val devices = hid.connectedDevices
            if (devices != null && devices.isNotEmpty()) {
                host = devices.first()
                connectedHost = host
            }
        }

        if (host == null) {
            log("WARN", "HID", "sendReport: No connected host")
            return false
        }
        val sent = hid.sendReport(host, reportId.toInt(), data)
        if (!sent) {
            log("WARN", "HID", "sendReport: hid.sendReport returned FALSE (buffer full or dropped)")
        }
        return sent
    }

    private fun saveLastDevice(device: BluetoothDevice) {
        prefs.edit()
            .putString(KEY_LAST_DEVICE_ADDR, device.address)
            .putString(KEY_LAST_DEVICE_NAME, device.name ?: "Unknown Device")
            .apply()
        log("DEBUG", "CACHE", "Saved last device: '${device.name}' (${device.address})")
    }

    private fun parseDeviceInfo(device: BluetoothDevice, rssi: Int, btClass: BluetoothClass?): Map<String, Any?> {
        val devClass = btClass ?: device.bluetoothClass
        val majorClass = devClass?.majorDeviceClass ?: 0
        val specificClass = devClass?.deviceClass ?: 0

        val capabilities = mutableListOf<String>()
        var isPeripheral = false
        var isTv = false
        var isAudio = false
        var hasNetworking = false
        var hasPhoneCalls = false
        var hasContactSharing = false

        // Fetch ParcelUuids if available
        val uuidStrings = try {
            device.uuids?.map { it.uuid.toString().lowercase() } ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        }

        // Check Media Audio (A2DP, AVRCP)
        val hasA2dpUuid = uuidStrings.any { it.contains("110a") || it.contains("110b") || it.contains("110d") || it.contains("110e") }
        if (hasA2dpUuid || devClass?.hasService(BluetoothClass.Service.AUDIO) == true || majorClass == BluetoothClass.Device.Major.AUDIO_VIDEO) {
            isAudio = true
            capabilities.add("Media Audio")
        }

        // Check Phone calls (HFP, HSP, Telephony)
        val hasHfpUuid = uuidStrings.any { it.contains("111e") || it.contains("1108") || it.contains("111f") }
        if (hasHfpUuid || devClass?.hasService(BluetoothClass.Service.TELEPHONY) == true || majorClass == BluetoothClass.Device.Major.PHONE) {
            hasPhoneCalls = true
            capabilities.add("Phone calls")
        }

        // Check Contact sharing (PBAP)
        val hasPbapUuid = uuidStrings.any { it.contains("112f") || it.contains("1130") }
        if (hasPbapUuid || majorClass == BluetoothClass.Device.Major.PHONE) {
            hasContactSharing = true
            capabilities.add("Contact sharing")
        }

        // Check Internet access (PAN, NAP, GN)
        val hasPanUuid = uuidStrings.any { it.contains("1115") || it.contains("1116") || it.contains("1117") }
        if (hasPanUuid || devClass?.hasService(BluetoothClass.Service.NETWORKING) == true || majorClass == BluetoothClass.Device.Major.NETWORKING) {
            hasNetworking = true
            capabilities.add("Internet access")
        }

        // Check Major & Device Class
        val majorStr: String
        when (majorClass) {
            BluetoothClass.Device.Major.PERIPHERAL -> {
                isPeripheral = true
                majorStr = "Input Device / Peripheral"
                when (specificClass) {
                    BluetoothClass.Device.PERIPHERAL_KEYBOARD -> capabilities.add("Keyboard")
                    BluetoothClass.Device.PERIPHERAL_POINTING -> capabilities.add("Mouse")
                    BluetoothClass.Device.PERIPHERAL_KEYBOARD_POINTING -> capabilities.add("Combo (Keyboard+Mouse)")
                    else -> capabilities.add("Input device (Gamepad)")
                }
            }
            BluetoothClass.Device.Major.AUDIO_VIDEO -> {
                majorStr = "Audio / Video"
                when (specificClass) {
                    BluetoothClass.Device.AUDIO_VIDEO_WEARABLE_HEADSET,
                    BluetoothClass.Device.AUDIO_VIDEO_HEADPHONES -> capabilities.add("Headphones")
                    BluetoothClass.Device.AUDIO_VIDEO_LOUDSPEAKER -> capabilities.add("Speaker")
                    BluetoothClass.Device.AUDIO_VIDEO_SET_TOP_BOX,
                    BluetoothClass.Device.AUDIO_VIDEO_VIDEO_DISPLAY_AND_LOUDSPEAKER,
                    1056 -> { // 1056 = TV / Set Top Box
                        isTv = true
                        capabilities.add("TV / Display")
                    }
                    else -> {}
                }
            }
            BluetoothClass.Device.Major.PHONE -> {
                majorStr = "Phone"
            }
            BluetoothClass.Device.Major.COMPUTER -> {
                majorStr = "Computer"
            }
            BluetoothClass.Device.Major.NETWORKING -> {
                majorStr = "Networking"
            }
            else -> {
                majorStr = "Uncategorized"
            }
        }

        // Check HID UUIDs
        val hasHidUuid = uuidStrings.any { it.contains("1124") || it.contains("1812") }
        if (hasHidUuid && !isPeripheral) {
            isPeripheral = true
            if (!capabilities.any { it.contains("Input device") }) {
                capabilities.add("Input device (Gamepad)")
            }
        }

        val name = device.name ?: ""
        // Extra heuristic for TVs (e.g. MiTV, Sony TV, Fire TV, etc.)
        val lowerName = name.lowercase()
        if (lowerName.contains("tv") || lowerName.contains("box") || lowerName.contains("fire") || lowerName.contains("shield")) {
            isTv = true
            if (!capabilities.contains("TV / Display")) {
                capabilities.add("TV / Display")
            }
        }

        val isCurrentConnected = connectedHost?.address == device.address
        val uniqueCaps = capabilities.distinct()

        return mapOf(
            "name" to (if (name.isNotEmpty()) name else "Unknown Device"),
            "address" to device.address,
            "bondState" to bondStateToTag(device.bondState),
            "type" to deviceTypeToString(device.type),
            "rssi" to rssi,
            "majorClass" to majorStr,
            "isPeripheral" to isPeripheral,
            "isTv" to isTv,
            "isAudio" to isAudio,
            "hasNetworking" to hasNetworking,
            "mediaAudio" to isAudio,
            "phoneCalls" to hasPhoneCalls,
            "contactSharing" to hasContactSharing,
            "internetAccess" to hasNetworking,
            "inputDevice" to isPeripheral,
            "capabilities" to uniqueCaps,
            "isConnected" to isCurrentConnected
        )
    }

    private fun deviceTypeToString(type: Int): String {
        return when (type) {
            BluetoothDevice.DEVICE_TYPE_CLASSIC -> "CLASSIC"
            BluetoothDevice.DEVICE_TYPE_LE -> "LE"
            BluetoothDevice.DEVICE_TYPE_DUAL -> "DUAL"
            else -> "UNKNOWN"
        }
    }

    private fun bondStateToTag(bondState: Int): String {
        return when (bondState) {
            BluetoothDevice.BOND_BONDED -> "bonded"
            BluetoothDevice.BOND_BONDING -> "bonding"
            BluetoothDevice.BOND_NONE -> "none"
            else -> "unknown"
        }
    }

    private fun connectionStateToString(state: Int): String {
        return when (state) {
            BluetoothProfile.STATE_CONNECTED -> "CONNECTED"
            BluetoothProfile.STATE_CONNECTING -> "CONNECTING"
            BluetoothProfile.STATE_DISCONNECTING -> "DISCONNECTING"
            BluetoothProfile.STATE_DISCONNECTED -> "DISCONNECTED"
            else -> "UNKNOWN ($state)"
        }
    }

    private fun log(level: String, tag: String, message: String) {
        val priority = when (level) {
            "ERROR" -> android.util.Log.ERROR
            "WARN" -> android.util.Log.WARN
            "DEBUG" -> android.util.Log.DEBUG
            else -> android.util.Log.INFO
        }
        android.util.Log.println(priority, "BLE_$tag", message)

        val timeStr = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US).format(java.util.Date())
        val entry = mapOf(
            "event" to "log",
            "level" to level,
            "tag" to tag,
            "message" to message,
            "timestamp" to System.currentTimeMillis(),
            "formattedTime" to timeStr
        )
        sendEvent(entry)
    }

    private fun sendEvent(data: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(data)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.eventSink = events
        log("INFO", "BRIDGE", "Flutter event channel listener connected")
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
    }
}
