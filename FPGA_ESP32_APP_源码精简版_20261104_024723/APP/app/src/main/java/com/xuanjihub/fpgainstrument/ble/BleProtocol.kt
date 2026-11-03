package com.xuanjihub.fpgainstrument.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.UUID

/**
 * A GET accepted the bridge payload, but the FPGA build is outside the profile's
 * exact allowlist. The bridge replied; the App only talks to an allowlisted bitstream.
 */
class UnsupportedFpgaBuild(
    val build: Long,
    val acceptedBuilds: Set<Long>,
) : IllegalArgumentException(
    "FPGA build ${"%08X".format(build)} 不在当前 profile 的精确支持列表 " +
        acceptedBuilds.joinToString { "%08X".format(it) },
)

/** INFO was received, but the bridge identity is unknown to this App. */
class UnsupportedBridgeInfo(raw: ByteArray) : IllegalArgumentException(
    "已读到 ESP32，但固件身份与此 App 不兼容。请安装配套版本 App。" +
        "收到 INFO：${raw.toHex()}；未发送参数修改。",
)

/**
 * BLE/UART bridge codec for the exact stage-1 profiles.
 *
 * The legacy profile (`50314B01`) exposes MASTER only. The timbre profile
 * (`50314B02`) additionally exposes GET_TIMBRE / SET_TIMBRE. The ADSR profile
 * (firmware `0.4.0`, INFO id `4E303704`) exposes MASTER, timbre and ADSR and
 * accepts exactly `50314B03`, Miseki D03 `50314D03`, and `50314D05`. The profile
 * is selected by an exact INFO payload; an unknown or partially matching
 * identity is rejected.
 *
 * Pure Kotlin: all wire rules live in this file.
 */
object BleProtocol {
    val SERVICE_UUID: UUID = UUID.fromString("4a1dee0d-24f4-4f1a-8db6-d329a5a0d69d")
    val INFO_UUID: UUID = UUID.fromString("4a1dee0d-24f4-4f1a-8db6-d329a5a0d69e")
    val COMMAND_UUID: UUID = UUID.fromString("4a1dee0d-24f4-4f1a-8db6-d329a5a0d69f")
    val RESULT_UUID: UUID = UUID.fromString("4a1dee0d-24f4-4f1a-8db6-d329a5a0d6a0")
    val CLIENT_CHARACTERISTIC_CONFIG: UUID =
        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val DEVICE_NAME = "FPGA-BLE-N07"
    const val MAGIC = 0xB1
    const val VERSION = 1
    const val FRAME_SIZE = 20
    const val MAX_PAYLOAD = 11

    // Requests
    const val PING = 0x01
    const val GET_INFO = 0x02
    const val GET_STATE = 0x10
    const val SET_MASTER = 0x11
    const val GET_TIMBRE = 0x12
    const val SET_TIMBRE = 0x13
    const val GET_ATTACK = 0x14
    const val SET_ATTACK = 0x15
    const val GET_DECAY = 0x16
    const val SET_DECAY = 0x17
    const val GET_SUSTAIN = 0x18
    const val SET_SUSTAIN = 0x19
    const val GET_RELEASE = 0x1A
    const val SET_RELEASE = 0x1B

    // Responses
    const val PING_RESPONSE = 0x81
    const val INFO_RESPONSE = 0x82
    const val STATE_RESULT = 0x90
    const val MASTER_RESULT = 0x91
    const val TIMBRE_RESULT = 0x92
    const val SET_TIMBRE_RESULT = 0x93
    const val ATTACK_RESULT = 0x94
    const val SET_ATTACK_RESULT = 0x95
    const val DECAY_RESULT = 0x96
    const val SET_DECAY_RESULT = 0x97
    const val SUSTAIN_RESULT = 0x98
    const val SET_SUSTAIN_RESULT = 0x99
    const val RELEASE_RESULT = 0x9A
    const val SET_RELEASE_RESULT = 0x9B
    const val ERROR_RESPONSE = 0xFF

    // Business status
    const val OK = 0x00
    const val UNSUPPORTED_OPCODE = 0x01
    const val BAD_VERSION = 0x02
    const val BAD_PAYLOAD = 0x03
    const val REQUEST_ID_CONFLICT = 0x04
    const val FPGA_UNAVAILABLE = 0x10
    const val BUSY = 0x11
    const val REVISION_CONFLICT = 0x12
    const val CANCELLED = 0x13
    const val CONFIG_FAULT = 0x14
    const val OUTCOME_UNKNOWN = 0x15

