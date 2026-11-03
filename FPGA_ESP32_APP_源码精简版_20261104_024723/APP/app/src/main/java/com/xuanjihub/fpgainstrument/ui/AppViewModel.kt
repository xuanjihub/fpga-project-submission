package com.xuanjihub.fpgainstrument.ui

import android.app.Application
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.xuanjihub.fpgainstrument.ble.AdsrField
import com.xuanjihub.fpgainstrument.ble.AdsrState
import com.xuanjihub.fpgainstrument.ble.AndroidBleTransport
import com.xuanjihub.fpgainstrument.ble.BleProtocol
import com.xuanjihub.fpgainstrument.ble.BridgeInfo
import com.xuanjihub.fpgainstrument.ble.BridgeRepository
import com.xuanjihub.fpgainstrument.ble.BridgeSnapshot
import com.xuanjihub.fpgainstrument.ble.DiagLogger
import com.xuanjihub.fpgainstrument.ble.FpgaState
import com.xuanjihub.fpgainstrument.ble.LinkState
import com.xuanjihub.fpgainstrument.ble.ScanHit
import com.xuanjihub.fpgainstrument.ble.SetAdsrOutcome
import com.xuanjihub.fpgainstrument.ble.SetMasterOutcome
import com.xuanjihub.fpgainstrument.ble.SetTimbreOutcome
import com.xuanjihub.fpgainstrument.ble.Timbre
import com.xuanjihub.fpgainstrument.ble.TimbreState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

enum class Phase {
    Disconnected,
    BluetoothOff,
    Connecting,
    Discovering,
    Subscribing,
    ReadingInfo,
    Ready,
    Failed,
}

data class LogEntry(val time: String, val text: String)

data class SetMasterConfirmation(
    val target: Int,
    val expectedRevision: Int,
    val expectedBuild: String,
)

data class SetTimbreConfirmation(
    val target: Int,
    val expectedRevision: Int,
    val expectedBuild: String,
    val boardTimbre: Int,
)

data class SetAdsrConfirmation(
    val field: AdsrField,
    val target: Int,
    val expectedRevision: Int,
    val expectedBuild: String,
    val boardIndex: Int,
)

enum class BatchWriteKind { Master, Timbre, Adsr }

/** One dirty parameter captured at confirm time. */
data class BatchWriteItem(
    val kind: BatchWriteKind,
    val target: Int,
    val label: String,
    val field: AdsrField? = null,
)

data class SetBatchConfirmation(val items: List<BatchWriteItem>)

