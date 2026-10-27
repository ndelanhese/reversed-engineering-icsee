package io.github.ndelanhese.reversedicsee

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import android.widget.Button
import android.widget.DatePicker
import android.widget.ScrollView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 29)
class RecordingsCalendarTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun views(root: View): List<View> = listOf(root) +
        if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
    private fun roots() = WindowInspector.getGlobalWindowViews()
    private fun awaitUi(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 6000
        var ready = false
        while (!ready && System.currentTimeMillis() < deadline) {
            instrumentation.runOnMainSync { ready = condition() }
            if (!ready) Thread.sleep(50)
        }
        assertTrue("UI condition did not become true", ready)
    }

    @Test fun landscapeCalendarCanScrollToAndSelectLastDay() {
        DvripPeer(calendarMask = Int.MAX_VALUE).use { peer ->
            val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            try {
                instrumentation.runOnMainSync { activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
                awaitUi { activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
                instrumentation.runOnMainSync { activity.navigate(RecordingsScreen(activity, peer.camera, Credentials("fixture", "synthetic"))) }
                awaitUi { views(activity.window.decorView).filterIsInstance<Button>().any { it.text.toString().matches(Regex("\\d{4}-\\d{2}-\\d{2}")) } }
                instrumentation.runOnMainSync {
                    views(activity.window.decorView).filterIsInstance<Button>().first { it.text.toString().matches(Regex("\\d{4}-\\d{2}-\\d{2}")) }.performClick()
                }
                awaitUi { roots().any { views(it).any { view -> view is DatePicker } } }
                instrumentation.runOnMainSync {
                    val dialog = roots().first { views(it).any { view -> view is DatePicker } }
                    views(dialog).filterIsInstance<DatePicker>().first().updateDate(2026, 9, 1)
                    dialog.findViewById<Button>(android.R.id.button1).performClick()
                }
                awaitUi { views(activity.window.decorView).filterIsInstance<Button>().any { it.text == "2026-10-01" } }
                instrumentation.runOnMainSync {
                    views(activity.window.decorView).filterIsInstance<Button>().first { it.text == activity.getString(R.string.choose_date) }.performClick()
                }
                awaitUi { roots().any { views(it).filterIsInstance<Button>().any { button -> button.text == "31 •" && button.isLaidOut && button.width > 0 } } }
                instrumentation.runOnMainSync {
                    val dialog = roots().first { views(it).filterIsInstance<Button>().any { button -> button.text == "31 •" } }
                    val last = views(dialog).filterIsInstance<Button>().first { it.text == "31 •" }
                    val scroll = generateSequence(last.parent) { it.parent }.filterIsInstance<ScrollView>().first()
                    scroll.scrollTo(0, scroll.getChildAt(0).height)
                    val visible = Rect()
                    assertTrue("Last calendar day is not visible after scrolling", last.getGlobalVisibleRect(visible) && visible.height() >= activity.dp(48))
                    last.performClick()
                }
                awaitUi { views(activity.window.decorView).filterIsInstance<Button>().any { it.text == "2026-10-31" } }
            } finally { instrumentation.runOnMainSync { activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED; activity.finish() } }
        }
    }
}
