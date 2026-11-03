package com.xuanjihub.fpgainstrument.ble

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import java.util.concurrent.atomic.AtomicInteger

/** Last fresh bridge snapshot. Each parameter keeps its own read time and version. */
data class BridgeSnapshot(
    val info: BridgeInfo? = null,
    val state: FpgaState? = null,
    val stateReadAtMillis: Long? = null,
    val stateVersion: Long = 0,
    val timbre: TimbreState? = null,
    val timbreReadAtMillis: Long? = null,
    val timbreVersion: Long = 0,
    val adsr: Map<AdsrField, AdsrState> = emptyMap(),
    val adsrReadAtMillis: Map<AdsrField, Long> = emptyMap(),
    val adsrVersions: Map<AdsrField, Long> = emptyMap(),
)

class BridgeBusy(message: String) : Exception(message)

/** A SET needs a GET_INFO confirmation bound to the current GATT session. */
class BridgeHandshakeRequired(message: String) : Exception(message)

/**
 * The bridge answered the GET with a non-OK stage-1 status. Kept typed so the App
 * can distinguish `FPGA_UNAVAILABLE` (bridge has no FPGA reply) from BUSY, an
 * unsupported build, or a BLE timeout.
 */
class BridgeStatusError(val operation: String, val status: Int) :
    Exception("$operation 返回 ${BleProtocol.statusName(status)}")

sealed interface SetMasterOutcome {
    /** Publication ACK and a fresh readback agree, and both match the request. */
    data class Applied(val ack: FpgaState, val fresh: FpgaState) : SetMasterOutcome

    /** The FPGA owner refused the write (BUSY / revision conflict / etc.). */
    data class Rejected(val status: Int, val state: FpgaState?) : SetMasterOutcome

    /** SET reported OK, but the fresh readback differs or is unavailable. */
    data class Inconsistent(val ack: FpgaState, val fresh: FpgaState?) : SetMasterOutcome

    /** The write may have been applied. Show the observed state only. */
    data class Unknown(val message: String, val observed: FpgaState?) : SetMasterOutcome

    /** The request failed before the board accepted it. */
    data class Failed(val message: String) : SetMasterOutcome
}

sealed interface SetTimbreOutcome {
    data class Applied(val ack: TimbreState, val fresh: TimbreState) : SetTimbreOutcome
    data class Rejected(val status: Int, val state: TimbreState?) : SetTimbreOutcome
    data class Inconsistent(val ack: TimbreState, val fresh: TimbreState?) : SetTimbreOutcome
    data class Unknown(val message: String, val observed: TimbreState?) : SetTimbreOutcome
    data class Failed(val message: String) : SetTimbreOutcome
}

sealed interface SetAdsrOutcome {
    data class Applied(val ack: AdsrState, val fresh: AdsrState) : SetAdsrOutcome
    data class Rejected(val status: Int, val state: AdsrState?) : SetAdsrOutcome
    data class Inconsistent(val ack: AdsrState, val fresh: AdsrState?) : SetAdsrOutcome
    data class Unknown(val message: String, val observed: AdsrState?) : SetAdsrOutcome
    data class Failed(val message: String) : SetAdsrOutcome
}

/**
 * Stage-1 business layer: GET_INFO / GET_STATE / GET_TIMBRE and the two
 * compare-and-set writes. MASTER and TIMBRE share one operation gate: a second
 * write during any part of a CAS is rejected immediately.
 */
