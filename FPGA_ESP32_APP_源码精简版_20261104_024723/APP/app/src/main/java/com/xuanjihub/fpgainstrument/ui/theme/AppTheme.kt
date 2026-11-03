package com.xuanjihub.fpgainstrument.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import top.yukonga.miuix.kmp.theme.ColorSchemeMode
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.ThemeController

/**
 * 语义状态色（正常 / 提示 / 错误）。
 *
 * MIUIX 的 ColorScheme 提供主题色（primary/secondary/tertiary/error 等），
 * 成功绿、警示黄这类语义槽位在这里统一定义。
 */
data class StatusColors(
    val okContainer: Color,
    val okGraphic: Color,
    val noticeContainer: Color,
    val onNoticeContainer: Color,
    val errorContainer: Color,
    val onErrorContainer: Color,
)

private val LightStatusColors = StatusColors(
    okContainer = Color(0xFFDFFAE4),
    okGraphic = Color(0xFF36D167),
    noticeContainer = Color(0xFFFFF0DB),
    onNoticeContainer = Color(0xFF8A6100),
    errorContainer = Color(0xFFF8E2E2),
    onErrorContainer = Color(0xFF8A1F1F),
)

private val DarkStatusColors = StatusColors(
    okContainer = Color(0xFF1A3825),
    okGraphic = Color(0xFF36D167),
    noticeContainer = Color(0xFF3E2F1B),
    onNoticeContainer = Color(0xFFE8C87A),
    errorContainer = Color(0xFF310808),
    onErrorContainer = Color(0xFFE8A0A0),
)

val LocalStatusColors = staticCompositionLocalOf { LightStatusColors }

/**
 * MIUIX 主题入口。
 *
 * 主题集中在这一层，页面只使用 MiuixTheme 的颜色/字体。
 */
@Composable
fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    MiuixTheme(
        controller = ThemeController(ColorSchemeMode.System),
        content = {
            CompositionLocalProvider(
                LocalStatusColors provides if (dark) DarkStatusColors else LightStatusColors,
                content = content,
            )
        },
    )
}