    // Capability bits carried by INFO.
    const val CAP_TIMBRE_GET = 0x10
    const val CAP_TIMBRE_SET = 0x20
    const val CAP_ADSR_GET = 0x40
    const val CAP_ADSR_SET = 0x80

    /**
     * Exact protocol profiles. `infoPayload` is compared byte-for-byte; the
     * build and capability bits are part of that identity.
     */
    sealed class BridgeProfile(
        val id: String,
        private val rawInfo: ByteArray,
        val fpgaBuild: Long,
        val acceptedFpgaBuilds: Set<Long> = setOf(fpgaBuild),
        val supportsTimbre: Boolean,
        val supportsAdsr: Boolean,
        val firmware: String,
        val buildId: String,
        val capabilities: Int,
    ) {
        val infoPayload: ByteArray get() = rawInfo.copyOf()

        fun acceptsFpgaBuild(build: Long): Boolean = build in acceptedFpgaBuilds

        object Legacy : BridgeProfile(
            id = "legacy",
            rawInfo = byteArrayOf(
                0x01, 0x00, 0x02, 0x00, 0x02, 0x37, 0x30, 0x4E, 0x14, 0x0B, 0x0F,
            ),
            fpgaBuild = 0x50314B01L,
            supportsTimbre = false,
            supportsAdsr = false,
            firmware = "0.2.0",
            buildId = "4E303702",
            capabilities = 0x0F,
        )

        object Timbre : BridgeProfile(
            id = "timbre",
            rawInfo = byteArrayOf(
                0x01, 0x00, 0x03, 0x00, 0x03, 0x37, 0x30, 0x4E, 0x14, 0x0B, 0x3F,
            ),
            fpgaBuild = 0x50314B02L,
            supportsTimbre = true,
            supportsAdsr = false,
            firmware = "0.3.0",
            buildId = "4E303703",
            capabilities = 0x3F,
        )

        object Adsr : BridgeProfile(
            id = "adsr",
            rawInfo = byteArrayOf(
                0x01, 0x00, 0x04, 0x00, 0x04, 0x37, 0x30, 0x4E, 0x14, 0x0B, 0xFF.toByte(),
            ),
            fpgaBuild = 0x50314B03L,
            acceptedFpgaBuilds = setOf(0x50314B03L, 0x50314D03L, 0x50314D05L),
            supportsTimbre = true,
            supportsAdsr = true,
            firmware = "0.4.0",
            buildId = "4E303704",
            capabilities = 0xFF,
        )

        /** Same parameter commands as ADSR, plus independent USB MIDI on the ESP32. */
        object AdsrMidi : BridgeProfile(
            id = "adsr-midi",
            rawInfo = byteArrayOf(
                0x01, 0x00, 0x05, 0x00, 0x01, 0x31, 0x31, 0x4E, 0x14, 0x0B, 0xFF.toByte(),
            ),
            fpgaBuild = 0x50314D06L,
            acceptedFpgaBuilds = setOf(0x50314B03L, 0x50314D03L, 0x50314D05L, 0x50314D06L),
            supportsTimbre = true,
            supportsAdsr = true,
            firmware = "0.5.0",
            buildId = "4E313101",
            capabilities = 0xFF,
        )

        companion object {
            fun match(raw: ByteArray): BridgeProfile = when {
                raw.contentEquals(Legacy.infoPayload) -> Legacy
                raw.contentEquals(Timbre.infoPayload) -> Timbre
                raw.contentEquals(Adsr.infoPayload) -> Adsr
                raw.contentEquals(AdsrMidi.infoPayload) -> AdsrMidi
                else -> throw UnsupportedBridgeInfo(raw)
            }
        }
    }

    /** Legacy INFO bytes. */
    val INFO_PAYLOAD: ByteArray get() = BridgeProfile.Legacy.infoPayload
    val TIMBRE_INFO_PAYLOAD: ByteArray get() = BridgeProfile.Timbre.infoPayload
    val ADSR_INFO_PAYLOAD: ByteArray get() = BridgeProfile.Adsr.infoPayload

    const val FPGA_BUILD = 0x50314B01
    const val TIMBRE_FPGA_BUILD = 0x50314B02
    const val ADSR_FPGA_BUILD = 0x50314B03
    const val ADSR_MISEKI_FPGA_BUILD = 0x50314D03
    const val INSTRUMENT_TEST_FPGA_BUILD = 0x50314D05

