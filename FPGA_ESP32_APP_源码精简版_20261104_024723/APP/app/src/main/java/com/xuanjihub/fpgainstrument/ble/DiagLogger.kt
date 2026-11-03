package com.xuanjihub.fpgainstrument.ble

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class DiagLine(
    val time: String,
    val level: String,
    val tag: String,
    val message: String,
) {
    val display: String get() = "$time $level/$tag $message"
}

/**
 * Persistent BLE log. Writes to app-specific external storage so the file can be
 * shared from the diagnostic page.
 */
class DiagLogger(context: Context) {
    private val appContext = context.applicationContext
    private val clock = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val fileClock = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
    private val lock = Any()

    private val logDir: File = run {
        val base = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        File(base, "logs").also { it.mkdirs() }
    }
    val file: File = File(logDir, "ble-${fileClock.format(Date())}.log")

    private val _lines = MutableSharedFlow<DiagLine>(replay = 300, extraBufferCapacity = 300)
    val lines: SharedFlow<DiagLine> = _lines.asSharedFlow()

    init {
        writeHeader()
    }

    private fun writeHeader() {
        val packageInfo = runCatching {
            appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        }.getOrNull()
        val version = packageInfo?.versionName ?: "?"
        val code = packageInfo?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode else @Suppress("DEPRECATION") it.versionCode.toLong()
        } ?: -1L
        val scan = permissionState(Manifest.permission.BLUETOOTH_SCAN)
        val connect = permissionState(Manifest.permission.BLUETOOTH_CONNECT)
        val body = buildString {
            appendLine("==== FPGA Instrument BLE log ====")
            appendLine("started=${Date()}")
            appendLine("package=${appContext.packageName} version=$version ($code)")
            appendLine("android=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}")
            appendLine("device=${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})")
            appendLine("permissions: BLUETOOTH_SCAN=$scan BLUETOOTH_CONNECT=$connect")
            appendLine("note: INFO only proves the ESP32 bridge; GET_STATE proves the FPGA link")
            appendLine("----")
        }
        synchronized(lock) { runCatching { file.appendText(body) } }
        _lines.tryEmit(DiagLine(clock.format(Date()), "I", "APP", "log file: ${file.absolutePath}"))
        Log.i(TAG, "log file: ${file.absolutePath}")
    }

    fun d(tag: String, message: String) = log("D", tag, message, null)
    fun i(tag: String, message: String) = log("I", tag, message, null)
    fun w(tag: String, message: String, error: Throwable? = null) = log("W", tag, message, error)
    fun e(tag: String, message: String, error: Throwable? = null) = log("E", tag, message, error)

    private fun log(level: String, tag: String, message: String, error: Throwable?) {
        val time = clock.format(Date())
        val line = "$time $level/$tag $message"
        val stack = error?.let { Log.getStackTraceString(it) }
        synchronized(lock) {
            runCatching {
                file.appendText(line + "\n")
                if (stack != null) file.appendText(stack + "\n")
            }
        }
        Log.println(
            when (level) {
                "E" -> Log.ERROR
                "W" -> Log.WARN
                "I" -> Log.INFO
                else -> Log.DEBUG
            },
            "FpgaBle/$tag",
            message,
        )
        _lines.tryEmit(DiagLine(time, level, tag, message))
    }

    fun snapshot(): String = runCatching { file.readText() }.getOrDefault("")

    val absolutePath: String get() = file.absolutePath

    fun shareIntent(): Intent {
        val uri = FileProvider.getUriForFile(
            appContext,
            "${appContext.packageName}.fileprovider",
            file,
        )
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "FPGA Instrument BLE log")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun permissionState(permission: String): String =
        if (ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED) {
            "granted"
        } else {
            "denied"
        }

    companion object {
        private const val TAG = "FpgaBle"
    }
}