data class AppUiState(
    val phase: Phase = Phase.Disconnected,
    val phaseDetail: String = "未连接",
    val connectionName: String? = null,
    val bluetoothEnabled: Boolean = false,
    val scanning: Boolean = false,
    val devices: List<ScanHit> = emptyList(),
    val info: BridgeInfo? = null,
    val state: FpgaState? = null,
    val stateReadAtMillis: Long? = null,
    val stateVersion: Long = 0,
    val masterDraft: Int = 0,
    val timbre: TimbreState? = null,
    val timbreReadAtMillis: Long? = null,
    val timbreVersion: Long = 0,
    val timbreDraft: Int = 0,
    val adsr: Map<AdsrField, AdsrState> = emptyMap(),
    val adsrReadAtMillis: Map<AdsrField, Long> = emptyMap(),
    val adsrVersions: Map<AdsrField, Long> = emptyMap(),
    val adsrDrafts: Map<AdsrField, Int> = AdsrField.defaults(),
    val busy: Boolean = false,
    val confirmation: SetMasterConfirmation? = null,
    val timbreConfirmation: SetTimbreConfirmation? = null,
    val adsrConfirmation: SetAdsrConfirmation? = null,
    val batchConfirmation: SetBatchConfirmation? = null,
    val batchSummary: String? = null,
    val notice: String? = null,
    /** Last FPGA state read failure; cleared only by a successful read or a new link. */
    val readFailure: ReadFailure? = null,
    val logs: List<LogEntry> = emptyList(),
) {
    val ready: Boolean get() = phase == Phase.Ready

    /** GATT link is up and the INFO characteristic matched a known profile. */
    val bleConnected: Boolean get() = ready

    /** ESP32 bridge identity is verified. */
    val bridgeInfoVerified: Boolean get() = ready && info != null

    /** A fresh GET_STATE succeeded, so the FPGA parameters below are real values. */
    val fpgaStateVerified: Boolean get() = ready && state != null

    val supportsTimbre: Boolean get() = info?.profile?.supportsTimbre == true
    val supportsAdsr: Boolean get() = info?.profile?.supportsAdsr == true
    val percentDraft: Int get() = BleProtocol.percentOf(masterDraft)
    val canApply: Boolean get() = ready && !busy && state != null
    val canApplyTimbre: Boolean
        get() = ready && supportsTimbre && !busy && timbre != null

    fun canApplyAdsr(field: AdsrField): Boolean =
        ready && supportsAdsr && !busy && adsr[field] != null

    /** Number of parameters whose draft differs from the last board read. */
    val pendingWriteCount: Int
        get() {
            var count = 0
            val board = state
            if (board != null && masterDraft != board.master) count++
            val timbreBoard = timbre
            if (timbreBoard != null && timbreDraft != timbreBoard.timbre) count++
            if (supportsAdsr) {
                for (field in AdsrField.entries) {
                    val fieldBoard = adsr[field] ?: continue
                    val draft = adsrDrafts[field] ?: field.defaultIndex
                    if (draft != fieldBoard.index) count++
                }
            }
            return count
        }

    val hasPendingWrites: Boolean get() = pendingWriteCount > 0
}

/**
 * App state owner. It wires the verified stage-1 transport and CAS repository
 * to the UI.
 */
