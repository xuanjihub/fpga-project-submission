package com.xuanjihub.fpgainstrument

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.xuanjihub.fpgainstrument.ui.AppRoot

/**
 * 入口。
 *
 * 三个页面（连接 / 乐器 / 诊断）展示 stage-1 协议数据。
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AppRoot()
        }
    }
}
