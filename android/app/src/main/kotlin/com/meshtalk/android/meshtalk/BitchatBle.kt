package com.meshtalk.android.meshtalk

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.ArrayDeque
import java.util.UUID

/**
 * Bluetooth LE links in bitchat's format (service + characteristic UUIDs
 * from bitchat's public-domain sources). Like bitchat, every phone is both:
 *
 *  - a GATT server: advertises the service; bitchat phones connect, write
 *    packets to the characteristic and receive packets as notifications;
 *  - a GATT client: scans for the service, connects, subscribes to
 *    notifications and writes packets.
 *
 * One write / notification = one bitchat packet (Dart fragments anything
 * that doesn't fit the link). All callbacks are moved to the main thread.
 *
 * Link ids: "c:<address>" (we are client), "s:<address>" (we are server).
 */
@SuppressLint("MissingPermission") // permissions are requested in Dart first
class BitchatBle(
    private val ctx: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "MeshTalkBle"
        val SERVICE_UUID: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
        val CHAR_UUID: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val MAX_CLIENT_LINKS = 6
        const val MAX_QUEUE = 300
        const val TARGET_MTU = 517
        const val CONNECT_TIMEOUT_MS = 15_000L
        const val RETRY_AFTER_MS = 20_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?

    private var running = false
    private var server: BluetoothGattServer? = null
    private var serverChar: BluetoothGattCharacteristic? = null
    private var advertising = false
    private var scanning = false

    private class ClientLink(val gatt: BluetoothGatt) {
        var ch: BluetoothGattCharacteristic? = null
        var mtu = 23
        var ready = false
        val queue = ArrayDeque<ByteArray>()
        var writing = false
        var writeStartedAt = 0L
    }

    private class ServerLink(val device: BluetoothDevice) {
        var mtu = 23
        var subscribed = false
        val queue = ArrayDeque<ByteArray>()
        var sending = false
        var sendStartedAt = 0L
        val prepared = ByteArrayOutputStream()
    }

    private val clients = HashMap<String, ClientLink>()
    private val connecting = HashMap<String, Long>()
    private val retryAt = HashMap<String, Long>()
    private val servers = HashMap<String, ServerLink>()

    // ── lifecycle ───────────────────────────────────────────────────────

    fun start() {
        val adapter = manager?.adapter
        if (adapter == null) {
            emit(mapOf("e" to "state", "on" to false, "error" to "Bluetooth not supported"))
            return
        }
        if (!adapter.isEnabled) {
            // Bluetooth was switched off: drop stale state so a later start
            // (Dart retries every 20 s) rebuilds everything.
            if (running || server != null) stop()
            emit(mapOf("e" to "state", "on" to false, "error" to "Bluetooth is off"))
            return
        }
        try {
            if (server == null) openServer()
            if (!advertising) startAdvertising()
            if (!scanning) startScanning()
            if (!running) {
                running = true
                main.postDelayed(watchdog, 2_000)
            }
            emit(mapOf("e" to "state", "on" to true))
        } catch (e: SecurityException) {
            emit(mapOf("e" to "state", "on" to false, "error" to "Bluetooth permission missing"))
        } catch (e: Exception) {
            Log.w(TAG, "start failed", e)
        }
    }

    fun stop() {
        running = false
        main.removeCallbacks(watchdog)
        val adapter = manager?.adapter
        try {
            if (scanning) adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (e: Exception) {}
        scanning = false
        try {
            if (advertising) adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        } catch (e: Exception) {}
        advertising = false
        for ((addr, link) in clients) {
            try { link.gatt.disconnect(); link.gatt.close() } catch (e: Exception) {}
            if (link.ready) emit(mapOf("e" to "down", "link" to "c:$addr"))
        }
        clients.clear()
        connecting.clear()
        for (addr in servers.keys) emit(mapOf("e" to "down", "link" to "s:$addr"))
        servers.clear()
        try { server?.close() } catch (e: Exception) {}
        server = null
        serverChar = null
    }

    /** Queues [data] for [link]. Returns false if the link is unknown. */
    fun send(link: String, data: ByteArray): Boolean {
        val addr = link.substring(2)
        return when {
            link.startsWith("c:") -> {
                val l = clients[addr] ?: return false
                if (!l.ready || data.size > l.mtu - 3) return false
                if (l.queue.size >= MAX_QUEUE) l.queue.pollFirst()
                l.queue.addLast(data)
                pumpClient(addr)
                true
            }
            link.startsWith("s:") -> {
                val l = servers[addr] ?: return false
                if (data.size > l.mtu - 3) return false
                if (l.queue.size >= MAX_QUEUE) l.queue.pollFirst()
                l.queue.addLast(data)
                pumpServer(addr)
                true
            }
            else -> false
        }
    }

    /** Unsticks queues whose write/notify callback never came; restarts scanning. */
    private val watchdog = object : Runnable {
        override fun run() {
            if (!running) return
            val now = SystemClock.elapsedRealtime()
            for ((addr, l) in clients) {
                if (l.writing && now - l.writeStartedAt > 1_000) {
                    l.writing = false
                    pumpClient(addr)
                }
            }
            for ((addr, l) in servers) {
                if (l.sending && now - l.sendStartedAt > 1_000) {
                    l.sending = false
                    pumpServer(addr)
                }
            }
            for ((addr, startedAt) in connecting.entries.toList()) {
                if (now - startedAt > CONNECT_TIMEOUT_MS) {
                    connecting.remove(addr)
                    clients.remove(addr)?.let {
                        try { it.gatt.disconnect(); it.gatt.close() } catch (e: Exception) {}
                    }
                    retryAt[addr] = now + RETRY_AFTER_MS
                }
            }
            if (!scanning) try { startScanning() } catch (e: Exception) {}
            main.postDelayed(this, 2_000)
        }
    }

    // ── GATT server (peripheral role) ───────────────────────────────────

    private fun openServer() {
        val s = manager?.openGattServer(ctx, serverCallback) ?: return
        val ch = BluetoothGattCharacteristic(
            CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        ch.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            )
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(ch)
        s.addService(service)
        server = s
        serverChar = ch
    }

    private fun startAdvertising() {
        val adv = manager?.adapter?.bluetoothLeAdvertiser ?: return // phone can't advertise
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()
        // Service UUID only, no device name (same as bitchat, for privacy).
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        adv.startAdvertising(settings, data, advertiseCallback)
        advertising = true
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            main.post {
                advertising = false
                Log.w(TAG, "advertising failed: $errorCode")
            }
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                val addr = device.address
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!servers.containsKey(addr)) {
                        servers[addr] = ServerLink(device)
                        emit(mapOf("e" to "up", "link" to "s:$addr", "mtu" to 23))
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (servers.remove(addr) != null) {
                        emit(mapOf("e" to "down", "link" to "s:$addr"))
                    }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            main.post {
                val l = servers[device.address] ?: return@post
                l.mtu = mtu
                emit(mapOf("e" to "mtu", "link" to "s:${device.address}", "mtu" to mtu))
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            // Respond right away: centrals time out quickly.
            if (responseNeeded) {
                try {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                } catch (e: Exception) {}
            }
            val data = value ?: return
            main.post {
                val addr = device.address
                val l = servers.getOrPut(addr) {
                    emit(mapOf("e" to "up", "link" to "s:$addr", "mtu" to 23))
                    ServerLink(device)
                }
                if (preparedWrite) {
                    l.prepared.write(data)
                } else {
                    emit(mapOf("e" to "data", "link" to "s:$addr", "data" to data))
                }
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            try {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            } catch (e: Exception) {}
            main.post {
                val l = servers[device.address] ?: return@post
                if (execute && l.prepared.size() > 0) {
                    emit(mapOf("e" to "data", "link" to "s:${device.address}", "data" to l.prepared.toByteArray()))
                }
                l.prepared.reset()
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            if (responseNeeded) {
                try {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                } catch (e: Exception) {}
            }
            if (descriptor.uuid != CCCD_UUID) return
            val on = value != null && value.isNotEmpty() && (value[0].toInt() and 0x03) != 0
            main.post {
                val l = servers[device.address] ?: return@post
                l.subscribed = on
                if (on) pumpServer(device.address)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic,
        ) {
            try {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, ByteArray(0))
            } catch (e: Exception) {}
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor,
        ) {
            try {
                server?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0,
                    BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE,
                )
            } catch (e: Exception) {}
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                val l = servers[device.address] ?: return@post
                l.sending = false
                pumpServer(device.address)
            }
        }
    }

    private fun pumpServer(addr: String) {
        val l = servers[addr] ?: return
        val s = server ?: return
        val ch = serverChar ?: return
        if (l.sending || !l.subscribed) return
        val data = l.queue.pollFirst() ?: return
        val ok = try {
            if (Build.VERSION.SDK_INT >= 33) {
                s.notifyCharacteristicChanged(l.device, ch, false, data) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                ch.value = data
                @Suppress("DEPRECATION")
                s.notifyCharacteristicChanged(l.device, ch, false)
            }
        } catch (e: Exception) {
            false
        }
        if (ok) {
            l.sending = true
            l.sendStartedAt = SystemClock.elapsedRealtime()
        } else {
            // Stack busy: put it back and retry shortly.
            l.queue.addFirst(data)
            main.postDelayed({ pumpServer(addr) }, 30)
        }
    }

    // ── GATT client (central role) ──────────────────────────────────────

    private fun startScanning() {
        val scanner = manager?.adapter?.bluetoothLeScanner ?: return
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .build()
        scanner.startScan(filters, settings, scanCallback)
        scanning = true
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { onFound(result.device) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            main.post { results.forEach { onFound(it.device) } }
        }

        override fun onScanFailed(errorCode: Int) {
            main.post {
                scanning = false
                Log.w(TAG, "scan failed: $errorCode")
            }
        }
    }

    private fun onFound(device: BluetoothDevice) {
        if (!running) return
        val addr = device.address
        if (clients.containsKey(addr) || connecting.containsKey(addr)) return
        if (servers.containsKey(addr)) return // already linked the other way
        if (clients.size >= MAX_CLIENT_LINKS) return
        val now = SystemClock.elapsedRealtime()
        if ((retryAt[addr] ?: 0L) > now) return
        val gatt = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(ctx, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(ctx, false, clientCallback)
            }
        } catch (e: Exception) {
            null
        } ?: return
        connecting[addr] = now
        clients[addr] = ClientLink(gatt)
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                val addr = gatt.device.address
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    if (!gatt.requestMtu(TARGET_MTU)) gatt.discoverServices()
                } else {
                    connecting.remove(addr)
                    val l = clients.remove(addr)
                    try { gatt.close() } catch (e: Exception) {}
                    if (l?.ready == true) emit(mapOf("e" to "down", "link" to "c:$addr"))
                    retryAt[addr] = SystemClock.elapsedRealtime() + RETRY_AFTER_MS
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                clients[gatt.device.address]?.mtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23
                if (!gatt.discoverServices()) gatt.disconnect()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                val l = clients[gatt.device.address] ?: return@post
                val ch = gatt.getService(SERVICE_UUID)?.getCharacteristic(CHAR_UUID)
                if (status != BluetoothGatt.GATT_SUCCESS || ch == null) {
                    gatt.disconnect()
                    return@post
                }
                l.ch = ch
                gatt.setCharacteristicNotification(ch, true)
                val cccd = ch.getDescriptor(CCCD_UUID)
                if (cccd == null) {
                    markReady(gatt)
                    return@post
                }
                val ok = if (Build.VERSION.SDK_INT >= 33) {
                    gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ==
                        BluetoothGatt.GATT_SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(cccd)
                }
                if (!ok) markReady(gatt) // can still write; notifications may fail
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post { markReady(gatt) }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33) return // the 3-argument version is called instead
            @Suppress("DEPRECATION")
            val data = characteristic.value ?: return
            val copy = data.copyOf()
            main.post { emit(mapOf("e" to "data", "link" to "c:${gatt.device.address}", "data" to copy)) }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray,
        ) {
            val copy = value.copyOf()
            main.post { emit(mapOf("e" to "data", "link" to "c:${gatt.device.address}", "data" to copy)) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post {
                val addr = gatt.device.address
                clients[addr]?.writing = false
                pumpClient(addr)
            }
        }
    }

    private fun markReady(gatt: BluetoothGatt) {
        val addr = gatt.device.address
        val l = clients[addr] ?: return
        if (l.ready) return
        l.ready = true
        connecting.remove(addr)
        emit(mapOf("e" to "up", "link" to "c:$addr", "mtu" to l.mtu))
        pumpClient(addr)
    }

    private fun pumpClient(addr: String) {
        val l = clients[addr] ?: return
        val ch = l.ch ?: return
        if (!l.ready || l.writing) return
        val data = l.queue.pollFirst() ?: return
        val ok = try {
            if (Build.VERSION.SDK_INT >= 33) {
                l.gatt.writeCharacteristic(ch, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) ==
                    BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION")
                ch.value = data
                @Suppress("DEPRECATION")
                l.gatt.writeCharacteristic(ch)
            }
        } catch (e: Exception) {
            false
        }
        if (ok) {
            l.writing = true
            l.writeStartedAt = SystemClock.elapsedRealtime()
        } else {
            // Stack busy: put it back and retry shortly.
            l.queue.addFirst(data)
            main.postDelayed({ pumpClient(addr) }, 30)
        }
    }
}