    val BRIDGE_FAILURES: Set<Int> = setOf(
        FPGA_UNAVAILABLE, BUSY, REVISION_CONFLICT, CANCELLED, CONFIG_FAULT, OUTCOME_UNKNOWN,
    )

    fun statusName(status: Int): String = when (status) {
        OK -> "OK"
        UNSUPPORTED_OPCODE -> "UNSUPPORTED_OPCODE"
        BAD_VERSION -> "BAD_VERSION"
        BAD_PAYLOAD -> "BAD_PAYLOAD"
        REQUEST_ID_CONFLICT -> "REQUEST_ID_CONFLICT"
        FPGA_UNAVAILABLE -> "FPGA_UNAVAILABLE"
        BUSY -> "BUSY"
        REVISION_CONFLICT -> "REVISION_CONFLICT"
        CANCELLED -> "CANCELLED"
        CONFIG_FAULT -> "CONFIG_FAULT"
        OUTCOME_UNKNOWN -> "OUTCOME_UNKNOWN"
        else -> "UNKNOWN_STATUS_0x%02X".format(status)
    }

    /** CRC16-CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR. */
    fun crc16(data: ByteArray): Int {
        var crc = 0xFFFF
        for (byte in data) {
            crc = crc xor ((byte.toInt() and 0xFF) shl 8)
            repeat(8) {
                crc = if ((crc and 0x8000) != 0) {
                    ((crc shl 1) xor 0x1021) and 0xFFFF
                } else {
                    (crc shl 1) and 0xFFFF
                }
            }
        }
        return crc
    }

    /**
     * Board-facing percentage: the panel renders index 7/16 as 44%.
     * The protocol value stays the index; the rounded display is for the UI only.
     */
    fun percentOf(masterIndex: Int): Int {
        require(masterIndex in 0..16) { "master index must be 0..16" }
        return (masterIndex * 100 + 8) / 16
    }

    /** Exact fraction for diagnostics, e.g. index 7 -> 43.75. */
    fun exactPercentOf(masterIndex: Int): Double {
        require(masterIndex in 0..16) { "master index must be 0..16" }
        return masterIndex * 100.0 / 16.0
    }

    fun exactPercentText(masterIndex: Int): String =
        String.format(Locale.US, "%.2f", exactPercentOf(masterIndex))

    /** One-line display used by the UI; keeps rounded and exact values together. */
    fun stateSummary(state: FpgaState): String =
        "${state.masterPercent}%（index ${state.master}，精确 ${exactPercentText(state.master)}%），" +
            "revision ${state.revision}，${state.buildHex}"

    fun timbreSummary(timbre: TimbreState): String =
        "${Timbre.from(timbre.timbre).label}（${timbre.timbre}），revision ${timbre.revision}，" +
            timbre.buildHex

    /** Panel step -> existing envelope code. */
    val ADSR_STEP_VALUES: IntArray = intArrayOf(0, 8192, 2048, 512, 128, 32, 8, 2)

    fun envelopeCode(field: AdsrField, index: Int): Int {
        require(index in 0..field.maxIndex) { "${field.label} index out of range" }
        return when (field) {
            AdsrField.SUSTAIN -> if (index == 16) 65535 else index * 4096
            else -> ADSR_STEP_VALUES[index]
        }
    }

    fun adsrSummary(state: AdsrState): String =
        "${state.field.label} 档位 ${state.index}/${state.field.maxIndex}" +
            "（包络码 ${state.envelopeCode}），revision ${state.revision}，${state.buildHex}"

