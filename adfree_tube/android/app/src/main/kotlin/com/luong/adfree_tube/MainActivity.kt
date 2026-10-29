package com.luong.adfree_tube

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.luong.adfree_tube.downloads.DownloadsChannel

class MainActivity : AudioServiceActivity() {
    private val handler = Handler(Looper.getMainLooper())

    /** Turned off only by the background-playback CI test, to measure the bug. */
    private var keepPlaying = true

    // Workaround (bug 10 in the README "Known bugs and workarounds"): when the
    // app goes to the background or the screen turns off, Android tells the
    // WebView its window is hidden. Chromium then treats the page as hidden,
    // pauses the <video> (sound included), and lets the WebView's renderer
    // process drop to a low priority that Android freezes. So while the app
    // is in the background, keep telling every WebView it's still visible,
    // keep its timers running, and keep its renderer as important as the app
    // itself (which audio_service's foreground service keeps alive).
    private var stopped = false
    private val keepAwakeLoop = object : Runnable {
        override fun run() {
            if (!stopped || !keepPlaying) return
            keepWebViewsAwake()
            handler.postDelayed(this, 2000)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "adfree_tube/background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepPlaying" -> {
                        keepPlaying = call.arguments as Boolean
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        DownloadsChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onStart() {
        super.onStart()
        stopped = false
        handler.removeCallbacks(keepAwakeLoop)
    }

    override fun onStop() {
        super.onStop()
        stopped = true
        // The hidden-window notice reaches the WebView after onStop, during
        // a later layout pass, so answer it right away and then every two
        // seconds for as long as the app stays in the background.
        handler.removeCallbacks(keepAwakeLoop)
        handler.post(keepAwakeLoop)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun keepWebViewsAwake() {
        for (webView in findWebViews(window.decorView)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                webView.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
            }
            webView.dispatchWindowVisibilityChanged(View.VISIBLE)
            webView.onResume()
            webView.resumeTimers()
        }
    }

    private fun findWebViews(view: View): List<WebView> = when (view) {
        is WebView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { findWebViews(view.getChildAt(it)) }
        else -> emptyList()
    }
}
