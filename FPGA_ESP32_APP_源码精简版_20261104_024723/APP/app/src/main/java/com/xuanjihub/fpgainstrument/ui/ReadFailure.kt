package com.xuanjihub.fpgainstrument.ui

import com.xuanjihub.fpgainstrument.ble.BleProtocol
import com.xuanjihub.fpgainstrument.ble.BridgeBusy
import com.xuanjihub.fpgainstrument.ble.BridgeDisconnected
import com.xuanjihub.fpgainstrument.ble.BridgeStatusError
import com.xuanjihub.fpgainstrument.ble.BridgeTimeout
import com.xuanjihub.fpgainstrument.ble.UnsupportedFpgaBuild

/**
 * Why the last FPGA state read failed. This stays separate from the BLE link
 * phase: the phone can be connected to the ESP32 (`Phase.Ready`) while the
 * FPGA is unavailable, or while the bridge refuses an unsupported build.
 */
enum class ReadFailureKind {
    /** Bridge answered `FPGA_UNAVAILABLE (0x10)`: no valid FPGA reply. */
    FpgaUnavailable,

    /** Bridge answered OK, but the FPGA build is not in the exact allowlist. */
    BuildRejected,

    /** Another App operation holds the bridge, or the board reported BUSY. */
    Busy,

    /** No RESULT frame before the transport timeout. */
    Timeout,

    /** The GATT link dropped while reading. */
    Disconnected,

    /** Malformed, mismatched or otherwise unexpected response. */
    Protocol,
}

data class ReadFailure(
    val kind: ReadFailureKind,
    val detail: String,
    val hint: String? = null,
) {
    val headline: String
        get() = when (kind) {
            ReadFailureKind.FpgaUnavailable -> "FPGA 状态不可用"
            ReadFailureKind.BuildRejected -> "FPGA 构建不受支持"
            ReadFailureKind.Busy -> "板端忙"
            ReadFailureKind.Timeout -> "读取 FPGA 超时"
            ReadFailureKind.Disconnected -> "蓝牙连接已断开"
            ReadFailureKind.Protocol -> "FPGA 状态读取失败"
        }
}

/**
 * Maps a repository/transport exception to the read failure shown in the UI.
 *
 * [BridgeStatusError.status] keeps `FPGA_UNAVAILABLE` distinct from BUSY or a
 * revision conflict; [UnsupportedFpgaBuild] means the bridge answered but the
 * build is outside this profile's allowlist.
 */
internal fun classifyReadFailure(error: Throwable): ReadFailure = when (error) {
    is UnsupportedFpgaBuild -> ReadFailure(
        kind = ReadFailureKind.BuildRejected,
        detail = error.message ?: "FPGA 构建不受支持",
        hint = "未发送任何参数写入。当前 profile 精确接受：" +
            error.acceptedBuilds.joinToString { "%08X".format(it) } +
            "；请使用与 ESP32 配套的 FPGA 程序。",
    )

    is BridgeStatusError -> when (error.status) {
        BleProtocol.FPGA_UNAVAILABLE -> ReadFailure(
            kind = ReadFailureKind.FpgaUnavailable,
            detail = "桥接返回 FPGA_UNAVAILABLE：ESP32 没有拿到 FPGA 的有效回复。",
            hint = "INFO 只能证明 ESP32 桥接在线，不能证明 FPGA 在线。请核对 FPGA 已运行程序、" +
                "UART 收发接线及共地；D06（50314D06）参数控制需要 ESP32 0.5.0 配套固件。",
        )

        BleProtocol.BUSY -> ReadFailure(
            kind = ReadFailureKind.Busy,
            detail = "板端报告 BUSY：可能正在编辑或按住 STOP。",
            hint = "未自动重试；松开 STOP 后再刷新。",
        )

        else -> ReadFailure(
            kind = ReadFailureKind.Protocol,
            detail = error.message ?: "桥接返回 ${BleProtocol.statusName(error.status)}",
            hint = "未自动重试；旧状态已清空。",
        )
    }

    is BridgeTimeout -> ReadFailure(
        kind = ReadFailureKind.Timeout,
        detail = if (error.submitted) {
            "命令已发出，但超时前没有收到 RESULT。"
        } else {
            "命令未发出，等待写入通道超时。"
        },
        hint = "旧状态已清空；未自动重发。",
    )

    is BridgeDisconnected -> ReadFailure(
        kind = ReadFailureKind.Disconnected,
        detail = error.message ?: "蓝牙连接已断开",
        hint = "旧状态已清空；不会自动重连或重放 SET。",
    )

    is BridgeBusy -> ReadFailure(
        kind = ReadFailureKind.Busy,
        detail = error.message ?: "另一个操作正在进行",
        hint = "等待当前操作结束后再刷新。",
    )

    else -> ReadFailure(
        kind = ReadFailureKind.Protocol,
        detail = error.message ?: error::class.simpleName ?: "未知错误",
    )
}