    fun encodeRequest(opcode: Int, requestId: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        require(opcode in 0..0xFF) { "opcode must be 0..255" }
        require(requestId in 0..0xFFFF) { "request id must be 0..65535" }
        require(payload.size <= MAX_PAYLOAD) { "payload exceeds $MAX_PAYLOAD bytes" }
        val buffer = ByteBuffer.allocate(FRAME_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(MAGIC.toByte())
        buffer.put(VERSION.toByte())
        buffer.put(opcode.toByte())
        buffer.put(0.toByte()) // request status must be zero
        buffer.putShort(requestId.toShort())
        buffer.put(payload.size.toByte())
        buffer.put(payload)
        repeat(MAX_PAYLOAD - payload.size) { buffer.put(0) }
        val withoutCrc = buffer.array().copyOf(18)
        buffer.putShort(crc16(withoutCrc).toShort())
        return buffer.array()
    }

    fun decodeFrame(raw: ByteArray): Frame {
        require(raw.size == FRAME_SIZE) { "frame must be exactly $FRAME_SIZE bytes" }
        require((raw[0].toInt() and 0xFF) == MAGIC) { "bad frame magic" }
        val expectedCrc = (raw[18].toInt() and 0xFF) or ((raw[19].toInt() and 0xFF) shl 8)
        require(crc16(raw.copyOf(18)) == expectedCrc) { "bad frame CRC" }
        val version = raw[1].toInt() and 0xFF
        val opcode = raw[2].toInt() and 0xFF
        val status = raw[3].toInt() and 0xFF
        val requestId = (raw[4].toInt() and 0xFF) or ((raw[5].toInt() and 0xFF) shl 8)
        val length = raw[6].toInt() and 0xFF
        require(length <= MAX_PAYLOAD) { "payload length exceeds $MAX_PAYLOAD" }
        for (index in 7 + length until 18) {
            require(raw[index].toInt() == 0) { "nonzero frame padding" }
        }
        return Frame(
            opcode = opcode,
            requestId = requestId,
            status = status,
            payload = raw.copyOfRange(7, 7 + length),
            version = version,
        )
    }

    fun decodeRequest(raw: ByteArray): Frame {
        val frame = decodeFrame(raw)
        require(frame.status == 0) { "request status must be zero" }
        return frame
    }

    fun parseInfo(raw: ByteArray): BridgeInfo {
        require(raw.size == MAX_PAYLOAD) { "INFO must be exactly $MAX_PAYLOAD bytes" }
        val profile = BridgeProfile.match(raw)
        return BridgeInfo(
            stage = 1,
            firmware = profile.firmware,
            buildId = profile.buildId,
            frameSize = FRAME_SIZE,
            maxPayload = MAX_PAYLOAD,
            capabilities = profile.capabilities,
            profile = profile,
        )
    }

    fun parseState(raw: ByteArray, profile: BridgeProfile = BridgeProfile.Legacy): FpgaState {
        require(raw.size == 7) { "state payload must be exactly 7 bytes" }
        val buffer = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        val state = FpgaState(
            build = buffer.int.toLong() and 0xFFFFFFFFL,
            revision = buffer.short.toInt() and 0xFFFF,
            master = buffer.get().toInt() and 0xFF,
        )
        if (!profile.acceptsFpgaBuild(state.build)) {
            throw UnsupportedFpgaBuild(state.build, profile.acceptedFpgaBuilds)
        }
        require(state.master in 0..16) { "master index must be in 0..16" }
        return state
    }

    fun parseTimbre(raw: ByteArray, profile: BridgeProfile = BridgeProfile.Timbre): TimbreState {
        require(profile.supportsTimbre) { "profile does not support timbre" }
        require(raw.size == 7) { "timbre payload must be exactly 7 bytes" }
        val buffer = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        val state = TimbreState(
            build = buffer.int.toLong() and 0xFFFFFFFFL,
            revision = buffer.short.toInt() and 0xFFFF,
            timbre = buffer.get().toInt() and 0xFF,
        )
        if (!profile.acceptsFpgaBuild(state.build)) {
            throw UnsupportedFpgaBuild(state.build, profile.acceptedFpgaBuilds)
        }
        require(state.timbre in 0..3) { "timbre must be in 0..3" }
        return state
    }

    fun stateRequest(requestId: Int): Frame =
        Frame(opcode = GET_STATE, requestId = requestId, status = 0, payload = ByteArray(0))

    fun masterRequest(
        requestId: Int,
        state: FpgaState,
        target: Int,
        profile: BridgeProfile = BridgeProfile.Legacy,
    ): Frame {
        require(profile.acceptsFpgaBuild(state.build)) { "unsupported FPGA build" }
        require(target in 0..16) { "master index must be in 0..16" }
        val payload = ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(state.build.toInt())
            .putShort(state.revision.toShort())
            .put(target.toByte())
            .array()
        return Frame(opcode = SET_MASTER, requestId = requestId, status = 0, payload = payload)
    }

    fun timbreGetRequest(requestId: Int): Frame =
        Frame(opcode = GET_TIMBRE, requestId = requestId, status = 0, payload = ByteArray(0))

    fun timbreRequest(
        requestId: Int,
        state: TimbreState,
        target: Int,
        profile: BridgeProfile = BridgeProfile.Timbre,
    ): Frame {
        require(profile.supportsTimbre) { "profile does not support timbre" }
        require(profile.capabilities and CAP_TIMBRE_SET != 0) { "profile lacks SET_TIMBRE capability" }
        require(profile.acceptsFpgaBuild(state.build)) { "unsupported FPGA build for timbre" }
        require(target in 0..3) { "timbre must be in 0..3" }
        val payload = ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(state.build.toInt())
            .putShort(state.revision.toShort())
            .put(target.toByte())
            .array()
        return Frame(opcode = SET_TIMBRE, requestId = requestId, status = 0, payload = payload)
    }

    fun adsrGetRequest(field: AdsrField, requestId: Int): Frame =
        Frame(opcode = field.getOpcode, requestId = requestId, status = 0, payload = ByteArray(0))

    fun adsrRequest(
        requestId: Int,
        state: AdsrState,
        target: Int,
        profile: BridgeProfile = BridgeProfile.Adsr,
    ): Frame {
        require(profile.supportsAdsr) { "profile does not support ADSR" }
        require(profile.capabilities and CAP_ADSR_SET != 0) { "profile lacks ADSR SET capability" }
        if (!profile.acceptsFpgaBuild(state.build)) {
            throw UnsupportedFpgaBuild(state.build, profile.acceptedFpgaBuilds)
        }
        require(target in 0..state.field.maxIndex) {
            "${state.field.label} index must be in 0..${state.field.maxIndex}"
        }
        val payload = ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(state.build.toInt())
            .putShort(state.revision.toShort())
            .put(target.toByte())
            .array()
        return Frame(opcode = state.field.setOpcode, requestId = requestId, status = 0, payload = payload)
    }

    fun parseAdsr(
        field: AdsrField,
        raw: ByteArray,
        profile: BridgeProfile = BridgeProfile.Adsr,
    ): AdsrState {
        require(profile.supportsAdsr) { "profile does not support ADSR" }
        require(raw.size == 7) { "ADSR payload must be exactly 7 bytes" }
        val buffer = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        val state = AdsrState(
            field = field,
            build = buffer.int.toLong() and 0xFFFFFFFFL,
            revision = buffer.short.toInt() and 0xFFFF,
            index = buffer.get().toInt() and 0xFF,
        )
        if (!profile.acceptsFpgaBuild(state.build)) {
            throw UnsupportedFpgaBuild(state.build, profile.acceptedFpgaBuilds)
        }
        return state
    }

    /**
     * Checks every business field of the response frame and returns it.
     */
    fun validateResponse(
        request: Frame,
        response: Frame,
        realInfo: ByteArray = INFO_PAYLOAD,
        profile: BridgeProfile = BridgeProfile.Legacy,
    ) {
        val decodedRequest = decodeRequest(encodeFrame(request))
        val frame = decodeFrame(encodeFrame(response))
        require(frame.version == VERSION) { "response uses an unsupported version" }
        require(frame.requestId == decodedRequest.requestId) { "response request ID mismatch" }

        if (frame.opcode == ERROR_RESPONSE &&
            frame.status == REQUEST_ID_CONFLICT &&
            frame.payload.isEmpty()
        ) {
            return
        }
        if (decodedRequest.version != VERSION) {
            expect(frame, ERROR_RESPONSE, BAD_VERSION, ByteArray(0))
            return
        }
        when (decodedRequest.opcode) {
            PING -> expect(frame, PING_RESPONSE, OK, decodedRequest.payload)

            GET_INFO -> {
                if (decodedRequest.payload.isNotEmpty()) {
                    expect(frame, ERROR_RESPONSE, BAD_PAYLOAD, ByteArray(0))
                    return
                }
                val actual = parseInfo(frame.payload)
                require(actual.profile == profile) { "GET_INFO profile differs from negotiated profile" }
                require(frame.payload.contentEquals(realInfo)) {
                    "GET_INFO differs from real characteristic INFO read"
                }
                expect(frame, INFO_RESPONSE, OK, profile.infoPayload)
            }

            GET_STATE, SET_MASTER -> {
                val validPayload = if (decodedRequest.opcode == GET_STATE) {
                    decodedRequest.payload.isEmpty()
                } else {
                    decodedRequest.payload.size == 7 &&
                        (decodedRequest.payload[6].toInt() and 0xFF) <= 16
                }
                if (!validPayload) {
                    expect(frame, ERROR_RESPONSE, BAD_PAYLOAD, ByteArray(0))
                    return
                }
                if (decodedRequest.opcode == SET_MASTER) {
                    val expectedBuild = ByteBuffer.wrap(decodedRequest.payload.copyOfRange(0, 4))
                        .order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                    if (!profile.acceptsFpgaBuild(expectedBuild)) {
                        expect(frame, ERROR_RESPONSE, REVISION_CONFLICT, ByteArray(0))
                        return
                    }
                }
                val expectedOpcode =
                    if (decodedRequest.opcode == GET_STATE) STATE_RESULT else MASTER_RESULT
                require(frame.opcode == expectedOpcode) {
                    "unexpected state/master result opcode"
                }
                when {
                    frame.status == OK -> {
                        val state = parseState(frame.payload, profile)
                        if (decodedRequest.opcode == SET_MASTER) {
                            val buffer = ByteBuffer.wrap(decodedRequest.payload)
                                .order(ByteOrder.LITTLE_ENDIAN)
                            val expectedBuild = buffer.int.toLong() and 0xFFFFFFFFL
                            require(state.build == expectedBuild) {
                                "SET success does not match requested FPGA build"
                            }
                            val expectedRevision = buffer.short.toInt() and 0xFFFF
                            val target = buffer.get().toInt() and 0xFF
                            require(state.master == target) {
                                "SET success does not match requested master"
                            }
                            require(
                                state.revision == expectedRevision ||
                                    state.revision == (expectedRevision + 1) and 0xFFFF,
                            ) { "SET success does not match requested revision" }
                        }
                    }

                    frame.status in BRIDGE_FAILURES -> {
                        if (frame.payload.isNotEmpty()) parseState(frame.payload, profile)
                    }

                    else -> error("unexpected state/master business status")
                }
            }

            GET_TIMBRE, SET_TIMBRE -> {
                require(profile.supportsTimbre) { "profile does not support timbre" }
                require(profile.capabilities and CAP_TIMBRE_GET != 0) {
                    "profile lacks GET_TIMBRE capability"
                }
                if (decodedRequest.opcode == SET_TIMBRE) {
                    require(profile.capabilities and CAP_TIMBRE_SET != 0) {
                        "profile lacks SET_TIMBRE capability"
                    }
                }
                val validPayload = if (decodedRequest.opcode == GET_TIMBRE) {
                    decodedRequest.payload.isEmpty()
                } else {
                    decodedRequest.payload.size == 7 &&
                        (decodedRequest.payload[6].toInt() and 0xFF) <= 3
                }
                if (!validPayload) {
                    expect(frame, ERROR_RESPONSE, BAD_PAYLOAD, ByteArray(0))
                    return
                }
                if (decodedRequest.opcode == SET_TIMBRE) {
                    val expectedBuild = ByteBuffer.wrap(decodedRequest.payload.copyOfRange(0, 4))
                        .order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                    if (!profile.acceptsFpgaBuild(expectedBuild)) {
                        expect(frame, ERROR_RESPONSE, REVISION_CONFLICT, ByteArray(0))
                        return
                    }
                }
                val expectedOpcode =
                    if (decodedRequest.opcode == GET_TIMBRE) TIMBRE_RESULT else SET_TIMBRE_RESULT
                require(frame.opcode == expectedOpcode) {
                    "unexpected timbre result opcode"
                }
                when {
                    frame.status == OK -> {
                        val state = parseTimbre(frame.payload, profile)
                        if (decodedRequest.opcode == SET_TIMBRE) {
                            val buffer = ByteBuffer.wrap(decodedRequest.payload)
                                .order(ByteOrder.LITTLE_ENDIAN)
                            val expectedBuild = buffer.int.toLong() and 0xFFFFFFFFL
                            require(state.build == expectedBuild) {
                                "SET success does not match requested FPGA build"
                            }
                            val expectedRevision = buffer.short.toInt() and 0xFFFF
                            val target = buffer.get().toInt() and 0xFF
                            require(state.timbre == target) {
                                "SET success does not match requested timbre"
                            }
                            require(
                                state.revision == expectedRevision ||
                                    state.revision == (expectedRevision + 1) and 0xFFFF,
                            ) { "SET success does not match requested revision" }
                        }
                    }

                    frame.status in BRIDGE_FAILURES -> {
                        if (frame.payload.isNotEmpty()) parseTimbre(frame.payload, profile)
                    }

                    else -> error("unexpected timbre business status")
                }
            }

            in AdsrField.opcodes -> {
                val field = AdsrField.fromOpcode(decodedRequest.opcode)
                    ?: error("unmapped ADSR opcode")
                require(profile.supportsAdsr) { "profile does not support ADSR" }
                require(profile.capabilities and CAP_ADSR_GET != 0) {
                    "profile lacks ADSR GET capability"
                }
                val writing = decodedRequest.opcode == field.setOpcode
                if (writing) {
                    require(profile.capabilities and CAP_ADSR_SET != 0) {
                        "profile lacks ADSR SET capability"
                    }
                }
                val validPayload = if (!writing) {
                    decodedRequest.payload.isEmpty()
                } else {
                    decodedRequest.payload.size == 7 &&
                        (decodedRequest.payload[6].toInt() and 0xFF) <= field.maxIndex
                }
                if (!validPayload) {
                    expect(frame, ERROR_RESPONSE, BAD_PAYLOAD, ByteArray(0))
                    return
                }
                if (writing) {
                    val expectedBuild = ByteBuffer.wrap(decodedRequest.payload.copyOfRange(0, 4))
                        .order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                    if (!profile.acceptsFpgaBuild(expectedBuild)) {
                        expect(frame, ERROR_RESPONSE, REVISION_CONFLICT, ByteArray(0))
                        return
                    }
                }
                val expectedOpcode =
                    if (writing) field.setResultOpcode else field.getResultOpcode
                require(frame.opcode == expectedOpcode) {
                    "unexpected ${field.label} result opcode"
                }
                when {
                    frame.status == OK -> {
                        val state = parseAdsr(field, frame.payload, profile)
                        if (writing) {
                            val buffer = ByteBuffer.wrap(decodedRequest.payload)
                                .order(ByteOrder.LITTLE_ENDIAN)
                            val expectedBuild = buffer.int.toLong() and 0xFFFFFFFFL
                            require(state.build == expectedBuild) {
                                "SET success does not match requested FPGA build"
                            }
                            val expectedRevision = buffer.short.toInt() and 0xFFFF
                            val target = buffer.get().toInt() and 0xFF
                            require(state.index == target) {
                                "SET success does not match requested ${field.label}"
                            }
                            require(
                                state.revision == expectedRevision ||
                                    state.revision == (expectedRevision + 1) and 0xFFFF,
                            ) { "SET success does not match requested revision" }
                        }
                    }

                    frame.status in BRIDGE_FAILURES -> {
                        if (frame.payload.isNotEmpty()) parseAdsr(field, frame.payload, profile)
                    }

                    else -> error("unexpected ADSR business status")
                }
            }

            else -> expect(frame, ERROR_RESPONSE, UNSUPPORTED_OPCODE, ByteArray(0))
        }
    }

    fun encodeFrame(frame: Frame): ByteArray {
        require(frame.version in 0..0xFF)
        require(frame.requestId in 0..0xFFFF)
        require(frame.payload.size <= MAX_PAYLOAD)
        val buffer = ByteBuffer.allocate(FRAME_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(MAGIC.toByte())
        buffer.put(frame.version.toByte())
        buffer.put(frame.opcode.toByte())
        buffer.put(frame.status.toByte())
        buffer.putShort(frame.requestId.toShort())
        buffer.put(frame.payload.size.toByte())
        buffer.put(frame.payload)
        repeat(MAX_PAYLOAD - frame.payload.size) { buffer.put(0) }
        buffer.putShort(crc16(buffer.array().copyOf(18)).toShort())
        return buffer.array()
    }

    private fun expect(frame: Frame, opcode: Int, status: Int, payload: ByteArray) {
        require(frame.opcode == opcode && frame.status == status &&
            frame.payload.contentEquals(payload)) {
            "unexpected business opcode/status/payload"
        }
    }
}

enum class Timbre(val value: Int, val label: String) {
    SINE(0, "SINE"),
    PULSE(1, "PULSE"),
    ORGAN(2, "ORGAN"),
    REED(3, "REED");

    companion object {
        fun from(value: Int): Timbre = entries.firstOrNull { it.value == value }
            ?: throw IllegalArgumentException("timbre must be in 0..3")
    }
}

/**
 * The four ADSR fields are independent panel indices. The wire value is the
 * panel step.
 */
enum class AdsrField(
    val label: String,
    val getOpcode: Int,
    val setOpcode: Int,
    val getResultOpcode: Int,
    val setResultOpcode: Int,
    val maxIndex: Int,
    val defaultIndex: Int,
) {
    ATTACK("ATTACK", BleProtocol.GET_ATTACK, BleProtocol.SET_ATTACK, BleProtocol.ATTACK_RESULT, BleProtocol.SET_ATTACK_RESULT, 7, 2),
    DECAY("DECAY", BleProtocol.GET_DECAY, BleProtocol.SET_DECAY, BleProtocol.DECAY_RESULT, BleProtocol.SET_DECAY_RESULT, 7, 5),
    SUSTAIN("SUSTAIN", BleProtocol.GET_SUSTAIN, BleProtocol.SET_SUSTAIN, BleProtocol.SUSTAIN_RESULT, BleProtocol.SET_SUSTAIN_RESULT, 16, 12),
    RELEASE("RELEASE", BleProtocol.GET_RELEASE, BleProtocol.SET_RELEASE, BleProtocol.RELEASE_RESULT, BleProtocol.SET_RELEASE_RESULT, 7, 6);

    companion object {
        val opcodes: Set<Int> = entries.flatMap { listOf(it.getOpcode, it.setOpcode) }.toSet()

        fun fromOpcode(opcode: Int): AdsrField? =
            entries.firstOrNull { it.getOpcode == opcode || it.setOpcode == opcode }

        fun defaults(): Map<AdsrField, Int> = entries.associateWith { it.defaultIndex }
    }
}

data class AdsrState(
    val build: Long,
    val revision: Int,
    val index: Int,
    val field: AdsrField,
) {
    init {
        require(build in 0..0xFFFFFFFFL) { "invalid FPGA build" }
        require(revision in 0..0xFFFF) { "invalid FPGA revision" }
        require(index in 0..field.maxIndex) { "${field.label} index must be in 0..${field.maxIndex}" }
    }

    val buildHex: String get() = "%08X".format(build)
    val envelopeCode: Int = BleProtocol.envelopeCode(field, index)

    fun encode(): ByteArray = ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN)
        .putInt(build.toInt())
        .putShort(revision.toShort())
        .put(index.toByte())
        .array()
}

data class Frame(
    val opcode: Int,
    val requestId: Int,
    val status: Int = 0,
    val payload: ByteArray = ByteArray(0),
    val version: Int = BleProtocol.VERSION,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Frame) return false
        return opcode == other.opcode && requestId == other.requestId &&
            status == other.status && payload.contentEquals(other.payload) &&
            version == other.version
    }

    override fun hashCode(): Int {
        var result = opcode
        result = 31 * result + requestId
        result = 31 * result + status
        result = 31 * result + payload.contentHashCode()
        result = 31 * result + version
        return result
    }
}

