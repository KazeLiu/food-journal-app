package local.foodjournal.food_journal

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var shortcutChannel: MethodChannel? = null
    private var pendingShortcut: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingShortcut = if (savedInstanceState?.containsKey(PENDING_SHORTCUT) == true) {
            savedInstanceState.getString(PENDING_SHORTCUT)
        } else {
            shortcutFrom(intent)
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shortcutChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "local.foodjournal.app/shortcuts"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "takeShortcut") {
                    val shortcut = pendingShortcut
                    pendingShortcut = null
                    intent.action = Intent.ACTION_MAIN
                    result.success(shortcut)
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val shortcut = shortcutFrom(intent) ?: return
        setIntent(intent)
        pendingShortcut = shortcut
        shortcutChannel?.invokeMethod("shortcutAvailable", null)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        // 已消费的入口也保存为空，避免拍照期间重建 Activity 后再次打开相机。
        outState.putString(PENDING_SHORTCUT, pendingShortcut)
        super.onSaveInstanceState(outState)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shortcutChannel?.setMethodCallHandler(null)
        shortcutChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun shortcutFrom(intent: Intent): String? = when (intent.action) {
        "local.foodjournal.app.action.RECORD_WEIGHT" -> "record_weight"
        "local.foodjournal.app.action.QUICK_CAMERA" -> "quick_camera"
        else -> null
    }

    companion object {
        private const val PENDING_SHORTCUT = "food_journal.pending_shortcut"
    }
}
