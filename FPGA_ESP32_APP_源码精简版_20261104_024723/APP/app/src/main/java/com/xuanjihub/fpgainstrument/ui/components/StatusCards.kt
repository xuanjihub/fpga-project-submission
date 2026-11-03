package com.xuanjihub.fpgainstrument.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.xuanjihub.fpgainstrument.ui.theme.LocalStatusColors
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.utils.PressFeedbackType

/** 卡片通用外边距：间距和页边距取 12dp。 */
private val CardSpacing = Modifier
    .fillMaxWidth()
    .padding(horizontal = 12.dp)
    .padding(bottom = 12.dp)

/** 提示级别。 */
enum class NoticeLevel { Notice, Error }

/**
 * 顶部状态大卡。
 *
 * - 用 `Icons.Rounded.CheckCircleOutline`（带圆环的对勾）
 * - 图标层 `fillMaxSize() + offset(27.dp, 31.dp)`、内容对齐 `BottomEnd`，
 *   110dp 的圆环伸出卡片、由卡片裁掉一角
 * - 文字层用 `padding(16.dp, 14.dp)` 叠在左上角，标题 22sp
 * - 卡片使用默认前景色
 */
@Composable
fun StatusHeroCard(
    headline: String,
    lines: List<String>,
    ok: Boolean,
) {
    val status = LocalStatusColors.current
    Card(
        modifier = CardSpacing,
        colors = CardDefaults.defaultColors(
            color = if (ok) status.okContainer else MiuixTheme.colorScheme.surfaceVariant,
        ),
        pressFeedbackType = PressFeedbackType.None,
        showIndication = false,
    ) {
        Box {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .offset(27.dp, 31.dp),
                contentAlignment = Alignment.BottomEnd,
            ) {
                Icon(
                    modifier = Modifier.size(110.dp),
                    imageVector = if (ok) Icons.Rounded.CheckCircleOutline else Icons.Rounded.ErrorOutline,
                    tint = if (ok) status.okGraphic else MiuixTheme.colorScheme.onSurfaceSecondary,
                    contentDescription = null,
                )
            }
            Column(
                modifier = Modifier.padding(start = 16.dp, top = 14.dp, end = 96.dp, bottom = 14.dp),
            ) {
                Text(
                    text = headline,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                lines.forEach { line ->
                    Spacer(modifier = Modifier.size(4.dp))
                    Text(text = line, fontSize = 15.sp)
                }
            }
        }
    }
}

/**
 * 统计小卡：上面灰色小标题、下面大号粗体数值。
 */
@Composable
fun StatCard(
    title: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier,
        insideMargin = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
        pressFeedbackType = PressFeedbackType.None,
        showIndication = false,
    ) {
        Text(
            text = title,
            fontSize = 13.sp,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
        )
        Spacer(modifier = Modifier.size(6.dp))
        Text(
            text = value,
            fontSize = 26.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/** 一行两张统计卡。 */
@Composable
fun StatRow(
    left: Pair<String, String>,
    right: Pair<String, String>,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(bottom = 12.dp),
    ) {
        StatCard(title = left.first, value = left.second, modifier = Modifier.weight(1f))
        Spacer(modifier = Modifier.width(12.dp))
        StatCard(title = right.first, value = right.second, modifier = Modifier.weight(1f))
    }
}

/**
 * 警示卡：整块低饱和色底 + 粗体标题 + 说明。
 */
@Composable
fun WarningCard(
    headline: String,
    body: String,
    level: NoticeLevel = NoticeLevel.Notice,
    action: (@Composable () -> Unit)? = null,
) {
    val status = LocalStatusColors.current
    val container = when (level) {
        NoticeLevel.Notice -> status.noticeContainer
        NoticeLevel.Error -> status.errorContainer
    }
    val onContainer = when (level) {
        NoticeLevel.Notice -> status.onNoticeContainer
        NoticeLevel.Error -> status.onErrorContainer
    }
    Card(
        modifier = CardSpacing,
        colors = CardDefaults.defaultColors(color = container, contentColor = onContainer),
        insideMargin = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
        pressFeedbackType = PressFeedbackType.None,
        showIndication = false,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = headline,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(modifier = Modifier.size(6.dp))
                Text(text = body, fontSize = 14.sp)
            }
            if (action != null) {
                Spacer(modifier = Modifier.width(12.dp))
                action()
            }
        }
    }
}

/** 说明性小字，用于卡片之间的注解。 */
@Composable
fun PageNote(text: String) {
    Text(
        text = text,
        fontSize = 13.sp,
        color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
        modifier = Modifier.padding(start = 28.dp, end = 28.dp, bottom = 12.dp),
    )
}
