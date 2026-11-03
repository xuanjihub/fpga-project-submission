package com.xuanjihub.fpgainstrument.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.window.WindowDialog

/** 通用确认弹窗。 */
@Composable
fun ConfirmDialog(
    show: Boolean,
    title: String,
    summary: String? = null,
    confirmText: String,
    dismissText: String = "取消",
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    WindowDialog(
        show = show,
        title = title,
        summary = summary,
        onDismissRequest = onDismiss,
    ) {
        Column {
            content()
            Spacer(modifier = Modifier.height(20.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                TextButton(
                    text = dismissText,
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f),
                )
                Spacer(modifier = Modifier.width(20.dp))
                TextButton(
                    text = confirmText,
                    onClick = onConfirm,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.textButtonColorsPrimary(),
                )
            }
        }
    }
}