data class BridgeInfo(
    val stage: Int,
    val firmware: String,
    val buildId: String,
    val frameSize: Int,
    val maxPayload: Int,
    val capabilities: Int,
    val profile: BleProtocol.BridgeProfile,
) {
    /** INFO describes the ESP32 bridge; the FPGA link state is tracked separately. */
    val fpgaLinkVerified: Boolean = false
}

data class FpgaState(
    val build: Long,
    val revision: Int,
    val master: Int,
) {
    init {
        require(build in 0..0xFFFFFFFFL) { "invalid FPGA build" }
        require(revision in 0..0xFFFF) { "invalid FPGA revision" }
        require(master in 0..16) { "master index must be in 0..16" }
    }

    val buildHex: String get() = "%08X".format(build)
    val masterPercent: Int get() = BleProtocol.percentOf(master)

    fun encode(): ByteArray = ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN)
        .putInt(build.toInt())
        .putShort(revision.toShort())
        .put(master.toByte())
        .array()
}

data class TimbreState(
    val build: Long,
    val revision: Int,
    val timbre: Int,
) {
    init {
        require(build in 0..0xFFFFFFFFL) { "invalid FPGA build" }
        require(revision in 0..0xFFFF) { "invalid FPGA revision" }
        require(timbre in 0..3) { "timbre must be in 0..3" }
    }

    val buildHex: String get() = "%08X".format(build)
    val label: String get() = Timbre.from(timbre).label

    fun encode(): ByteArray = ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN)
        .putInt(build.toInt())
        .putShort(revision.toShort())
        .put(timbre.toByte())
        .array()
}

/** Utility for logs: a compact hex dump of a frame. */
fun ByteArray.toHex(): String = joinToString(" ") { "%02X".format(it) }
