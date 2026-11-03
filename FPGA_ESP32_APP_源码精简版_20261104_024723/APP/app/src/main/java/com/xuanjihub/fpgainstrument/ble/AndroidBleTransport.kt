package com.xuanjihub.fpgainstrument.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicLong

/** One scan hit; only devices advertising the stage-1 service are kept. */
data class ScanHit(
    val name: String,
    val address: String,
    val rssi: Int,
)

sealed interface LinkState {
    data object Disconnected : LinkState
    data object BluetoothOff : LinkState
    data class Connecting(val address: String) : LinkState
    data class Discovering(val address: String) : LinkState
    data class Subscribing(val address: String) : LinkState
    data class ReadingInfo(val address: String) : LinkState

    /**
     * A GATT session that has read the INFO characteristic. `sessionId` changes
     * for every connection attempt, so a protocol confirmation stays bound to
     * the session that produced it.
     */
    data class Ready(
        val address: String,
        val name: String?,
        val infoRaw: ByteArray,
        val sessionId: Long,
    ) : LinkState

    data class Failed(val message: String) : LinkState
}

/** The transport boundary. */
interface BridgeTransport {
    val link: StateFlow<LinkState>
    val scanHits: StateFlow<List<ScanHit>>
    val isScanning: StateFlow<Boolean>
    val logs: SharedFlow<String>

    fun startScan()
    fun stopScan()
    suspend fun connect(address: String)
    fun disconnect()

    /** Sends one 20-byte request and waits for its matching RESULT notification. */
    suspend fun request(request: Frame, timeoutMs: Long): Frame

    fun close()
}

class BridgeException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * True when Android accepted the ATT write but no trustworthy business result
 * arrived. Callers treat this as "may have been applied".
 */
class BridgeTimeout(val submitted: Boolean) : Exception(
    if (submitted) "等待板端响应超时（写入可能已提交，结果未知）" else "写入超时（尚未提交）",
)

class BridgeDisconnected(message: String = "蓝牙连接已断开") : Exception(message)

/**
 * Android BLE transport for the verified stage-1 GATT profile.
 *
 * It scans, connects, subscribes RESULT, reads INFO and exchanges 20-byte frames.
 * The one-request rule is enforced with a mutex.
 */
