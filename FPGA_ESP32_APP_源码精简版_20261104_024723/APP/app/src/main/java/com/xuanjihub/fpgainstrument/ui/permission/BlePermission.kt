package com.xuanjihub.fpgainstrument.ui.permission

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect

enum class BlePermissionStatus {
    Granted,
    Missing,
    Denied,
    Blocked,
}

@Immutable
data class BlePermissionItem(
    val title: String,
    val summary: String,
    val granted: Boolean,
)

/**
 * 权限状态只由三件事决定：实际是否授予、是否已经请求过、系统是否还允许解释。
 *
 * 单独抽成纯函数，用于区分“首次未授予”和“被永久拒绝”（两者的
 * `shouldShowRequestPermissionRationale` 都是 false）。
 */
internal fun resolvePermissionStatus(
    granted: Boolean,
    requestedOnce: Boolean,
    canShowRationale: Boolean,
): BlePermissionStatus = when {
    granted -> BlePermissionStatus.Granted
    !requestedOnce -> BlePermissionStatus.Missing
    canShowRationale -> BlePermissionStatus.Denied
    else -> BlePermissionStatus.Blocked
}

/**
 * 蓝牙权限状态机。
 *
 * Controller 持有 Android 侧状态，Composable 只读 [status]/[items]/[dialogVisible] 并调用动作；
 * `checkSelfPermission`、`shouldShowRequestPermissionRationale` 和 Settings Intent 集中在这里。
 */
@Stable
class BlePermissionController internal constructor(
    private val context: Context,
    private val permissions: Array<String>,
    private val onGranted: () -> Unit,
) {
    private val prefs = context.getSharedPreferences("ble_permission", Context.MODE_PRIVATE)

    var status by mutableStateOf(BlePermissionStatus.Missing)
        private set

    var dialogVisible by mutableStateOf(false)
        private set

    private var requestedOnce by mutableStateOf(prefs.getBoolean(KEY_REQUESTED_ONCE, false))
    private var scanAfterGrant = false
    private var launch: ((Array<String>) -> Unit)? = null

    init {
        status = resolvePermissionStatus(
            granted = permissions.all(::isGranted),
            requestedOnce = requestedOnce,
            canShowRationale = canShowRationale(),
        )
    }

    val granted: Boolean
        get() = status == BlePermissionStatus.Granted

    val items: List<BlePermissionItem>
        get() = buildItems()

    internal fun bindLauncher(launcher: (Array<String>) -> Unit) {
        launch = launcher
    }

    /**
     * 重新读取真实权限并同步状态。App 从系统授权页/应用设置返回时调用。
     * 只有本次确实要扫描时才在授权成功后自动开始扫描。
     */
    fun refresh() {
        val nowGranted = permissions.all(::isGranted)
        status = resolvePermissionStatus(
            granted = nowGranted,
            requestedOnce = requestedOnce,
            canShowRationale = canShowRationale(),
        )
        if (!nowGranted) return

        dialogVisible = false
        if (scanAfterGrant) {
            scanAfterGrant = false
            onGranted()
        }
    }

    /** 点击“授权/去授权”：先弹说明，确认后再拉系统授权框。 */
    fun requestFromUser() {
        val alreadyWantedScan = scanAfterGrant
        refresh()
        if (granted) {
            // refresh() 已处理本次授权后的扫描；同一次点击只触发一次。
            if (!alreadyWantedScan) onGranted()
            return
        }
        scanAfterGrant = true
        dialogVisible = true
    }

    /** 说明弹窗里的“允许/重试”；已被永久拒绝时改走应用设置。 */
    fun allow() {
        val alreadyWantedScan = scanAfterGrant
        refresh()
        if (granted) {
            if (!alreadyWantedScan) onGranted()
            return
        }
        if (status == BlePermissionStatus.Blocked) {
            openSettings()
            return
        }
        scanAfterGrant = true
        val launcher = launch
        if (launcher == null) {
            openSettings()
            return
        }
        launcher(permissions)
    }

    fun dismissDialog() {
        dialogVisible = false
        scanAfterGrant = false
    }

    fun openSettings() {
        dialogVisible = false
        scanAfterGrant = true
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    internal fun onPermissionResult() {
        requestedOnce = true
        prefs.edit().putBoolean(KEY_REQUESTED_ONCE, true).apply()
        // 厂商回调返回的 Map 仅作参考；真实状态以 checkSelfPermission 为准。
        refresh()
        if (!granted) {
            scanAfterGrant = true
            dialogVisible = true
        }
    }

    private fun buildItems(): List<BlePermissionItem> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return listOf(
                BlePermissionItem(
                    title = "附近的设备",
                    summary = "扫描并连接 FPGA-BLE-N07",
                    granted = permissions.all(::isGranted),
                ),
            )
        }
        return legacyItems()
    }

    private fun legacyItems(): List<BlePermissionItem> =
        permissions.map { permission ->
            BlePermissionItem(
                title = if (permission == Manifest.permission.ACCESS_FINE_LOCATION) "位置信息" else "蓝牙",
                summary = if (permission == Manifest.permission.ACCESS_FINE_LOCATION) {
                    "Android 11 及以下扫描 BLE 设备所需"
                } else {
                    "旧版 Android 的蓝牙访问权限"
                },
                granted = isGranted(permission),
            )
        }

    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun canShowRationale(): Boolean {
        val activity = context.findActivity() ?: return true
        return permissions.any {
            ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
        }
    }
}

@Composable
fun rememberBlePermissionController(onGranted: () -> Unit): BlePermissionController {
    val context = LocalContext.current
    val permissions = remember { requiredBlePermissions() }
    val currentOnGranted by rememberUpdatedState(onGranted)
    val controller = remember(context, permissions) {
        BlePermissionController(context, permissions) { currentOnGranted() }
    }
    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        controller.onPermissionResult()
    }

    SideEffect {
        controller.bindLauncher { launcher.launch(it) }
    }
    LaunchedEffect(controller) {
        controller.refresh()
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        controller.refresh()
    }
    return controller
}

private fun requiredBlePermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

private const val KEY_REQUESTED_ONCE = "requested_once"

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
