package com.xuanjihub.fpgainstrument.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xuanjihub.fpgainstrument.ble.AdsrField
import com.xuanjihub.fpgainstrument.ble.BleProtocol
import com.xuanjihub.fpgainstrument.ble.Timbre
import com.xuanjihub.fpgainstrument.ui.AppUiState
import com.xuanjihub.fpgainstrument.ui.ReadFailureKind
import com.xuanjihub.fpgainstrument.ui.components.NoticeLevel
import com.xuanjihub.fpgainstrument.ui.components.WarningCard
import com.xuanjihub.fpgainstrument.ui.theme.LocalStatusColors
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Slider
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.theme.MiuixTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/**
 * 乐器页：单屏演奏面板。
 *
 * 一个参数一行；滑杆只改草稿。底部“写入”一次提交所有脏参数（前端逐项 CAS），
 * “撤销”丢弃未写入的草稿并同步回最近一次板端读取。
 */
@Composable
fun InstrumentScreen(
    ui: AppUiState,
    onDraftChange: (Float) -> Unit,
    onApplyBatch: () -> Unit,
    onResetDrafts: () -> Unit,
    onRefresh: () -> Unit,
    onTimbreDraftChange: (Int) -> Unit,
    onAdsrDraftChange: (AdsrField, Int) -> Unit,
) {
    if (!ui.ready) {
        WarningCard(
            headline = "未连接真实设备",
            body = "先到“连接”页扫描并连接 FPGA-BLE-N07；MASTER、音色和 ADSR 都需要真实连接。",
        )
    }

    ConnectionStrip(ui)
    if (ui.ready && !ui.fpgaStateVerified) {
        ui.readFailure?.let { failure ->
            WarningCard(
                headline = failure.headline,
                body = buildString {
                    append(failure.detail)
                    failure.hint?.let { append("\n\n").append(it) }
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
    ui.notice?.let { NoticeLine(it) }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(bottom = 12.dp),
    ) {
        MasterRow(ui, onDraftChange)
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        AdsrSection(ui, onAdsrDraftChange)
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        TimbreSection(ui, onTimbreDraftChange)
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        WriteBar(
            ui = ui,
            onApplyBatch = onApplyBatch,
            onResetDrafts = onResetDrafts,
        )
    }

    Text(
        text = "写入为逐项 CAS：每段“读 → SET → ACK → 读回”，任一项未确认即停止；" +
            "stage 1 是未加密的开发接口。",
        fontSize = 12.sp,
        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

@Composable
private fun ConnectionStrip(ui: AppUiState) {
    val status = LocalStatusColors.current
    val dotColor = when {
        ui.fpgaStateVerified -> status.okGraphic
        ui.ready && ui.bridgeInfoVerified -> Color(0xFFF0A020)
        ui.ready -> Color(0xFFF0A020)
        else -> MiuixTheme.colorScheme.outline
    }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(bottom = 8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(9.dp)
                    .clip(CircleShape)
                    .background(dotColor),
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = when {
                            ui.ready -> ui.connectionName ?: "已连接"
                            ui.scanning -> "扫描中…"
                            else -> "未连接"
                        },
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f),
                    )
                    if (ui.busy) {
                        Text(
                            text = "通信中…",
                            fontSize = 11.sp,
                            color = MiuixTheme.colorScheme.primary,
                        )
                    }
                }
                Text(
                    text = when {
                        !ui.ready -> "到“连接”页扫描 FPGA-BLE-N07"
                        ui.bridgeInfoVerified -> buildString {
                            append("BLE 已连接 · ESP32 INFO 已验证")
                            ui.info?.let { append(" · ${it.firmware} / ${it.buildId}") }
                        }
                        else -> "BLE 已连接 · ESP32 INFO 未验证"
                    },
                    fontSize = 11.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
                Text(
                    text = when {
                        !ui.ready -> ""
                        ui.fpgaStateVerified -> buildString {
                            append("FPGA 已验证 · ${ui.state?.buildHex}")
                            ui.state?.let {
                                append(" · revision ${it.revision} · MASTER ${it.master}/16")
                            }
                        }
                        ui.readFailure != null -> "FPGA 未验证 · ${ui.readFailure.headline}"
                        else -> "FPGA 未验证 · 尚未读取状态"
                    },
                    fontSize = 11.sp,
                    color = if (ui.fpgaStateVerified) {
                        MiuixTheme.colorScheme.onSurfaceVariantSummary
                    } else {
                        status.onErrorContainer
                    },
                )
            }
        }
    }
}

@Composable
private fun NoticeLine(text: String) {
    Text(
        text = text,
        fontSize = 12.sp,
        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
        modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp),
    )
}

