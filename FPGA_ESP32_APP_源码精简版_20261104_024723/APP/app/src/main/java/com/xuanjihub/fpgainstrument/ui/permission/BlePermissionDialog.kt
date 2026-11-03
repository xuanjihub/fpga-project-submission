package com.xuanjihub.fpgainstrument.ui.permission

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bluetooth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.LocationOff
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xuanjihub.fpgainstrument.R
import com.xuanjihub.fpgainstrument.ui.components.ConfirmDialog
import com.xuanjihub.fpgainstrument.ui.theme.LocalStatusColors
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.theme.MiuixTheme

/**
 * 蓝牙权限请求弹窗，复用 `WindowDialog + TextButton` 布局。
 *
 * 说明页负责解释和触发；系统授权框由 ActivityResultContracts 拉起。
 */
@Composable
fun BlePermissionDialog(controller: BlePermissionController) {
    val status = controller.status
    BlePermissionDialogContent(
        show = controller.dialogVisible && status != BlePermissionStatus.Granted,
        status = status,
        items = controller.items,
        onConfirm = {
            if (status == BlePermissionStatus.Blocked) {
                controller.openSettings()
            } else {
                controller.allow()
            }
        },
        onDismiss = controller::dismissDialog,
        onOpenSettings = controller::openSettings,
    )
}

@Composable
fun BlePermissionDialogContent(
    show: Boolean,
    status: BlePermissionStatus,
    items: List<BlePermissionItem>,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val appName = stringResource(R.string.app_name)
    val packageName = LocalContext.current.packageName
    val title = when (status) {
        BlePermissionStatus.Missing -> "允许使用蓝牙？"
        BlePermissionStatus.Denied -> "蓝牙权限被拒绝"
        BlePermissionStatus.Blocked -> "蓝牙权限已被阻止"
        BlePermissionStatus.Granted -> "蓝牙权限已授予"
    }
    val summary = when (status) {
        BlePermissionStatus.Missing ->
            "$appName 需要“附近的设备”权限，才能扫描并连接 stage-1 设备。"
        BlePermissionStatus.Denied ->
            "扫描不会开始。你可以再允许一次；如果系统不再弹窗，请到应用设置中手动开启。"
        BlePermissionStatus.Blocked ->
            "系统不再弹出授权框。请到应用设置手动允许“附近的设备”，再返回本页。"
        BlePermissionStatus.Granted ->
            "权限已就绪，可以扫描 FPGA-BLE-N07。"
    }
    val confirmText = when (status) {
        BlePermissionStatus.Missing -> "允许"
        BlePermissionStatus.Denied -> "重试"
        BlePermissionStatus.Blocked -> "打开设置"
        BlePermissionStatus.Granted -> "知道了"
    }

    ConfirmDialog(
        show = show,
        title = title,
        summary = summary,
        confirmText = confirmText,
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(MiuixTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.Bluetooth,
                    contentDescription = null,
                    tint = MiuixTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(24.dp),
                )
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column {
                Text(
                    text = appName,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = packageName,
                    fontSize = 12.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }

        Spacer(modifier = Modifier.height(18.dp))
        Text(
            text = "请求的权限",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
        )
        Spacer(modifier = Modifier.height(4.dp))
        items.forEach { item ->
            PermissionRow(item)
        }

        HorizontalDivider(
            modifier = Modifier.padding(vertical = 8.dp),
            thickness = 1.dp,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Rounded.LocationOff,
                contentDescription = null,
                tint = LocalStatusColors.current.okGraphic,
                modifier = Modifier.size(20.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(text = "不用于推断位置", fontSize = 13.sp, fontWeight = FontWeight.Medium)
                Text(
                    text = "Android 12+ 已声明 neverForLocation；只在前台扫描。",
                    fontSize = 12.sp,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
            }
        }

        if (status == BlePermissionStatus.Denied) {
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = "改为在应用设置中开启",
                fontSize = 13.sp,
                color = MiuixTheme.colorScheme.primary,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onOpenSettings)
                    .padding(vertical = 8.dp),
            )
        }

        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = "权限仅用于扫描、连接和读写已验 stage-1 服务；不会后台扫描，也不会把蓝牙用于定位。",
            fontSize = 12.sp,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
        )
    }
}

@Composable
private fun PermissionRow(item: BlePermissionItem) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = if (item.granted) Icons.Rounded.CheckCircle else Icons.Rounded.Lock,
            contentDescription = null,
            tint = if (item.granted) {
                LocalStatusColors.current.okGraphic
            } else {
                MiuixTheme.colorScheme.onSurfaceSecondary
            },
            modifier = Modifier.size(20.dp),
        )
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(text = item.title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(
                text = item.summary,
                fontSize = 12.sp,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = if (item.granted) "已授予" else "待授予",
            fontSize = 12.sp,
            color = if (item.granted) {
                LocalStatusColors.current.okGraphic
            } else {
                MiuixTheme.colorScheme.onSurfaceVariantSummary
            },
        )
    }
}
