package com.xuanjihub.fpgainstrument.ui.screen

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xuanjihub.fpgainstrument.BuildConfig
import com.xuanjihub.fpgainstrument.ui.AppUiState
import com.xuanjihub.fpgainstrument.ui.Phase
import com.xuanjihub.fpgainstrument.ui.ReadFailureKind
import com.xuanjihub.fpgainstrument.ui.components.NoticeLevel
import com.xuanjihub.fpgainstrument.ui.components.PageNote
import com.xuanjihub.fpgainstrument.ui.components.StatusHeroCard
import com.xuanjihub.fpgainstrument.ui.components.WarningCard
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.InfiniteProgressIndicator
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme

private val TableCard = Modifier
    .fillMaxWidth()
    .padding(horizontal = 12.dp)
    .padding(bottom = 12.dp)

@Composable
fun ConnectScreen(
    ui: AppUiState,
    blePermissionGranted: Boolean,
    onRequestPermission: () -> Unit,
    onScan: () -> Unit,
    onStopScan: () -> Unit,
    onConnect: (String) -> Unit,
    onDisconnect: () -> Unit,
    onRefresh: () -> Unit,
    onOpenBluetoothSettings: () -> Unit,
) {
    val headline = when (ui.phase) {
        Phase.Ready -> "已连接"
        Phase.Connecting, Phase.Discovering, Phase.Subscribing, Phase.ReadingInfo -> "正在连接"
        Phase.BluetoothOff -> "蓝牙未开启"
        Phase.Failed -> "连接失败"
        Phase.Disconnected -> "未连接"
    }
    StatusHeroCard(
        headline = headline,
        lines = buildList {
            if (ui.ready) {
                // 已连接只保留设备名；阶段/控制说明放在下方“当前链路”和提示里。
                add(ui.connectionName ?: "stage-1 链路已就绪")
            } else {
                if (ui.phaseDetail != headline) add(ui.phaseDetail)
                if (ui.phase == Phase.Disconnected || ui.phase == Phase.BluetoothOff) {
                    add("目标服务：stage-1 UUID 过滤")
                }
            }
        },
        ok = ui.ready,
    )

    ui.notice?.let { PageNote(it) }

    if (ui.ready && !ui.fpgaStateVerified) {
        ui.readFailure?.let { failure ->
            WarningCard(
                headline = failure.headline,
                body = buildString {
                    append("BLE 已连接，ESP32 INFO 已验证，但 FPGA 状态未验证。\n")
                    append(failure.detail)
                    failure.hint?.let { append("\n").append(it) }
                },
                level = when (failure.kind) {
                    ReadFailureKind.FpgaUnavailable, ReadFailureKind.BuildRejected ->
                        NoticeLevel.Error
                    else -> NoticeLevel.Notice
                },
                action = {
                    TextButton(
                        text = "重试",
                        onClick = onRefresh,
                        colors = ButtonDefaults.textButtonColorsPrimary(),
                    )
                },
            )
        }
    }

    if (!blePermissionGranted) {
        WarningCard(
            headline = "蓝牙权限未授予",
            body = "扫描、连接需要“附近的设备”权限；只在前台使用，不用于定位。",
            action = {
                TextButton(
                    text = "授予",
                    onClick = onRequestPermission,
                    colors = ButtonDefaults.textButtonColorsPrimary(),
                )
            },
        )
    }

    if (!ui.bluetoothEnabled) {
        WarningCard(
            headline = "蓝牙未开启",
            body = "请先在系统设置中打开蓝牙，再回到本页扫描。Android 12+ 还需要授予“附近的设备”权限。",
        )
        Row(modifier = Modifier.padding(horizontal = 12.dp)) {
            Button(onClick = onOpenBluetoothSettings) { Text("打开蓝牙设置") }
            Spacer(modifier = Modifier.size(12.dp))
            Button(onClick = onScan) { Text("已开启，重新扫描") }
        }
        Spacer(modifier = Modifier.size(12.dp))
    }

    SectionTitle("扫描")
    Card(modifier = TableCard) {
        ArrowPreference(
            title = if (ui.scanning) "停止扫描" else "扫描 stage-1 设备",
            summary = if (ui.scanning) {
                "正在扫描…（10 秒后自动停止）"
            } else {
                "10 秒超时 · 只显示广播目标服务 UUID 的设备"
            },
            endActions = {
                if (ui.scanning) {
                    InfiniteProgressIndicator(
                        modifier = Modifier.padding(end = 8.dp),
                        size = 18.dp,
                        strokeWidth = 2.dp,
                    )
                }
            },
            onClick = if (ui.scanning) onStopScan else onScan,
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        if (ui.devices.isEmpty()) {
            BasicComponent(
                title = if (ui.scanning) "正在查找设备" else "尚未发现设备",
                summary = if (ui.scanning) "等待广播…" else "确认 ESP32 已上电且手机蓝牙已开启",
            )
        } else {
            ui.devices.forEach { device ->
                ArrowPreference(
                    title = device.name,
                    summary = "${device.address} · RSSI ${device.rssi} dBm",
                    onClick = { onConnect(device.address) },
                )
            }
        }
    }

    SectionTitle("当前链路")
    Card(modifier = TableCard) {
        BasicComponent(
            title = "App 版本",
            summary = "${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}） · " +
                "支持 ESP32 0.4.0 / 0.5.0 参数控制",
        )
        BasicComponent(
            title = "BLE 链路",
            summary = if (ui.ready) {
                "已连接 · ${ui.connectionName ?: "stage-1 链路"}"
            } else {
                ui.phaseDetail
            },
        )
        BasicComponent(
            title = "ESP32 INFO",
            summary = ui.info?.let {
                "已验证 · ${it.firmware} / ${it.buildId} · profile ${it.profile.id} · " +
                    "caps 0x%02X".format(it.capabilities)
            } ?: "未验证",
        )
        BasicComponent(
            title = "FPGA 状态",
            summary = when {
                ui.state != null ->
                    "已验证 · ${ui.state.buildHex} · revision ${ui.state.revision}"
                ui.readFailure != null ->
                    "未验证 · ${ui.readFailure.detail}"
                else -> "未读取"
            },
        )
        BasicComponent(
            title = "当前 MASTER",
            summary = ui.state?.let { "${it.masterPercent}%（index ${it.master}/16）" } ?: "未读取",
        )
    }

    if (ui.ready) {
        Row(modifier = Modifier.padding(horizontal = 12.dp)) {
            Button(onClick = onRefresh, enabled = !ui.busy) { Text("刷新 INFO / 状态") }
            Spacer(modifier = Modifier.size(12.dp))
            Button(onClick = onDisconnect) { Text("断开") }
        }
        Spacer(modifier = Modifier.size(12.dp))
        PageNote("连接成功后只自动读取 INFO、状态和音色（如 profile 支持），不会自动写入。")
    }

    Spacer(modifier = Modifier.size(12.dp))
    PageNote(
        when {
            ui.supportsAdsr ->
                "当前 profile 支持 MASTER、音色与 ADSR 的读取/写入；接受的 FPGA：" +
                    ui.info?.profile?.acceptedFpgaBuilds.orEmpty().joinToString { "%08X".format(it) } +
                    "。App 只调整参数。"
            ui.supportsTimbre ->
                "协议边界：当前 profile 支持 MASTER 与音色；固件没有 ADSR、预设、音符、音频流命令，" +
                    "App 不提供对应界面。"
            else ->
                "协议边界：当前 profile 仅支持 GET_INFO / GET_STATE / SET_MASTER；" +
                    "固件没有音色、ADSR、预设、音符、音频流命令，App 不提供对应界面。"
        },
    )
    PageNote("ESP32 同时只接受一个蓝牙连接。手机连接前，请先断开电脑或其他手机的连接。")
}
