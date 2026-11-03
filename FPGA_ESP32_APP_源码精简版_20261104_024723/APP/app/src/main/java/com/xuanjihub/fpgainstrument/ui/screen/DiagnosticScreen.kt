package com.xuanjihub.fpgainstrument.ui.screen

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xuanjihub.fpgainstrument.ble.AdsrField
import com.xuanjihub.fpgainstrument.ui.AppUiState
import com.xuanjihub.fpgainstrument.ui.AppViewModel
import com.xuanjihub.fpgainstrument.ui.ReadFailureKind
import com.xuanjihub.fpgainstrument.ui.components.NoticeLevel
import com.xuanjihub.fpgainstrument.ui.components.WarningCard
import com.xuanjihub.fpgainstrument.ui.theme.LocalStatusColors
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val TableCard = Modifier
    .fillMaxWidth()
    .padding(horizontal = 12.dp)
    .padding(bottom = 12.dp)

/**
 * 诊断页：三层链路 + 真实参数 + 协议信息 + 日志。
 *
 * 只读展示；未验证的层标记“未验证”。
 */
@Composable
fun DiagnosticScreen(
    ui: AppUiState,
    onRefresh: () -> Unit,
    onClearLogs: () -> Unit,
    onShareLogs: () -> Unit,
    logPath: String,
) {
    val board = ui.state
    val timbre = ui.timbre
    val info = ui.info
    val profile = info?.profile

    if (!ui.ready) {
        WarningCard(
            headline = "未连接",
            body = "先到“连接”页扫描并连接；没有链路时这里不会伪造任何板端值。",
        )
    } else if (!ui.fpgaStateVerified) {
        val failure = ui.readFailure
        WarningCard(
            headline = failure?.headline ?: "FPGA 状态未验证",
            body = failure?.let { it.detail + (it.hint?.let { hint -> "\n" + hint } ?: "") }
                ?: "BLE 已连接，但还没有成功的 GET_STATE；INFO 不能证明 FPGA 在线。",
            level = if (failure?.kind == ReadFailureKind.FpgaUnavailable ||
                failure?.kind == ReadFailureKind.BuildRejected
            ) {
                NoticeLevel.Error
            } else {
                NoticeLevel.Notice
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

    SectionTitle("链路")
    Card(modifier = TableCard) {
        LayerRow(
            title = "BLE 链路",
            ok = ui.ready,
            value = if (ui.ready) ui.connectionName ?: "已连接" else ui.phaseDetail,
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        LayerRow(
            title = "ESP32 INFO",
            ok = ui.bridgeInfoVerified,
            value = info?.let { "${it.firmware} / ${it.buildId}" } ?: "未验证",
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        LayerRow(
            title = "FPGA 状态",
            ok = ui.fpgaStateVerified,
            value = board?.let { "${it.buildHex} · revision ${it.revision}" }
                ?: ui.readFailure?.headline
                ?: "未验证",
        )
    }

    SectionTitle("参数")
    Card(modifier = TableCard) {
        ValueRow(
            title = "FPGA build",
            value = board?.buildHex ?: "—",
            hint = profile?.let { "profile ${it.buildId}" },
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ValueRow(
            title = "revision",
            value = board?.revision?.toString() ?: "—",
            hint = readHint(ui.stateReadAtMillis),
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ValueRow(
            title = "MASTER",
            value = board?.let { "${it.masterPercent}% · ${it.master}/16" } ?: "—",
            hint = if (board == null) "未读取" else "index ${board.master}",
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ValueRow(
            title = "音色",
            value = timbre?.label ?: if (ui.supportsTimbre) "未读取" else "不支持",
            hint = timbre?.let { "revision ${it.revision} · ${readHint(ui.timbreReadAtMillis)}" },
        )
    }

    if (ui.supportsAdsr) {
        SectionTitle("ADSR")
        Card(modifier = TableCard) {
            AdsrField.entries.forEachIndexed { index, field ->
                if (index > 0) {
                    HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
                }
                val state = ui.adsr[field]
                ValueRow(
                    title = field.label,
                    value = state?.let { "${it.index}/${field.maxIndex}" } ?: "未读取",
                    hint = state?.let {
                        "包络码 ${it.envelopeCode} · revision ${it.revision} · " +
                            readHint(ui.adsrReadAtMillis[field])
                    },
                )
            }
        }
    }

    SectionTitle("协议与固件")
    Card(modifier = TableCard) {
        ValueRow(title = "App 版本", value = AppViewModel.APP_VERSION)
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ValueRow(
            title = "协商 profile",
            value = profile?.let { "${it.id} · ${it.firmware} / ${it.buildId}" } ?: "未读取",
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ValueRow(
            title = "INFO 能力",
            value = info?.let {
                "stage ${it.stage} · frame ${it.frameSize} · caps 0x%02X".format(it.capabilities)
            } ?: "未读取",
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ValueRow(
            title = "FPGA 协议 build",
            value = board?.buildHex ?: "未读取",
            hint = "INFO 只证明桥接，GET_STATE 才证明 FPGA 在线",
        )
    }

    SectionTitle("操作")
    Card(modifier = TableCard) {
        ArrowPreference(
            title = "刷新链路与参数",
            summary = if (ui.busy) "通信中…" else "重新读取 INFO、状态、音色与 ADSR",
            enabled = ui.ready && !ui.busy,
            onClick = onRefresh,
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ArrowPreference(
            title = "分享日志文件",
            summary = logPath,
            onClick = onShareLogs,
        )
        HorizontalDivider(color = MiuixTheme.colorScheme.dividerLine)
        ArrowPreference(
            title = "清空界面日志",
            summary = "只清空本页记录，不删除日志文件",
            onClick = onClearLogs,
        )
    }

    SectionTitle("最近记录")
    Card(
        modifier = TableCard,
        insideMargin = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
    ) {
        val lines = ui.logs.takeLast(10)
        if (lines.isEmpty()) {
            Text(
                text = "暂无日志",
                fontSize = 13.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            )
        } else {
            Column(modifier = Modifier.fillMaxWidth()) {
                lines.forEachIndexed { index, line ->
                    if (index > 0) {
                        Spacer(modifier = Modifier.size(6.dp))
                    }
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                        Text(
                            text = line.time,
                            fontSize = 11.sp,
                            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                            modifier = Modifier.padding(end = 8.dp),
                        )
                        Text(text = line.text, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun LayerRow(
    title: String,
    ok: Boolean,
    value: String,
) {
    val status = LocalStatusColors.current
    BasicComponent(
        title = title,
        summary = value,
        startAction = {
            Icon(
                imageVector = if (ok) Icons.Rounded.CheckCircleOutline else Icons.Rounded.ErrorOutline,
                contentDescription = null,
                modifier = Modifier
                    .padding(end = 12.dp)
                    .size(20.dp),
                tint = if (ok) status.okGraphic else MiuixTheme.colorScheme.onSurfaceSecondary,
            )
        },
    )
}

@Composable
private fun ValueRow(
    title: String,
    value: String,
    hint: String? = null,
) {
    BasicComponent(
        title = title,
        summary = hint,
        endActions = {
            Text(
                text = value,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            )
        },
    )
}

private fun readHint(millis: Long?): String =
    millis?.let { "读于 " + formatTime(it) } ?: "尚未读取"

private fun formatTime(millis: Long): String =
    SimpleDateFormat("HH:mm:ss", Locale.US).format(Date(millis))