class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val logger = DiagLogger(application.applicationContext)
    private val transport = AndroidBleTransport(application.applicationContext, logger)
    private val repository = BridgeRepository(transport, logger)
    private val _ui = MutableStateFlow(AppUiState())
    val ui: StateFlow<AppUiState> = _ui.asStateFlow()

    init {
        refreshBluetoothEnabled()
        viewModelScope.launch {
            transport.link.collect { link ->
                _ui.value = when (link) {
                    is LinkState.Disconnected -> _ui.value.copy(
                        phase = Phase.Disconnected,
                        phaseDetail = "未连接",
                        connectionName = null,
                        info = null,
                        state = null,
                        stateReadAtMillis = null,
                        timbre = null,
                        timbreReadAtMillis = null,
                        adsr = emptyMap(),
                        adsrReadAtMillis = emptyMap(),
                        confirmation = null,
                        timbreConfirmation = null,
                        adsrConfirmation = null,
                        batchConfirmation = null,
                        readFailure = null,
                    )
                    is LinkState.BluetoothOff -> _ui.value.copy(
                        phase = Phase.BluetoothOff,
                        phaseDetail = "蓝牙未开启",
                        bluetoothEnabled = false,
                        info = null,
                        state = null,
                        stateReadAtMillis = null,
                        timbre = null,
                        timbreReadAtMillis = null,
                        adsr = emptyMap(),
                        adsrReadAtMillis = emptyMap(),
                        confirmation = null,
                        timbreConfirmation = null,
                        adsrConfirmation = null,
                        batchConfirmation = null,
                        readFailure = null,
                    )
                    is LinkState.Connecting -> _ui.value.copy(
                        phase = Phase.Connecting,
                        phaseDetail = "正在连接 ${link.address}",
                        busy = true,
                        info = null,
                        state = null,
                        stateReadAtMillis = null,
                        timbre = null,
                        timbreReadAtMillis = null,
                        adsr = emptyMap(),
                        adsrReadAtMillis = emptyMap(),
                        confirmation = null,
                        timbreConfirmation = null,
                        adsrConfirmation = null,
                        batchConfirmation = null,
                        readFailure = null,
                    )
                    is LinkState.Discovering -> _ui.value.copy(
                        phase = Phase.Discovering,
                        phaseDetail = "正在发现 GATT 服务",
                    )
                    is LinkState.Subscribing -> _ui.value.copy(
                        phase = Phase.Subscribing,
                        phaseDetail = "正在订阅 RESULT 通知",
                    )
                    is LinkState.ReadingInfo -> _ui.value.copy(
                        phase = Phase.ReadingInfo,
                        phaseDetail = "正在读取并校验 INFO",
                    )
                    is LinkState.Ready -> {
                        val info = runCatching { BleProtocol.parseInfo(link.infoRaw) }.getOrNull()
                        val profile = info?.profile
                        _ui.value.copy(
                            phase = Phase.Ready,
                            phaseDetail = when {
                                profile?.supportsAdsr == true ->
                                    "BLE 与 ESP32 INFO 已验证，可读取/写入 MASTER、音色与 ADSR"
                                profile?.supportsTimbre == true ->
                                    "BLE 与 ESP32 INFO 已验证，可读取/写入 MASTER 与音色"
                                else -> "BLE 与 ESP32 INFO 已验证，可读取/写入 MASTER"
                            },
                            connectionName = link.name ?: link.address,
                            bluetoothEnabled = true,
                            info = info,
                            readFailure = null,
                        )
                    }
                    is LinkState.Failed -> _ui.value.copy(
                        phase = Phase.Failed,
                        phaseDetail = link.message,
                        notice = link.message,
                        busy = false,
                        info = null,
                        state = null,
                        stateReadAtMillis = null,
                        timbre = null,
                        timbreReadAtMillis = null,
                        adsr = emptyMap(),
                        adsrReadAtMillis = emptyMap(),
                        confirmation = null,
                        timbreConfirmation = null,
                        adsrConfirmation = null,
                        batchConfirmation = null,
                        readFailure = null,
                    )
                }
            }
        }
        viewModelScope.launch {
            transport.scanHits.collect { hits ->
                _ui.value = _ui.value.copy(devices = hits)
            }
        }
        viewModelScope.launch {
            transport.isScanning.collect { scanning ->
                _ui.value = _ui.value.copy(scanning = scanning)
            }
        }
        viewModelScope.launch {
            repository.snapshot.collect { snapshot ->
                applySnapshot(snapshot)
            }
        }
        viewModelScope.launch {
            logger.lines.collect { line ->
                val entry = LogEntry(line.time, "${line.level}/${line.tag} ${line.message}")
                _ui.value = _ui.value.copy(
                    logs = (_ui.value.logs + entry).takeLast(MAX_LOG_LINES),
                )
            }
        }
    }

    private fun applySnapshot(snapshot: BridgeSnapshot) {
        _ui.value = _ui.value.applyBridgeSnapshot(snapshot)
    }

    /** One line per layer: BLE, INFO and FPGA are reported separately. */
    private fun logVerifiedLayers(snapshot: BridgeSnapshot) {
        val info = snapshot.info ?: _ui.value.info
        addLog(
            "链路层级：BLE=已连接 INFO=已验证(${info?.firmware}/${info?.buildId}) " +
                "FPGA=已验证(${snapshot.state?.buildHex} rev ${snapshot.state?.revision})",
        )
    }

    private fun recordReadFailure(error: Exception, prefix: String) {
        val failure = classifyReadFailure(error)
        val stillConnected = _ui.value.ready
        addLog(
            "$prefix：BLE=${if (stillConnected) "已连接" else "未连接"} " +
                "INFO=${if (_ui.value.info != null) "已验证" else "未验证"} " +
                "FPGA=未验证 (${failure.kind}) ${failure.detail}",
        )
        _ui.value = _ui.value.copy(
            busy = false,
            readFailure = if (stillConnected) failure else null,
            batchSummary = null,
            notice = if (stillConnected) {
                "BLE 已连接，ESP32 INFO 已验证；FPGA 状态未验证：${failure.detail}"
            } else {
                error.message ?: prefix
            },
        )
    }

    fun refreshBluetoothEnabled() {
        val manager = getApplication<Application>()
            .getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val enabled = manager?.adapter?.isEnabled == true
        _ui.value = _ui.value.copy(bluetoothEnabled = enabled)
    }

    fun startScan() {
        refreshBluetoothEnabled()
        if (!_ui.value.bluetoothEnabled) {
            _ui.value = _ui.value.copy(
                phase = Phase.BluetoothOff,
                phaseDetail = "蓝牙未开启",
                notice = "请先在系统设置中开启蓝牙",
            )
            return
        }
        transport.startScan()
    }

    fun stopScan() = transport.stopScan()

    fun connect(address: String) {
        if (_ui.value.busy) return
        _ui.value = _ui.value.copy(busy = true, notice = null)
        viewModelScope.launch {
            try {
                transport.connect(address)
                _ui.value = _ui.value.copy(notice = "BLE 已连接，ESP32 INFO 已验证；正在读取 FPGA 状态")
                val snapshot = repository.refresh()
                logVerifiedLayers(snapshot)
                _ui.value = _ui.value.copy(
                    busy = false,
                    readFailure = null,
                    notice = "BLE 已连接 · ESP32 INFO 已验证 · FPGA 状态已读取；未修改板端参数",
                )
            } catch (error: Exception) {
                recordReadFailure(error, prefix = "连接后读取 FPGA 状态失败")
            }
        }
    }

    fun disconnect() {
        transport.disconnect()
        _ui.value = _ui.value.copy(
            phase = Phase.Disconnected,
            phaseDetail = "未连接",
            connectionName = null,
            info = null,
            state = null,
            stateReadAtMillis = null,
            timbre = null,
            timbreReadAtMillis = null,
            adsr = emptyMap(),
            adsrReadAtMillis = emptyMap(),
            confirmation = null,
            timbreConfirmation = null,
            adsrConfirmation = null,
            batchConfirmation = null,
            busy = false,
            readFailure = null,
            notice = "已断开；App 不会自动重放旧 SET",
        )
    }

    fun refresh() {
        if (_ui.value.busy || !_ui.value.ready) return
        _ui.value = _ui.value.copy(busy = true, notice = null)
        viewModelScope.launch {
            try {
                val snapshot = repository.refresh()
                logVerifiedLayers(snapshot)
                _ui.value = _ui.value.copy(
                    busy = false,
                    readFailure = null,
                    notice = "已刷新：BLE、ESP32 INFO 与 FPGA 状态均已验证",
                )
            } catch (error: Exception) {
                recordReadFailure(error, prefix = "刷新失败")
            }
        }
    }

    fun updateMasterDraft(value: Float) {
        val index = (value * 16f).roundToInt().coerceIn(0, 16)
        _ui.value = _ui.value.copy(masterDraft = index, batchSummary = null, notice = null)
    }

    fun requestApply() {
        val current = _ui.value
        val boardState = current.state
        if (!current.ready || boardState == null) {
            _ui.value = current.copy(notice = "尚未连接或未读到状态")
            return
        }
        if (current.busy) return
        _ui.value = current.copy(
            confirmation = SetMasterConfirmation(
                target = current.masterDraft,
                expectedRevision = boardState.revision,
                expectedBuild = boardState.buildHex,
            ),
            timbreConfirmation = null,
            notice = null,
        )
    }

    fun dismissConfirmation() {
        _ui.value = _ui.value.copy(confirmation = null)
    }

    fun confirmApply() {
        val current = _ui.value
        val confirmation = current.confirmation ?: return
        if (!current.canApply) {
            _ui.value = current.copy(confirmation = null, notice = "连接或控制授权已变化，请重新读取状态后确认")
            return
        }
        _ui.value = _ui.value.copy(confirmation = null, busy = true, notice = null)
        viewModelScope.launch {
            val outcome = repository.setMaster(confirmation.target)
            val message = when (outcome) {
                is SetMasterOutcome.Applied ->
                    "已应用并新鲜读回：MASTER ${outcome.fresh.masterPercent}%（index ${outcome.fresh.master}），revision ${outcome.fresh.revision}"

                is SetMasterOutcome.Rejected -> when (outcome.status) {
                    BleProtocol.BUSY ->
                        "板端 BUSY（可能正在编辑或按住 STOP）：未写入，未自动重试"
                    BleProtocol.REVISION_CONFLICT ->
                        "revision 冲突：状态已变化，未写入，未自动重试；请刷新后重试"
                    BleProtocol.OUTCOME_UNKNOWN ->
                        "板端报告 OUTCOME_UNKNOWN：写入可能已提交，未自动重发"
                    else ->
                        "板端拒绝 ${BleProtocol.statusName(outcome.status)}：未写入，未自动重试"
                }

                is SetMasterOutcome.Inconsistent ->
                    if (outcome.fresh == null) {
                        "SET 返回 ACK（revision ${outcome.ack.revision}），但新鲜读回失败：实际状态待核对，不计为已应用"
                    } else {
                        "SET 返回 ACK，但新鲜读回不一致（ack rev ${outcome.ack.revision}，实际 rev ${outcome.fresh.revision}）：不计为已应用"
                    }

                is SetMasterOutcome.Unknown ->
                    "结果未知：${outcome.message}。未自动重发；" +
                        if (outcome.observed == null) "尚无新鲜读回，请重新连接后读取" else "已读取实际状态供核对"

                is SetMasterOutcome.Failed ->
                    "未写入：${outcome.message}"
            }
            addLog(message)
            _ui.value = _ui.value.copy(busy = false, notice = message)
        }
    }

    fun updateTimbreDraft(value: Int) {
        _ui.value = _ui.value.copy(timbreDraft = value.coerceIn(0, 3), batchSummary = null, notice = null)
    }

    fun requestApplyTimbre() {
        val current = _ui.value
        val boardTimbre = current.timbre
        if (!current.ready || !current.supportsTimbre) {
            _ui.value = current.copy(notice = "当前固件不支持音色命令")
            return
        }
        if (boardTimbre == null) {
            _ui.value = current.copy(notice = "尚未读到板端音色，请刷新")
            return
        }
        if (current.busy) return
        _ui.value = current.copy(
            timbreConfirmation = SetTimbreConfirmation(
                target = current.timbreDraft,
                expectedRevision = boardTimbre.revision,
                expectedBuild = boardTimbre.buildHex,
                boardTimbre = boardTimbre.timbre,
            ),
            confirmation = null,
            notice = null,
        )
    }

    fun dismissTimbreConfirmation() {
        _ui.value = _ui.value.copy(timbreConfirmation = null)
    }

    fun confirmApplyTimbre() {
        val current = _ui.value
        val confirmation = current.timbreConfirmation ?: return
        if (!current.canApplyTimbre) {
            _ui.value = current.copy(
                timbreConfirmation = null,
                notice = "连接、音色能力或控制授权已变化，请刷新后确认",
            )
            return
        }
        _ui.value = current.copy(timbreConfirmation = null, busy = true, notice = null)
        viewModelScope.launch {
            val outcome = repository.setTimbre(confirmation.target)
            val message = when (outcome) {
                is SetTimbreOutcome.Applied ->
                    "已应用并新鲜读回：音色 ${outcome.fresh.label}（${outcome.fresh.timbre}），" +
                        "revision ${outcome.fresh.revision}；作用于下一次新触发"

                is SetTimbreOutcome.Rejected -> when (outcome.status) {
                    BleProtocol.BUSY ->
                        "板端 BUSY（可能正在编辑或按住 STOP）：音色未写入，未自动重试"
                    BleProtocol.REVISION_CONFLICT ->
                        "revision 冲突：状态已变化，音色未写入，未自动重试；请刷新后重试"
                    BleProtocol.OUTCOME_UNKNOWN ->
                        "板端报告 OUTCOME_UNKNOWN：音色写入可能已提交，未自动重发"
                    else ->
                        "板端拒绝 ${BleProtocol.statusName(outcome.status)}：音色未写入，未自动重试"
                }

                is SetTimbreOutcome.Inconsistent ->
                    if (outcome.fresh == null) {
                        "SET_TIMBRE 返回 ACK（revision ${outcome.ack.revision}），但新鲜读回失败：实际音色待核对，不计为已应用"
                    } else {
                        "SET_TIMBRE 返回 ACK，但新鲜读回不一致（ack rev ${outcome.ack.revision}，实际 rev ${outcome.fresh.revision}）：不计为已应用"
                    }

                is SetTimbreOutcome.Unknown ->
                    "音色结果未知：${outcome.message}。未自动重发；" +
                        if (outcome.observed == null) "尚无新鲜读回，请重新连接后读取" else "已读取实际音色供核对"

                is SetTimbreOutcome.Failed ->
                    "音色未写入：${outcome.message}"
            }
            addLog(message)
            _ui.value = _ui.value.copy(busy = false, notice = message)
        }
    }

    fun updateAdsrDraft(field: AdsrField, value: Int) {
        val clamped = value.coerceIn(0, field.maxIndex)
        _ui.value = _ui.value.copy(
            adsrDrafts = _ui.value.adsrDrafts + (field to clamped),
            batchSummary = null,
            notice = null,
        )
    }

    fun requestApplyAdsr(field: AdsrField) {
        val current = _ui.value
        if (!current.ready || !current.supportsAdsr) {
            _ui.value = current.copy(notice = "当前固件不支持 ADSR 命令")
            return
        }
        val board = current.adsr[field]
        if (board == null) {
            _ui.value = current.copy(notice = "尚未读到 ${field.label}，请刷新")
            return
        }
        if (current.busy) return
        _ui.value = current.copy(
            adsrConfirmation = SetAdsrConfirmation(
                field = field,
                target = current.adsrDrafts[field] ?: board.index,
                expectedRevision = board.revision,
                expectedBuild = board.buildHex,
                boardIndex = board.index,
            ),
            confirmation = null,
            timbreConfirmation = null,
            notice = null,
        )
    }

    fun dismissAdsrConfirmation() {
        _ui.value = _ui.value.copy(adsrConfirmation = null)
    }

    fun confirmApplyAdsr() {
        val current = _ui.value
        val confirmation = current.adsrConfirmation ?: return
        if (!current.canApplyAdsr(confirmation.field)) {
            _ui.value = current.copy(
                adsrConfirmation = null,
                notice = "连接、ADSR 能力或控制授权已变化，请刷新后确认",
            )
            return
        }
        _ui.value = current.copy(adsrConfirmation = null, busy = true, notice = null)
        viewModelScope.launch {
            val field = confirmation.field
            val outcome = repository.setAdsr(field, confirmation.target)
            val targetText = "${field.label} 档位 ${confirmation.target}/${field.maxIndex}" +
                "（包络码 ${BleProtocol.envelopeCode(field, confirmation.target)}）"
            val message = when (outcome) {
                is SetAdsrOutcome.Applied ->
                    "已应用并新鲜读回：${BleProtocol.adsrSummary(outcome.fresh)}"

                is SetAdsrOutcome.Rejected -> when (outcome.status) {
                    BleProtocol.BUSY ->
                        "板端 BUSY（可能正在编辑或按住 STOP）：${field.label} 未写入，未自动重试"
                    BleProtocol.REVISION_CONFLICT ->
                        "revision 冲突：状态已变化，${field.label} 未写入，未自动重试；请刷新后重试"
                    BleProtocol.OUTCOME_UNKNOWN ->
                        "板端报告 OUTCOME_UNKNOWN：${field.label} 写入可能已提交，未自动重发"
                    else ->
                        "板端拒绝 ${BleProtocol.statusName(outcome.status)}：" +
                            "${field.label} 未写入，未自动重试"
                }

                is SetAdsrOutcome.Inconsistent ->
                    if (outcome.fresh == null) {
                        "SET_${field.label} 返回 ACK（revision ${outcome.ack.revision}），" +
                            "但新鲜读回失败：实际值待核对，不计为已应用"
                    } else {
                        "SET_${field.label} 返回 ACK，但新鲜读回不一致" +
                            "（ack rev ${outcome.ack.revision}，实际 rev ${outcome.fresh.revision}）：" +
                            "不计为已应用"
                    }

                is SetAdsrOutcome.Unknown ->
                    "${field.label} 结果未知：${outcome.message}。未自动重发；" +
                        if (outcome.observed == null) "尚无新鲜读回，请重新连接后读取" else "已读取实际值供核对"

                is SetAdsrOutcome.Failed ->
                    "${field.label} 未写入：${outcome.message}"
            }
            addLog("$targetText -> $message")
            _ui.value = _ui.value.copy(busy = false, notice = message)
        }
    }

    fun requestApplyBatch() {
        val current = _ui.value
        if (!current.ready) {
            _ui.value = current.copy(notice = "尚未连接真实设备")
            return
        }
        if (current.busy) return
        val items = buildList {
            current.state?.let { board ->
                if (current.masterDraft != board.master) {
                    add(
                        BatchWriteItem(
                            kind = BatchWriteKind.Master,
                            target = current.masterDraft,
                            label = "MASTER ${BleProtocol.percentOf(current.masterDraft)}%",
                        ),
                    )
                }
            }
            val timbreBoard = current.timbre
            if (current.supportsTimbre && timbreBoard != null && current.timbreDraft != timbreBoard.timbre) {
                add(
                    BatchWriteItem(
                        kind = BatchWriteKind.Timbre,
                        target = current.timbreDraft,
                        label = "音色 ${Timbre.from(current.timbreDraft).label}",
                    ),
                )
            }
            if (current.supportsAdsr) {
                for (field in AdsrField.entries) {
                    val board = current.adsr[field] ?: continue
                    val draft = current.adsrDrafts[field] ?: field.defaultIndex
                    if (draft != board.index) {
                        add(
                            BatchWriteItem(
                                kind = BatchWriteKind.Adsr,
                                target = draft,
                                label = "${field.label} $draft/${field.maxIndex}",
                                field = field,
                            ),
                        )
                    }
                }
            }
        }
        if (items.isEmpty()) {
            _ui.value = current.copy(notice = "没有待写入的更改")
            return
        }
        _ui.value = current.copy(
            batchConfirmation = SetBatchConfirmation(items),
            batchSummary = null,
            notice = null,
        )
    }

    fun dismissBatchConfirmation() {
        _ui.value = _ui.value.copy(batchConfirmation = null)
    }

    /**
     * Writes every dirty parameter once, in a fixed order (MASTER, timbre, A/D/S/R).
     *
     * This is a frontend loop of independent compare-and-set operations. Each
     * repository call performs its own fresh GET, so later items see the revision
     * bumped by earlier ones. Any unconfirmed result stops the loop.
     */
    fun confirmApplyBatch() {
        val current = _ui.value
        val confirmation = current.batchConfirmation ?: return
        if (!current.ready || current.busy) {
            _ui.value = current.copy(
                batchConfirmation = null,
                notice = "连接或 busy 状态已变化，请重试",
            )
            return
        }
        val total = confirmation.items.size
        _ui.value = current.copy(
            batchConfirmation = null,
            busy = true,
            batchSummary = null,
            notice = null,
        )
        viewModelScope.launch {
            var applied = 0
            var failure: String? = null
            for (item in confirmation.items) {
                val reason = when (item.kind) {
                    BatchWriteKind.Master -> describeMasterOutcome(repository.setMaster(item.target))
                    BatchWriteKind.Timbre -> describeTimbreOutcome(repository.setTimbre(item.target))
                    BatchWriteKind.Adsr -> item.field?.let { field ->
                        describeAdsrOutcome(repository.setAdsr(field, item.target))
                    } ?: "字段缺失"
                }
                if (reason == null) {
                    applied++
                    addLog("${item.label} -> 已应用并新鲜读回一致")
                } else {
                    failure = "${item.label}：$reason"
                    addLog("${item.label} -> 未确认：$reason")
                    break
                }
            }
            val summary = if (failure == null) {
                "已写入 $applied/$total 项，全部确认读回一致"
            } else {
                "已写入 $applied/$total 项；$failure。后续未发送，未自动重试"
            }
            _ui.value = _ui.value.copy(busy = false, batchSummary = summary, notice = summary)
        }
    }

    /** Discards every unconfirmed draft and syncs the controls to the last board read. */
    fun resetDrafts() {
        val current = _ui.value
        if (current.busy) return
        val hadPending = current.hasPendingWrites
        val drafts = current.adsrDrafts.toMutableMap()
        for ((field, board) in current.adsr) {
            drafts[field] = board.index
        }
        _ui.value = current.copy(
            masterDraft = current.state?.master ?: current.masterDraft,
            timbreDraft = current.timbre?.timbre ?: current.timbreDraft,
            adsrDrafts = drafts,
            batchSummary = null,
            notice = if (hadPending) "已撤销未写入的更改" else "没有待撤销的更改",
        )
    }

    private fun describeMasterOutcome(outcome: SetMasterOutcome): String? = when (outcome) {
        is SetMasterOutcome.Applied -> null
        is SetMasterOutcome.Rejected -> rejectReason(outcome.status)
        is SetMasterOutcome.Inconsistent -> "ACK 后读回不一致，不计为已应用"
        is SetMasterOutcome.Unknown -> "结果未知，未自动重发"
        is SetMasterOutcome.Failed -> outcome.message
    }

    private fun describeTimbreOutcome(outcome: SetTimbreOutcome): String? = when (outcome) {
        is SetTimbreOutcome.Applied -> null
        is SetTimbreOutcome.Rejected -> rejectReason(outcome.status)
        is SetTimbreOutcome.Inconsistent -> "ACK 后读回不一致，不计为已应用"
        is SetTimbreOutcome.Unknown -> "结果未知，未自动重发"
        is SetTimbreOutcome.Failed -> outcome.message
    }

    private fun describeAdsrOutcome(outcome: SetAdsrOutcome): String? = when (outcome) {
        is SetAdsrOutcome.Applied -> null
        is SetAdsrOutcome.Rejected -> rejectReason(outcome.status)
        is SetAdsrOutcome.Inconsistent -> "ACK 后读回不一致，不计为已应用"
        is SetAdsrOutcome.Unknown -> "结果未知，未自动重发"
        is SetAdsrOutcome.Failed -> outcome.message
    }

    private fun rejectReason(status: Int): String = when (status) {
        BleProtocol.BUSY -> "板端 BUSY（可能正在编辑或按住 STOP）"
        BleProtocol.REVISION_CONFLICT -> "revision 冲突"
        BleProtocol.OUTCOME_UNKNOWN -> "板端报告 OUTCOME_UNKNOWN"
        else -> "被拒绝 ${BleProtocol.statusName(status)}"
    }

    fun clearLogs() {
        _ui.value = _ui.value.copy(logs = emptyList())
    }

    fun onNotice(message: String) {
        _ui.value = _ui.value.copy(notice = message)
    }

    private fun addLog(text: String) {
        logger.i("APP", text)
    }

    val logPath: String get() = logger.absolutePath

    fun shareLogs(context: Context) {
        runCatching {
            context.startActivity(Intent.createChooser(logger.shareIntent(), "分享 BLE 日志"))
        }.onFailure {
            logger.e("APP", "分享日志失败：${it.message}", it)
        }
    }

    override fun onCleared() {
        transport.close()
        super.onCleared()
    }

    companion object {
        const val APP_VERSION = "0.4.4"
        private const val MAX_LOG_LINES = 200
    }
}