@SuppressLint("MissingPermission")
class AndroidBleTransport(
    private val context: Context,
    private val logger: DiagLogger? = null,
) : BridgeTransport {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val requestMutex = Mutex()
    private val TAG = "FpgaBle"

    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter

    private val _link = MutableStateFlow<LinkState>(LinkState.Disconnected)
    override val link: StateFlow<LinkState> = _link.asStateFlow()

    private val _scanHits = MutableStateFlow<List<ScanHit>>(emptyList())
    override val scanHits: StateFlow<List<ScanHit>> = _scanHits.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    override val isScanning: StateFlow<Boolean> = _isScanning.asStateFlow()

    private val _logs = MutableSharedFlow<String>(extraBufferCapacity = 64)
    override val logs: SharedFlow<String> = _logs.asSharedFlow()

    private var scanTimeoutJob: Job? = null
    private var gatt: BluetoothGatt? = null
    private var infoChar: BluetoothGattCharacteristic? = null
    private var commandChar: BluetoothGattCharacteristic? = null
    private var resultChar: BluetoothGattCharacteristic? = null

    private var connectDeferred: CompletableDeferred<Unit>? = null
    private var discoverDeferred: CompletableDeferred<Unit>? = null
    private var descriptorDeferred: CompletableDeferred<Unit>? = null
    private var infoDeferred: CompletableDeferred<ByteArray>? = null
    private var writeDeferred: CompletableDeferred<Unit>? = null
    private var pendingResult: CompletableDeferred<Frame>? = null
    private var pendingRequestId: Int? = null
    private var intentionalDisconnect = false
    private val sessionCounter = AtomicLong(0)

    private fun log(message: String) {
        logger?.d("BLE", message)
        Log.d(TAG, message)
        _logs.tryEmit(message)
    }

    private fun logError(message: String, error: Throwable? = null) {
        logger?.e("BLE", message, error)
        Log.w(TAG, message, error)
        _logs.tryEmit(message)
    }

    override fun startScan() {
        val adapter = adapter
        if (adapter == null) {
            _link.value = LinkState.Failed("本机不支持蓝牙")
            return
        }
        if (!adapter.isEnabled) {
            _link.value = LinkState.BluetoothOff
            return
        }
        if (!hasScanPermission()) {
            _link.value = LinkState.Failed("缺少蓝牙扫描权限")
            return
        }
        stopScan()
        _scanHits.value = emptyList()
        _isScanning.value = true
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(BleProtocol.SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .build()
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            _isScanning.value = false
            _link.value = LinkState.Failed("蓝牙扫描器不可用")
            return
        }
        try {
            scanner.startScan(listOf(filter), settings, scanCallback)
            log("开始扫描 stage-1 服务")
            scanTimeoutJob = scope.launch {
                delay(10_000)
                stopScan()
                log("扫描超时（10 秒）")
            }
        } catch (security: SecurityException) {
            _isScanning.value = false
            _link.value = LinkState.Failed("蓝牙扫描权限被拒绝")
        }
    }

    override fun stopScan() {
        scanTimeoutJob?.cancel()
        scanTimeoutJob = null
        if (_isScanning.value) {
            try {
                adapter?.bluetoothLeScanner?.stopScan(scanCallback)
            } catch (_: SecurityException) {
                // Permission was revoked while scanning; nothing to clean up.
            }
        }
        _isScanning.value = false
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val name = runCatching { device.name }
                .getOrNull()
                ?: result.scanRecord?.deviceName
                ?: "未命名设备"
            val hit = ScanHit(name = name, address = device.address, rssi = result.rssi)
            val uuids = result.scanRecord?.serviceUuids?.joinToString(",") { it.uuid.toString() } ?: "-"
            log("scan hit name=$name address=${device.address} rssi=${result.rssi} services=$uuids")
            val current = _scanHits.value.filterNot { it.address == hit.address }
            _scanHits.value = (current + hit).sortedByDescending { it.rssi }
        }

        override fun onScanFailed(errorCode: Int) {
            _isScanning.value = false
            _link.value = LinkState.Failed("扫描失败（error=$errorCode）")
            log("扫描失败，error=$errorCode")
        }
    }

    override suspend fun connect(address: String) {
        val adapter = adapter ?: throw BridgeException("本机不支持蓝牙")
        if (!adapter.isEnabled) {
            _link.value = LinkState.BluetoothOff
            throw BridgeException("蓝牙未开启")
        }
        if (!hasConnectPermission()) {
            _link.value = LinkState.Failed("缺少蓝牙连接权限")
            throw BridgeException("缺少蓝牙连接权限")
        }
        stopScan()
        closeGatt()
        intentionalDisconnect = false
        val sessionId = sessionCounter.incrementAndGet()
        _link.value = LinkState.Connecting(address)
        connectDeferred = CompletableDeferred()
        discoverDeferred = CompletableDeferred()
        descriptorDeferred = CompletableDeferred()
        infoDeferred = CompletableDeferred()
        val device = adapter.getRemoteDevice(address)
        log("connectGatt address=$address")
        val newGatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            ?: throw BridgeException("无法创建 GATT 连接")
        gatt = newGatt
        try {
            withTimeout(12_000) { connectDeferred?.await() }
            _link.value = LinkState.Discovering(address)
            withTimeout(12_000) { discoverDeferred?.await() }
            _link.value = LinkState.Subscribing(address)
            withTimeout(12_000) { descriptorDeferred?.await() }
            _link.value = LinkState.ReadingInfo(address)
            val info = withTimeout(12_000) { infoDeferred?.await() }
                ?: throw BridgeException("未读到 INFO")
            BleProtocol.parseInfo(info)
            val name = runCatching { device.name }.getOrNull()
            _link.value = LinkState.Ready(address, name, info, sessionId)
            log("已连接 ${name ?: address}，INFO 校验通过")
        } catch (timeout: TimeoutCancellationException) {
            val stage = when (_link.value) {
                is LinkState.Connecting -> "GATT 连接"
                is LinkState.Discovering -> "服务发现"
                is LinkState.Subscribing -> "订阅 RESULT"
                is LinkState.ReadingInfo -> "读取 INFO"
                else -> "初始化"
            }
            closeGatt()
            val message = "${stage}超时（12 秒）"
            logError(message)
            _link.value = LinkState.Failed(message)
            throw BridgeException(message)
        } catch (error: Exception) {
            closeGatt()
            logError("连接失败：${error.message}", error)
            if (error !is BridgeException) {
                _link.value = LinkState.Failed(error.message ?: "连接失败")
            }
            throw error
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            log("onConnectionStateChange status=$status newState=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failAll("GATT 连接失败（status=$status）")
                return
            }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    log("GATT 已连接，发现服务")
                    connectDeferred?.complete(Unit)
                    if (!gatt.discoverServices()) failAll("无法发现 GATT 服务")
                }

                BluetoothProfile.STATE_DISCONNECTED -> {
                    failAll(BridgeDisconnected().message ?: "连接已断开")
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            log("onServicesDiscovered status=$status")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failAll("服务发现失败（status=$status）")
                return
            }
            val service = gatt.getService(BleProtocol.SERVICE_UUID)
            if (service == null) {
                failAll("目标服务不存在")
                return
            }
            log("service=${service.uuid} characteristics=" +
                service.characteristics.joinToString(",") { "${it.uuid}/props=${it.properties}" })
            infoChar = service.getCharacteristic(BleProtocol.INFO_UUID)
            commandChar = service.getCharacteristic(BleProtocol.COMMAND_UUID)
            resultChar = service.getCharacteristic(BleProtocol.RESULT_UUID)
            if (infoChar == null || commandChar == null || resultChar == null) {
                failAll("目标 GATT 特征不完整")
                return
            }
            // Release the service-discovery await before the CCCD/INFO handshake;
            // connect() waits on that deferred until it completes.
            discoverDeferred?.complete(Unit)
            // Contract order: subscribe RESULT first, then read the real INFO.
            val result = resultChar ?: return
            if (!gatt.setCharacteristicNotification(result, true)) {
                failAll("无法启用 RESULT 通知")
                return
            }
            val cccd = result.getDescriptor(BleProtocol.CLIENT_CHARACTERISTIC_CONFIG)
            if (cccd == null) {
                failAll("RESULT 缺少 CCCD")
                return
            }
            val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            val writeStarted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                cccd.value = value
                @Suppress("DEPRECATION")
                gatt.writeDescriptor(cccd)
            }
            if (!writeStarted) failAll("无法写入 RESULT CCCD")
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            if (descriptor.uuid != BleProtocol.CLIENT_CHARACTERISTIC_CONFIG) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failAll("RESULT 通知订阅失败（status=$status）")
                return
            }
            log("RESULT CCCD 订阅成功；读取 INFO")
            descriptorDeferred?.complete(Unit)
            val info = infoChar ?: return
            val started = gatt.readCharacteristic(info)
            if (!started) failAll("无法读取 INFO")
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            if (characteristic.uuid != BleProtocol.INFO_UUID) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failAll("读取 INFO 失败（status=$status）")
                return
            }
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: ByteArray(0)
            log("onCharacteristicRead INFO len=${value.size} hex=${value.toHex()}")
            infoDeferred?.complete(value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            if (characteristic.uuid != BleProtocol.INFO_UUID) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failAll("读取 INFO 失败（status=$status）")
                return
            }
            log("onCharacteristicRead INFO len=${value.size} hex=${value.toHex()}")
            infoDeferred?.complete(value)
        }

        @Deprecated("Deprecated in API 33, still delivered on older Android")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            if (characteristic.uuid != BleProtocol.RESULT_UUID) return
            handleResult(characteristic.value ?: ByteArray(0))
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            if (characteristic.uuid != BleProtocol.RESULT_UUID) return
            handleResult(value)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (intentionalDisconnect || gatt !== this@AndroidBleTransport.gatt) return
            if (characteristic.uuid != BleProtocol.COMMAND_UUID) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                writeDeferred?.complete(Unit)
            } else {
                writeDeferred?.completeExceptionally(
                    BridgeException("写入 COMMAND 失败（status=$status）"),
                )
            }
        }
    }

    private fun handleResult(value: ByteArray) {
        if (value.isEmpty()) return
        val frame = runCatching { BleProtocol.decodeFrame(value) }
            .onFailure { logError("收到无法解析的 RESULT：${it.message}") }
            .getOrNull() ?: return
        log("RESULT raw=${value.toHex()} opcode=0x%02X status=%s id=%d".format(
            frame.opcode, BleProtocol.statusName(frame.status), frame.requestId,
        ))
        val requested = pendingRequestId
        if (requested != null && requested == frame.requestId) {
            pendingResult?.complete(frame)
        }
    }

    override suspend fun request(request: Frame, timeoutMs: Long): Frame {
        return requestMutex.withLock {
            if (_link.value !is LinkState.Ready) throw BridgeDisconnected("尚未连接")
            val gatt = gatt ?: throw BridgeDisconnected("GATT 已释放")
            val command = commandChar ?: throw BridgeDisconnected("COMMAND 特征不存在")
            val raw = BleProtocol.encodeRequest(request.opcode, request.requestId, request.payload)
            log("write COMMAND raw=${raw.toHex()} opcode=0x%02X id=%d".format(request.opcode, request.requestId))
            val result = CompletableDeferred<Frame>()
            val write = CompletableDeferred<Unit>()
            pendingResult = result
            pendingRequestId = request.requestId
            writeDeferred = write
            var submitted = false
            var writeCompleted = false
            try {
                val writeStarted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(command, raw, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                        BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    run {
                        command.value = raw
                        command.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                        @Suppress("DEPRECATION")
                        gatt.writeCharacteristic(command)
                    }
                }
                if (!writeStarted) throw BridgeException("COMMAND 写入未被接受")
                submitted = true
                log("writeCharacteristic accepted; waiting for completion")
                withTimeout(5_000) { write.await() }
                writeCompleted = true
                log("COMMAND write completed; waiting for RESULT")
                val startedAt = System.currentTimeMillis()
                val frame = withTimeout(timeoutMs) { result.await() }
                log("RESULT id=${request.requestId} elapsed=${System.currentTimeMillis() - startedAt}ms")
                return@withLock frame
            } catch (timeout: TimeoutCancellationException) {
                if (submitted && !writeCompleted) {
                    invalidateIncompleteWrite(gatt, "COMMAND 写入完成回调超时；需重新连接，写入结果未知")
                }
                throw BridgeTimeout(submitted)
            } catch (cancelled: CancellationException) {
                if (submitted && !writeCompleted) {
                    invalidateIncompleteWrite(gatt, "COMMAND 写入完成前被取消；需重新连接，写入结果未知")
                }
                throw cancelled
            } finally {
                pendingResult = null
                pendingRequestId = null
                writeDeferred = null
            }
        }
    }

    private fun invalidateIncompleteWrite(requestGatt: BluetoothGatt, message: String) {
        if (requestGatt !== gatt) return
        // A late callback could otherwise be attributed to a later write on this
        // GATT. Discard the session before any recovery GET.
        closeGatt()
        _link.value = LinkState.Failed(message)
        logError(message)
    }

    override fun disconnect() {
        intentionalDisconnect = true
        stopScan()
        closeGatt()
        _link.value = LinkState.Disconnected
        log("已断开")
    }

    private fun closeGatt() {
        pendingResult?.completeExceptionally(BridgeDisconnected())
        pendingResult = null
        pendingRequestId = null
        writeDeferred?.completeExceptionally(BridgeDisconnected())
        writeDeferred = null
        connectDeferred?.completeExceptionally(BridgeDisconnected())
        discoverDeferred?.completeExceptionally(BridgeDisconnected())
        descriptorDeferred?.completeExceptionally(BridgeDisconnected())
        infoDeferred?.completeExceptionally(BridgeDisconnected())
        connectDeferred = null
        discoverDeferred = null
        descriptorDeferred = null
        infoDeferred = null
        val current = gatt
        gatt = null
        infoChar = null
        commandChar = null
        resultChar = null
        runCatching { current?.disconnect() }
        runCatching { current?.close() }
    }

    private fun failAll(message: String) {
        log(message)
        pendingResult?.completeExceptionally(BridgeDisconnected(message))
        pendingResult = null
        pendingRequestId = null
        writeDeferred?.completeExceptionally(BridgeDisconnected(message))
        writeDeferred = null
        connectDeferred?.completeExceptionally(BridgeDisconnected(message))
        discoverDeferred?.completeExceptionally(BridgeDisconnected(message))
        descriptorDeferred?.completeExceptionally(BridgeDisconnected(message))
        infoDeferred?.completeExceptionally(BridgeDisconnected(message))
        connectDeferred = null
        discoverDeferred = null
        descriptorDeferred = null
        infoDeferred = null
        val current = gatt
        gatt = null
        infoChar = null
        commandChar = null
        resultChar = null
        runCatching { current?.close() }
        _link.value = LinkState.Failed(message)
    }

    override fun close() {
        stopScan()
        closeGatt()
        scope.cancel()
    }

    private fun hasScanPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }
}