class BridgeRepository(
    private val transport: BridgeTransport,
    private val logger: DiagLogger? = null,
) {
    private val _snapshot = MutableStateFlow(BridgeSnapshot())
    val snapshot: StateFlow<BridgeSnapshot> = _snapshot.asStateFlow()

    private val _logs = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val logs: SharedFlow<String> = _logs.asSharedFlow()

    private val operationMutex = Mutex()
    private val nextRequestId = AtomicInteger(1)

    private data class ConfirmedInfo(
        val sessionId: Long,
        val profile: BleProtocol.BridgeProfile,
    )

    /**
     * Set only after both the INFO characteristic and a GET_INFO response in the
     * current GATT session agree exactly.
     */
    @Volatile
    private var confirmedInfo: ConfirmedInfo? = null
    private var stateVersionCounter = 0L
    private var timbreVersionCounter = 0L
    private val adsrVersionCounters = mutableMapOf<AdsrField, Long>()

    private fun id(): Int {
        while (true) {
            val current = nextRequestId.getAndUpdate { if (it >= 0xFFFF) 1 else it + 1 }
            if (current in 1..0xFFFF) return current
        }
    }

    private fun log(message: String) {
        logger?.i("CAS", message)
        _logs.tryEmit(message)
    }

    private fun logError(message: String, error: Throwable? = null) {
        logger?.w("CAS", message, error)
        _logs.tryEmit(message)
    }

    private fun protocolProfile(): BleProtocol.BridgeProfile {
        val link = transport.link.value
        if (link !is LinkState.Ready) {
            confirmedInfo = null
            throw BridgeDisconnected("尚未连接")
        }
        val profile = BleProtocol.parseInfo(link.infoRaw).profile
        val confirmed = confirmedInfo
        if (confirmed == null ||
            confirmed.sessionId != link.sessionId ||
            confirmed.profile != profile
        ) {
            confirmedInfo = null
            throw BridgeHandshakeRequired("INFO 尚未在当前连接会话确认，请先刷新")
        }
        return profile
    }

    private fun clearSnapshot() {
        val current = _snapshot.value
        _snapshot.value = BridgeSnapshot(
            stateVersion = current.stateVersion,
            timbreVersion = current.timbreVersion,
            adsrVersions = current.adsrVersions,
        )
    }

    private fun publishState(state: FpgaState, readAt: Long) {
        stateVersionCounter += 1
        _snapshot.value = _snapshot.value.copy(
            state = state,
            stateReadAtMillis = readAt,
            stateVersion = stateVersionCounter,
        )
    }

    private fun publishTimbre(timbre: TimbreState, readAt: Long) {
        timbreVersionCounter += 1
        _snapshot.value = _snapshot.value.copy(
            timbre = timbre,
            timbreReadAtMillis = readAt,
            timbreVersion = timbreVersionCounter,
        )
    }

    private fun publishAdsr(state: AdsrState, readAt: Long) {
        val next = (adsrVersionCounters[state.field] ?: 0L) + 1
        adsrVersionCounters[state.field] = next
        val current = _snapshot.value
        _snapshot.value = current.copy(
            adsr = current.adsr + (state.field to state),
            adsrReadAtMillis = current.adsrReadAtMillis + (state.field to readAt),
            adsrVersions = current.adsrVersions + (state.field to next),
        )
    }

    /**
     * Fresh INFO (both the characteristic and GET_INFO), GET_STATE, and — only
     * on the timbre profile — GET_TIMBRE. The exact INFO handshake confirms this
     * GATT session; any INFO failure or mismatch invalidates the confirmation
     * and the old snapshot.
     */
    suspend fun refresh(): BridgeSnapshot {
        if (!operationMutex.tryLock()) {
            throw BridgeBusy("MASTER/TIMBRE 操作正在进行，未刷新")
        }
        try {
            val link = transport.link.value
            if (link !is LinkState.Ready) {
                confirmedInfo = null
                clearSnapshot()
                throw BridgeDisconnected("尚未连接")
            }
            val realInfo = link.infoRaw
            val parsedInfo = BleProtocol.parseInfo(realInfo)
            val profile = parsedInfo.profile

            val confirmed = confirmedInfo
            if (confirmed == null ||
                confirmed.sessionId != link.sessionId ||
                confirmed.profile != profile
            ) {
                confirmedInfo = null
                clearSnapshot()
            }

            try {
                log("请求 GET_INFO")
                val infoRequest = Frame(
                    opcode = BleProtocol.GET_INFO,
                    requestId = id(),
                    payload = ByteArray(0),
                )
                val infoResponse = transport.request(infoRequest, READ_TIMEOUT_MS)
                BleProtocol.validateResponse(infoRequest, infoResponse, realInfo, profile)
                require(infoResponse.status == BleProtocol.OK) {
                    "GET_INFO 返回 ${BleProtocol.statusName(infoResponse.status)}"
                }
                require(infoResponse.payload.contentEquals(realInfo)) {
                    "GET_INFO 与 INFO 特征不一致"
                }
                confirmedInfo = ConfirmedInfo(link.sessionId, profile)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                confirmedInfo = null
                clearSnapshot()
                logError("INFO 会话确认失败，已禁止 MASTER/TIMBRE 写入：${error.message}", error)
                throw error
            }

            try {
                log("请求 GET_STATE")
                val state = readStateLocked(profile)
                val stateReadAt = System.currentTimeMillis()
                stateVersionCounter += 1
                val stateVersion = stateVersionCounter

                val previous = _snapshot.value
                var timbre = previous.timbre
                var timbreReadAt = previous.timbreReadAtMillis
                var timbreVersion = previous.timbreVersion
                if (profile.supportsTimbre) {
                    log("请求 GET_TIMBRE")
                    try {
                        val freshTimbre = readTimbreLocked(profile)
                        timbre = freshTimbre
                        timbreReadAt = System.currentTimeMillis()
                        timbreVersionCounter += 1
                        timbreVersion = timbreVersionCounter
                        log("GET_TIMBRE ${BleProtocol.timbreSummary(freshTimbre)}")
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Exception) {
                        // Keep the last known timbre and its timestamp after a failed read.
                        logError("GET_TIMBRE 失败，保留上次音色与读取时间：${error.message}", error)
                    }
                } else {
                    timbre = null
                    timbreReadAt = null
                }

                var adsr = previous.adsr
                var adsrReadAt = previous.adsrReadAtMillis
                var adsrVersions = previous.adsrVersions
                if (profile.supportsAdsr) {
                    for (field in AdsrField.entries) {
                        log("请求 GET_${field.label}")
                        try {
                            val freshAdsr = readAdsrLocked(profile, field)
                            adsr = adsr + (field to freshAdsr)
                            adsrReadAt = adsrReadAt + (field to System.currentTimeMillis())
                            val next = (adsrVersionCounters[field] ?: 0L) + 1
                            adsrVersionCounters[field] = next
                            adsrVersions = adsrVersions + (field to next)
                            log("GET_${field.label} ${BleProtocol.adsrSummary(freshAdsr)}")
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: Exception) {
                            // Independent fields: a failed read keeps its last value/time.
                            logError(
                                "GET_${field.label} 失败，保留上次值与读取时间：${error.message}",
                                error,
                            )
                        }
                    }
                } else {
                    adsr = emptyMap()
                    adsrReadAt = emptyMap()
                }

                val snapshot = BridgeSnapshot(
                    info = parsedInfo,
                    state = state,
                    stateReadAtMillis = stateReadAt,
                    stateVersion = stateVersion,
                    timbre = timbre,
                    timbreReadAtMillis = timbreReadAt,
                    timbreVersion = timbreVersion,
                    adsr = adsr,
                    adsrReadAtMillis = adsrReadAt,
                    adsrVersions = adsrVersions,
                )
                _snapshot.value = snapshot
                log("GET_STATE build=${state.buildHex} revision=${state.revision} master=${state.masterPercent}%")
                return snapshot
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                clearSnapshot()
                logError("刷新失败，已清除旧快照：${error.message}", error)
                throw error
            }
        } finally {
            operationMutex.unlock()
        }
    }

    private suspend fun readStateLocked(profile: BleProtocol.BridgeProfile): FpgaState {
        val request = BleProtocol.stateRequest(id())
        val response = transport.request(request, READ_TIMEOUT_MS)
        BleProtocol.validateResponse(request, response, profile.infoPayload, profile)
        if (response.status != BleProtocol.OK) {
            throw BridgeStatusError("GET_STATE", response.status)
        }
        return BleProtocol.parseState(response.payload, profile)
    }

    private suspend fun readTimbreLocked(profile: BleProtocol.BridgeProfile): TimbreState {
        require(profile.supportsTimbre) { "profile does not support timbre" }
        val request = BleProtocol.timbreGetRequest(id())
        val response = transport.request(request, READ_TIMEOUT_MS)
        BleProtocol.validateResponse(request, response, profile.infoPayload, profile)
        if (response.status != BleProtocol.OK) {
            throw BridgeStatusError("GET_TIMBRE", response.status)
        }
        return BleProtocol.parseTimbre(response.payload, profile)
    }

    private suspend fun readAdsrLocked(
        profile: BleProtocol.BridgeProfile,
        field: AdsrField,
    ): AdsrState {
        require(profile.supportsAdsr) { "profile does not support ADSR" }
        val request = BleProtocol.adsrGetRequest(field, id())
        val response = transport.request(request, READ_TIMEOUT_MS)
        BleProtocol.validateResponse(request, response, profile.infoPayload, profile)
        if (response.status != BleProtocol.OK) {
            throw BridgeStatusError("GET_${field.label}", response.status)
        }
        return BleProtocol.parseAdsr(field, response.payload, profile)
    }

    /**
     * One bounded MASTER CAS:
     *   fresh GET -> SET(expected build/revision, target) -> ACK -> fresh GET.
     */
    suspend fun setMaster(target: Int): SetMasterOutcome {
        require(target in 0..16) { "master index must be in 0..16" }
        val profile = try {
            protocolProfile()
        } catch (error: Exception) {
            return SetMasterOutcome.Failed(error.message ?: "尚未连接")
        }
        if (!operationMutex.tryLock()) {
            return SetMasterOutcome.Failed("另一个 MASTER/TIMBRE 操作正在进行，未发送")
        }
        try {
            return setMasterLocked(profile, target)
        } finally {
            operationMutex.unlock()
        }
    }

    private suspend fun setMasterLocked(
        profile: BleProtocol.BridgeProfile,
        target: Int,
    ): SetMasterOutcome {
        val before = try {
            readStateLocked(profile)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            logError("写入前读取状态失败：${error.message}", error)
            return SetMasterOutcome.Failed("写入前读取状态失败：${error.message}")
        }
        val stateReadAt = System.currentTimeMillis()
        publishState(before, stateReadAt)
        log("SET 前置 GET：build=${before.buildHex} revision=${before.revision} master=${before.masterPercent}%")
        if (!profile.acceptsFpgaBuild(before.build)) {
            return SetMasterOutcome.Failed("FPGA build ${before.buildHex} 不是 ${profile.buildId}，拒绝写入")
        }

        val request = try {
            BleProtocol.masterRequest(id(), before, target, profile)
        } catch (error: Exception) {
            return SetMasterOutcome.Failed("无法构造 SET：${error.message}")
        }
        log("发送 SET target=${BleProtocol.percentOf(target)}% expectedRevision=${before.revision}")
        val response = try {
            transport.request(request, SET_TIMEOUT_MS)
        } catch (cancelled: CancellationException) {
            log("SET OUTCOME_UNKNOWN：调用在 SET 尝试后取消，写入可能已提交；未自动重发，不宣称回滚")
            throw cancelled
        } catch (timeout: BridgeTimeout) {
            val observed = readStateQuietly(profile)
            return if (timeout.submitted) {
                log("SET 超时且写入可能已提交：结果未知，不自动重发")
                SetMasterOutcome.Unknown("SET 超时，写入可能已提交；未自动重发，请核对实际状态", observed)
            } else {
                SetMasterOutcome.Failed("SET 超时且写入未提交")
            }
        } catch (disconnected: BridgeDisconnected) {
            val observed = readStateQuietly(profile)
            log("SET 期间连接断开：结果未知")
            return SetMasterOutcome.Unknown("SET 期间连接断开，结果未知；未自动重发", observed)
        } catch (error: Exception) {
            val observed = readStateQuietly(profile)
            logError("SET 失败：${error.message}", error)
            return SetMasterOutcome.Unknown("SET 状态未知：${error.message}", observed)
        }

        try {
            BleProtocol.validateResponse(request, response, profile.infoPayload, profile)
        } catch (error: Exception) {
            val observed = readStateQuietly(profile)
            logError("SET 响应校验失败：${error.message}", error)
            return SetMasterOutcome.Unknown("SET 响应校验失败，结果未知：${error.message}", observed)
        }

        if (response.status != BleProtocol.OK) {
            val stateFromPayload = runCatching {
                BleProtocol.parseState(response.payload, profile)
            }.getOrNull()
            val observed = readStateQuietly(profile) ?: stateFromPayload
            if (response.status == BleProtocol.OUTCOME_UNKNOWN) {
                log("SET OUTCOME_UNKNOWN：板端无法确认写入结果；未自动重发")
                return SetMasterOutcome.Unknown("板端报告 OUTCOME_UNKNOWN，写入可能已提交；未自动重发", observed)
            }
            log("SET 被拒绝：${BleProtocol.statusName(response.status)}")
            return SetMasterOutcome.Rejected(response.status, observed)
        }

        val ack = BleProtocol.parseState(response.payload, profile)
        val expectedRevision = (before.revision + (if (before.master == target) 0 else 1)) and 0xFFFF
        if (ack.revision != expectedRevision) {
            val observed = readStateQuietly(profile)
            log("SET OUTCOME_UNKNOWN：ACK revision=${ack.revision}，预期 $expectedRevision；未自动重发")
            return SetMasterOutcome.Unknown(
                "SET ACK revision 与前态及目标不符，结果未知；未自动重发",
                observed,
            )
        }
        val fresh = try {
            readStateLocked(profile)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            log("SET 后新鲜读回失败：${error.message}")
            return SetMasterOutcome.Inconsistent(ack, null)
        }
        val freshAt = System.currentTimeMillis()
        publishState(fresh, freshAt)
        if (fresh.master != target || fresh.revision != ack.revision) {
            log("SET ACK 与新鲜读回不一致：ack rev=${ack.revision} fresh rev=${fresh.revision}")
            return SetMasterOutcome.Inconsistent(ack, fresh)
        }
        log("SET 已发布并新鲜读回一致：revision=${fresh.revision} master=${fresh.masterPercent}%")
        return SetMasterOutcome.Applied(ack, fresh)
    }

    /**
     * One bounded TIMBRE CAS. The profile must advertise the timbre capability.
     */
    suspend fun setTimbre(target: Int): SetTimbreOutcome {
        require(target in 0..3) { "timbre must be in 0..3" }
        val profile = try {
            protocolProfile()
        } catch (error: Exception) {
            return SetTimbreOutcome.Failed(error.message ?: "尚未连接")
        }
        if (!profile.supportsTimbre || profile.capabilities and BleProtocol.CAP_TIMBRE_SET == 0) {
            return SetTimbreOutcome.Failed("当前固件不支持音色写入")
        }
        if (!operationMutex.tryLock()) {
            return SetTimbreOutcome.Failed("另一个 MASTER/TIMBRE 操作正在进行，未发送")
        }
        try {
            return setTimbreLocked(profile, target)
        } finally {
            operationMutex.unlock()
        }
    }

    private suspend fun setTimbreLocked(
        profile: BleProtocol.BridgeProfile,
        target: Int,
    ): SetTimbreOutcome {
        val before = try {
            readTimbreLocked(profile)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            logError("音色写入前读取失败：${error.message}", error)
            return SetTimbreOutcome.Failed("音色写入前读取失败：${error.message}")
        }
        val readAt = System.currentTimeMillis()
        publishTimbre(before, readAt)
        log("SET_TIMBRE 前置 GET：build=${before.buildHex} revision=${before.revision} timbre=${before.label}")
        if (!profile.acceptsFpgaBuild(before.build)) {
            return SetTimbreOutcome.Failed("FPGA build ${before.buildHex} 不是 ${profile.buildId}，拒绝写入")
        }

        val request = try {
            BleProtocol.timbreRequest(id(), before, target, profile)
        } catch (error: Exception) {
            return SetTimbreOutcome.Failed("无法构造 SET_TIMBRE：${error.message}")
        }
        log("发送 SET_TIMBRE target=${Timbre.from(target).label} expectedRevision=${before.revision}")
        val response = try {
            transport.request(request, SET_TIMEOUT_MS)
        } catch (cancelled: CancellationException) {
            log("SET_TIMBRE OUTCOME_UNKNOWN：调用在 SET 尝试后取消，写入可能已提交；未自动重发")
            throw cancelled
        } catch (timeout: BridgeTimeout) {
            val observed = readTimbreQuietly(profile)
            return if (timeout.submitted) {
                log("SET_TIMBRE 超时且写入可能已提交：结果未知，不自动重发")
                SetTimbreOutcome.Unknown("SET_TIMBRE 超时，写入可能已提交；未自动重发", observed)
            } else {
                SetTimbreOutcome.Failed("SET_TIMBRE 超时且写入未提交")
            }
        } catch (disconnected: BridgeDisconnected) {
            val observed = readTimbreQuietly(profile)
            log("SET_TIMBRE 期间连接断开：结果未知")
            return SetTimbreOutcome.Unknown("SET_TIMBRE 期间连接断开，结果未知；未自动重发", observed)
        } catch (error: Exception) {
            val observed = readTimbreQuietly(profile)
            logError("SET_TIMBRE 失败：${error.message}", error)
            return SetTimbreOutcome.Unknown("SET_TIMBRE 状态未知：${error.message}", observed)
        }

        try {
            BleProtocol.validateResponse(request, response, profile.infoPayload, profile)
        } catch (error: Exception) {
            val observed = readTimbreQuietly(profile)
            logError("SET_TIMBRE 响应校验失败：${error.message}", error)
            return SetTimbreOutcome.Unknown("SET_TIMBRE 响应校验失败，结果未知：${error.message}", observed)
        }

        if (response.status != BleProtocol.OK) {
            val stateFromPayload = runCatching {
                BleProtocol.parseTimbre(response.payload, profile)
            }.getOrNull()
            val observed = readTimbreQuietly(profile) ?: stateFromPayload
            if (response.status == BleProtocol.OUTCOME_UNKNOWN) {
                log("SET_TIMBRE OUTCOME_UNKNOWN：板端无法确认写入结果；未自动重发")
                return SetTimbreOutcome.Unknown(
                    "板端报告 OUTCOME_UNKNOWN，写入可能已提交；未自动重发",
                    observed,
                )
            }
            log("SET_TIMBRE 被拒绝：${BleProtocol.statusName(response.status)}")
            return SetTimbreOutcome.Rejected(response.status, observed)
        }

        val ack = BleProtocol.parseTimbre(response.payload, profile)
        val expectedRevision = (before.revision + (if (before.timbre == target) 0 else 1)) and 0xFFFF
        if (ack.revision != expectedRevision) {
            val observed = readTimbreQuietly(profile)
            log("SET_TIMBRE OUTCOME_UNKNOWN：ACK revision=${ack.revision}，预期 $expectedRevision；未自动重发")
            return SetTimbreOutcome.Unknown(
                "SET_TIMBRE ACK revision 与前态及目标不符，结果未知；未自动重发",
                observed,
            )
        }
        val fresh = try {
            readTimbreLocked(profile)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            log("SET_TIMBRE 后新鲜读回失败：${error.message}")
            return SetTimbreOutcome.Inconsistent(ack, null)
        }
        val freshAt = System.currentTimeMillis()
        publishTimbre(fresh, freshAt)
        if (fresh.timbre != target || fresh.revision != ack.revision) {
            log("SET_TIMBRE ACK 与新鲜读回不一致：ack rev=${ack.revision} fresh rev=${fresh.revision}")
            return SetTimbreOutcome.Inconsistent(ack, fresh)
        }
        log("SET_TIMBRE 已发布并新鲜读回一致：revision=${fresh.revision} timbre=${fresh.label}")
        return SetTimbreOutcome.Applied(ack, fresh)
    }

    /**
     * One bounded ADSR-field CAS. Each of the four fields is an independent
     * snapshot; a write changes exactly one panel index.
     */
    suspend fun setAdsr(field: AdsrField, target: Int): SetAdsrOutcome {
        require(target in 0..field.maxIndex) { "${field.label} index out of range" }
        val profile = try {
            protocolProfile()
        } catch (error: Exception) {
            return SetAdsrOutcome.Failed(error.message ?: "尚未连接")
        }
        if (!profile.supportsAdsr || profile.capabilities and BleProtocol.CAP_ADSR_SET == 0) {
            return SetAdsrOutcome.Failed("当前固件不支持 ADSR 写入")
        }
        if (!operationMutex.tryLock()) {
            return SetAdsrOutcome.Failed("另一个参数操作正在进行，未发送")
        }
        try {
            return setAdsrLocked(profile, field, target)
        } finally {
            operationMutex.unlock()
        }
    }

    private suspend fun setAdsrLocked(
        profile: BleProtocol.BridgeProfile,
        field: AdsrField,
        target: Int,
    ): SetAdsrOutcome {
        val before = try {
            readAdsrLocked(profile, field)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            logError("${field.label} 写入前读取失败：${error.message}", error)
            return SetAdsrOutcome.Failed("${field.label} 写入前读取失败：${error.message}")
        }
        val readAt = System.currentTimeMillis()
        publishAdsr(before, readAt)
        log(
            "SET_${field.label} 前置 GET：build=${before.buildHex} " +
                "revision=${before.revision} index=${before.index}",
        )
        if (!profile.acceptsFpgaBuild(before.build)) {
            return SetAdsrOutcome.Failed(
                "FPGA build ${before.buildHex} 不是 ${profile.buildId}，拒绝写入",
            )
        }

        val request = try {
            BleProtocol.adsrRequest(id(), before, target, profile)
        } catch (error: Exception) {
            return SetAdsrOutcome.Failed("无法构造 SET_${field.label}：${error.message}")
        }
        log("发送 SET_${field.label} target=$target expectedRevision=${before.revision}")
        val response = try {
            transport.request(request, SET_TIMEOUT_MS)
        } catch (cancelled: CancellationException) {
            log(
                "SET_${field.label} OUTCOME_UNKNOWN：调用在 SET 尝试后取消，写入可能已提交；" +
                    "未自动重发，不宣称回滚",
            )
            throw cancelled
        } catch (timeout: BridgeTimeout) {
            val observed = readAdsrQuietly(profile, field)
            return if (timeout.submitted) {
                log("SET_${field.label} 超时且写入可能已提交：结果未知，不自动重发")
                SetAdsrOutcome.Unknown(
                    "SET_${field.label} 超时，写入可能已提交；未自动重发，请核对实际状态",
                    observed,
                )
            } else {
                SetAdsrOutcome.Failed("SET_${field.label} 超时且写入未提交")
            }
        } catch (disconnected: BridgeDisconnected) {
            val observed = readAdsrQuietly(profile, field)
            log("SET_${field.label} 期间连接断开：结果未知")
            return SetAdsrOutcome.Unknown(
                "SET_${field.label} 期间连接断开，结果未知；未自动重发",
                observed,
            )
        } catch (error: Exception) {
            val observed = readAdsrQuietly(profile, field)
            logError("SET_${field.label} 失败：${error.message}", error)
            return SetAdsrOutcome.Unknown("SET_${field.label} 状态未知：${error.message}", observed)
        }

        try {
            BleProtocol.validateResponse(request, response, profile.infoPayload, profile)
        } catch (error: Exception) {
            val observed = readAdsrQuietly(profile, field)
            logError("SET_${field.label} 响应校验失败：${error.message}", error)
            return SetAdsrOutcome.Unknown(
                "SET_${field.label} 响应校验失败，结果未知：${error.message}",
                observed,
            )
        }

        if (response.status != BleProtocol.OK) {
            val stateFromPayload = runCatching {
                BleProtocol.parseAdsr(field, response.payload, profile)
            }.getOrNull()
            val observed = readAdsrQuietly(profile, field) ?: stateFromPayload
            if (response.status == BleProtocol.OUTCOME_UNKNOWN) {
                log("SET_${field.label} OUTCOME_UNKNOWN：板端无法确认写入结果；未自动重发")
                return SetAdsrOutcome.Unknown(
                    "板端报告 OUTCOME_UNKNOWN，写入可能已提交；未自动重发",
                    observed,
                )
            }
            log("SET_${field.label} 被拒绝：${BleProtocol.statusName(response.status)}")
            return SetAdsrOutcome.Rejected(response.status, observed)
        }

        val ack = BleProtocol.parseAdsr(field, response.payload, profile)
        val expectedRevision =
            (before.revision + (if (before.index == target) 0 else 1)) and 0xFFFF
        if (ack.revision != expectedRevision) {
            val observed = readAdsrQuietly(profile, field)
            log(
                "SET_${field.label} OUTCOME_UNKNOWN：ACK revision=${ack.revision}，" +
                    "预期 $expectedRevision；未自动重发",
            )
            return SetAdsrOutcome.Unknown(
                "SET_${field.label} ACK revision 与前态及目标不符，结果未知；未自动重发",
                observed,
            )
        }
        val fresh = try {
            readAdsrLocked(profile, field)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            log("SET_${field.label} 后新鲜读回失败：${error.message}")
            return SetAdsrOutcome.Inconsistent(ack, null)
        }
        val freshAt = System.currentTimeMillis()
        publishAdsr(fresh, freshAt)
        if (fresh.index != target || fresh.revision != ack.revision) {
            log(
                "SET_${field.label} ACK 与新鲜读回不一致：" +
                    "ack rev=${ack.revision} fresh rev=${fresh.revision}",
            )
            return SetAdsrOutcome.Inconsistent(ack, fresh)
        }
        log(
            "SET_${field.label} 已发布并新鲜读回一致：" +
                "revision=${fresh.revision} index=${fresh.index}",
        )
        return SetAdsrOutcome.Applied(ack, fresh)
    }

    private suspend fun readStateQuietly(profile: BleProtocol.BridgeProfile): FpgaState? {
        return try {
            if (transport.link.value !is LinkState.Ready) return null
            readStateLocked(profile).also {
                publishState(it, System.currentTimeMillis())
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    private suspend fun readTimbreQuietly(profile: BleProtocol.BridgeProfile): TimbreState? {
        return try {
            if (!profile.supportsTimbre || transport.link.value !is LinkState.Ready) return null
            readTimbreLocked(profile).also {
                publishTimbre(it, System.currentTimeMillis())
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    private suspend fun readAdsrQuietly(
        profile: BleProtocol.BridgeProfile,
        field: AdsrField,
    ): AdsrState? {
        return try {
            if (!profile.supportsAdsr || transport.link.value !is LinkState.Ready) return null
            readAdsrLocked(profile, field).also {
                publishAdsr(it, System.currentTimeMillis())
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        const val READ_TIMEOUT_MS = 2_500L
        const val SET_TIMEOUT_MS = 3_500L
    }
}
