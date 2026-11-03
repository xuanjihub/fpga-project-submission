package com.xuanjihub.fpgainstrument.ui

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.xuanjihub.fpgainstrument.ble.BleProtocol
import com.xuanjihub.fpgainstrument.ble.Timbre
import com.xuanjihub.fpgainstrument.ui.components.ConfirmDialog
import com.xuanjihub.fpgainstrument.ui.permission.BlePermissionDialog
import com.xuanjihub.fpgainstrument.ui.permission.rememberBlePermissionController
import com.xuanjihub.fpgainstrument.ui.screen.ConnectScreen
import com.xuanjihub.fpgainstrument.ui.screen.DiagnosticScreen
import com.xuanjihub.fpgainstrument.ui.screen.InstrumentScreen
import com.xuanjihub.fpgainstrument.ui.theme.AppTheme
import top.yukonga.miuix.kmp.basic.NavigationBar
import top.yukonga.miuix.kmp.basic.NavigationBarItem
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Info
import top.yukonga.miuix.kmp.icon.extended.Link
import top.yukonga.miuix.kmp.icon.extended.Music

/**
 * App 骨架：连接 / 乐器 / 诊断。三个页面显示 stage-1 链路的实时数据。
 */
@Composable
fun AppRoot(viewModel: AppViewModel = viewModel()) {
    val ui by viewModel.ui.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var tab by remember { mutableIntStateOf(0) }
    val titles = listOf("连接", "乐器", "诊断")
    val blePermission = rememberBlePermissionController {
        viewModel.startScan()
    }
    val scanAction: () -> Unit = {
        if (blePermission.granted) {
            viewModel.startScan()
        } else {
            blePermission.requestFromUser()
        }
    }

    LaunchedEffect(Unit) {
        viewModel.refreshBluetoothEnabled()
    }

    AppTheme {
        Scaffold(
            topBar = {
                TopAppBar(title = titles[tab], largeTitle = titles[tab])
            },
            bottomBar = {
                NavigationBar {
                    NavigationBarItem(
                        selected = tab == 0,
                        onClick = { tab = 0 },
                        icon = MiuixIcons.Link,
                        label = "连接",
                    )
                    NavigationBarItem(
                        selected = tab == 1,
                        onClick = { tab = 1 },
                        icon = MiuixIcons.Music,
                        label = "乐器",
                    )
                    NavigationBarItem(
                        selected = tab == 2,
                        onClick = { tab = 2 },
                        icon = MiuixIcons.Info,
                        label = "诊断",
                    )
                }
            },
        ) { innerPadding ->
            PageContainer(innerPadding) {
                when (tab) {
                    0 -> ConnectScreen(
                        ui = ui,
                        blePermissionGranted = blePermission.granted,
                        onRequestPermission = blePermission::requestFromUser,
                        onScan = scanAction,
                        onStopScan = viewModel::stopScan,
                        onConnect = viewModel::connect,
                        onDisconnect = viewModel::disconnect,
                        onRefresh = viewModel::refresh,
                        onOpenBluetoothSettings = { openBluetoothSettings(context) },
                    )

                    1 -> InstrumentScreen(
                        ui = ui,
                        onDraftChange = viewModel::updateMasterDraft,
                        onApplyBatch = viewModel::requestApplyBatch,
                        onResetDrafts = viewModel::resetDrafts,
                        onRefresh = viewModel::refresh,
                        onTimbreDraftChange = viewModel::updateTimbreDraft,
                        onAdsrDraftChange = viewModel::updateAdsrDraft,
                    )

                    else -> DiagnosticScreen(
                        ui = ui,
                        onRefresh = viewModel::refresh,
                        onClearLogs = viewModel::clearLogs,
                        onShareLogs = { viewModel.shareLogs(context) },
                        logPath = viewModel.logPath,
                    )
                }
            }
        }

        ui.confirmation?.let { confirmation ->
            ApplyConfirmDialog(
                confirmation = confirmation,
                onConfirm = viewModel::confirmApply,
                onDismiss = viewModel::dismissConfirmation,
            )
        }

        ui.timbreConfirmation?.let { confirmation ->
            TimbreConfirmDialog(
                confirmation = confirmation,
                onConfirm = viewModel::confirmApplyTimbre,
                onDismiss = viewModel::dismissTimbreConfirmation,
            )
        }

        ui.adsrConfirmation?.let { confirmation ->
            AdsrConfirmDialog(
                confirmation = confirmation,
                onConfirm = viewModel::confirmApplyAdsr,
                onDismiss = viewModel::dismissAdsrConfirmation,
            )
        }

        ui.batchConfirmation?.let { confirmation ->
            BatchConfirmDialog(
                confirmation = confirmation,
                onConfirm = viewModel::confirmApplyBatch,
                onDismiss = viewModel::dismissBatchConfirmation,
            )
        }

        BlePermissionDialog(controller = blePermission)
    }
}