@Composable
private fun MasterRow(ui: AppUiState, onDraftChange: (Float) -> Unit) {
    val board = ui.state
    val editable = board != null && !ui.busy
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(text = "总音量", fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Text(
                    text = "MASTER · index ${ui.masterDraft}/16",
                    fontSize = 11.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
            }
            StepButton("−", enabled = editable && ui.masterDraft > 0) {
                onDraftChange((ui.masterDraft - 1) / 16f)
            }
            Box(modifier = Modifier.width(64.dp), contentAlignment = Alignment.Center) {
                Text(
                    text = if (board == null) "—" else "${ui.percentDraft}%",
                    fontSize = 21.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            StepButton("＋", enabled = editable && ui.masterDraft < 16) {
                onDraftChange((ui.masterDraft + 1) / 16f)
            }
        }
        Slider(
            value = if (board == null) 0f else ui.masterDraft / 16f,
            onValueChange = onDraftChange,
            steps = 15,
            showKeyPoints = false,
            enabled = editable,
            height = 22.dp,
        )
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = board?.let { "板端 ${it.master}/16" } ?: "板端未读取",
                fontSize = 11.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = ui.stateReadAtMillis?.let { "读于 ${formatTime(it)}" } ?: "",
                fontSize = 11.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            )
        }
    }
}

@Composable
private fun AdsrSection(
    ui: AppUiState,
    onDraftChange: (AdsrField, Int) -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = "包络 ADSR", fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.weight(1f))
            if (!ui.supportsAdsr) {
                Text(
                    text = if (ui.ready) "当前固件不支持" else "未连接",
                    fontSize = 11.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
            }
        }
        if (ui.ready && ui.supportsAdsr) {
            AdsrField.entries.forEachIndexed { index, field ->
                if (index > 0) {
                    HorizontalDivider(
                        color = MiuixTheme.colorScheme.dividerLine,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp),
                    )
                }
                AdsrRow(ui, field, onDraftChange)
            }
        } else {
            Text(
                text = if (ui.ready) {
                    "ADSR 需要 0.4.0 桥接且 FPGA 为 50314B03 或 50314D03 的精确 profile；当前 profile 不会发送 ADSR 命令。"
                } else {
                    "连接后读取四字段；旧 profile 不会显示或发送 ADSR。"
                },
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 10.dp),
            )
        }
    }
}

@Composable
private fun AdsrRow(
    ui: AppUiState,
    field: AdsrField,
    onDraftChange: (AdsrField, Int) -> Unit,
) {
    val board = ui.adsr[field]
    val draft = ui.adsrDrafts[field] ?: field.defaultIndex
    val editable = board != null && !ui.busy
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(text = field.label, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Text(
                    text = "包络码 ${BleProtocol.envelopeCode(field, draft)}",
                    fontSize = 11.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
            }
            StepButton("−", enabled = editable && draft > 0) {
                onDraftChange(field, draft - 1)
            }
            Box(modifier = Modifier.width(56.dp), contentAlignment = Alignment.Center) {
                Text(
                    text = if (board == null) "—" else "$draft/${field.maxIndex}",
                    fontSize = 19.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            StepButton("＋", enabled = editable && draft < field.maxIndex) {
                onDraftChange(field, draft + 1)
            }
        }
        Slider(
            value = if (board == null) 0f else draft / field.maxIndex.toFloat(),
            onValueChange = { value -> onDraftChange(field, (value * field.maxIndex).roundToInt()) },
            steps = (field.maxIndex - 1).coerceAtLeast(1),
            showKeyPoints = false,
            enabled = editable,
            height = 20.dp,
        )
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = board?.let { "板端 ${it.index}/${field.maxIndex} · rev ${it.revision}" }
                    ?: "板端未读取",
                fontSize = 11.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = ui.adsrReadAtMillis[field]?.let { "读于 ${formatTime(it)}" } ?: "",
                fontSize = 11.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            )
        }
    }
}

