package local.foodjournal.food_journal

import android.app.Activity
import android.content.Intent
import android.os.Bundle

class ShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 静态快捷方式会清除目标任务，先经独立的临时任务转发，保留现有 Flutter 页面和草稿。
        startActivity(Intent(this, MainActivity::class.java).apply {
            action = intent.action
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP)
        })
        finish()
    }
}