@Composable
private fun PageContainer(
    innerPadding: PaddingValues,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            // 顶部栏与底部栏的高度都要让出来；padding 必须在 verticalScroll 之前。
            .padding(
                top = innerPadding.calculateTopPadding(),
                bottom = innerPadding.calculateBottomPadding(),
            )
            .verticalScroll(rememberScrollState())
            .padding(bottom = 24.dp),
    ) {
        content()
    }
}

@Composable
private fun ApplyConfirmDialog(
    confirmation: SetMasterConfirmation,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    ConfirmDialog(
        show = true,
        title = "确认远程写入",
        summary = "目标 MASTER index ${confirmation.target}（${BleProtocol.percentOf(confirmation.target)}%）",
        confirmText = "确认写入",
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    ) {
        Text(
            text = "期望 FPGA build ${confirmation.expectedBuild}，revision ${confirmation.expectedRevision}",
            fontSize = 13.sp,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "这是未配对、未加密的开发控制接口。板端 BUSY / STOP 优先；" +
                "失败或超时不会自动重发，也不会伪造回滚。",
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun TimbreConfirmDialog(
    confirmation: SetTimbreConfirmation,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    ConfirmDialog(
        show = true,
        title = "确认切换音色",
        summary = "目标 ${Timbre.from(confirmation.target).label}（${confirmation.target}），" +
            "板端 ${Timbre.from(confirmation.boardTimbre).label}",
        confirmText = "确认切换",
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    ) {
        Text(
            text = "期望 FPGA build ${confirmation.expectedBuild}，revision ${confirmation.expectedRevision}",
            fontSize = 13.sp,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "只发送一次 SET_TIMBRE；音色作用于下一次新触发，已保持的音不强制换色。" +
                "BUSY/STOP 优先，失败或超时不会自动重发。",
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun BatchConfirmDialog(
    confirmation: SetBatchConfirmation,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    ConfirmDialog(
        show = true,
        title = "确认写入 ${confirmation.items.size} 项",
        summary = "按顺序逐项写入；每项独立 CAS，任一项未确认即停止",
        confirmText = "写入",
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    ) {
        confirmation.items.forEach { item ->
            Text(text = item.label, fontSize = 14.sp)
            Spacer(modifier = Modifier.height(4.dp))
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "这是未配对、未加密的开发接口；BUSY/STOP 优先，失败或超时不会自动重发。",
            fontSize = 13.sp,
        )
    }
}

@Composable
private fun AdsrConfirmDialog(
    confirmation: SetAdsrConfirmation,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val field = confirmation.field
    ConfirmDialog(
        show = true,
        title = "确认写入 ${field.label}",
        summary = "目标档位 ${confirmation.target}/${field.maxIndex}" +
            "（包络码 ${BleProtocol.envelopeCode(field, confirmation.target)}），" +
            "板端档位 ${confirmation.boardIndex}",
        confirmText = "确认写入",
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    ) {
        Text(
            text = "期望 FPGA build ${confirmation.expectedBuild}，revision ${confirmation.expectedRevision}",
            fontSize = 13.sp,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "只发送一次 SET_${field.label}；只改这一个字段，不构成四参数原子预设。" +
                "BUSY/STOP 优先，失败或超时不会自动重发。",
            fontSize = 13.sp,
        )
    }
}

private fun openBluetoothSettings(context: Context) {
    runCatching {
        context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
    }
}