@Composable
private fun TimbreSection(ui: AppUiState, onDraftChange: (Int) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(text = "音色", fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.weight(1f))
            if (ui.ready && ui.supportsTimbre) {
                Text(
                    text = "板端 ${ui.timbre?.let { Timbre.from(it.timbre).label } ?: "未读取"}",
                    fontSize = 11.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
            }
        }
        if (ui.ready && ui.supportsTimbre && ui.timbre != null) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Timbre.entries.forEach { option ->
                    val isDraft = ui.timbreDraft == option.value
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(
                                if (isDraft) MiuixTheme.colorScheme.primaryContainer
                                else MiuixTheme.colorScheme.surfaceVariant,
                            )
                            .clickable(enabled = ui.ready && ui.timbre != null && !ui.busy) {
                                onDraftChange(option.value)
                            }
                            .padding(vertical = 9.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = option.label,
                            fontSize = 13.sp,
                            color = if (isDraft) {
                                MiuixTheme.colorScheme.onPrimaryContainer
                            } else {
                                MiuixTheme.colorScheme.onSurface
                            },
                        )
                    }
                }
            }
            Text(
                text = "草稿 ${Timbre.from(ui.timbreDraft).label}",
                fontSize = 11.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.padding(top = 4.dp),
            )
        } else {
            Text(
                text = when {
                    !ui.ready -> "连接后按 profile 显示音色控制。"
                    !ui.supportsTimbre -> "当前 profile 不支持音色，只发送 MASTER 命令。"
                    else -> "板端音色未读取；刷新到真实状态后才可选择。"
                },
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun WriteBar(
    ui: AppUiState,
    onApplyBatch: () -> Unit,
    onResetDrafts: () -> Unit,
) {
    val pending = ui.pendingWriteCount
    val summary = ui.batchSummary
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = when {
                    !ui.ready -> "未连接"
                    !ui.fpgaStateVerified -> "板端状态未验证"
                    pending > 0 -> "待写入 $pending 项"
                    else -> "已与板端一致"
                },
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = when {
                    summary != null -> summary
                    !ui.ready -> "连接后可写入"
                    !ui.fpgaStateVerified -> "先刷新到真实 FPGA 状态，草稿才可编辑"
                    pending > 0 -> "按顺序逐项写入 · 每项独立 CAS"
                    else -> "编辑任意参数后在这里一次写入"
                },
                fontSize = 11.sp,
                color = if (summary != null) {
                    MiuixTheme.colorScheme.primary
                } else {
                    MiuixTheme.colorScheme.onSurfaceVariantSummary
                },
            )
        }
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable(enabled = pending > 0 && !ui.busy) { onResetDrafts() }
                .padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            Text(
                text = "撤销",
                fontSize = 13.sp,
                color = if (pending > 0 && !ui.busy) {
                    MiuixTheme.colorScheme.onSurfaceVariantActions
                } else {
                    MiuixTheme.colorScheme.onSurfaceSecondary.copy(alpha = 0.4f)
                },
            )
        }
        Spacer(Modifier.width(6.dp))
        Button(
            onClick = onApplyBatch,
            enabled = pending > 0 && ui.ready && !ui.busy,
        ) {
            Text("写入")
        }
    }
}

@Composable
private fun StepButton(symbol: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = symbol,
            fontSize = 18.sp,
            color = if (enabled) {
                MiuixTheme.colorScheme.onSurface
            } else {
                MiuixTheme.colorScheme.onSurfaceSecondary.copy(alpha = 0.4f)
            },
        )
    }
}

@Composable
internal fun SectionTitle(text: String) {
    top.yukonga.miuix.kmp.basic.SmallTitle(text = text)
}

private fun formatTime(millis: Long): String =
    SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(millis))
