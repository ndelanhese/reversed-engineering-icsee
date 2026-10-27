package io.github.ndelanhese.reversedicsee

import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.EditText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DiscoveryUiTest {
    private fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()

    @Test fun permissionResultBeforeResumeDoesNotStartWorkInPausedScreen() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        var invoked = false
        try {
            instrumentation.runOnMainSync {
                instrumentation.callActivityOnPause(activity)
                MainActivity::class.java.getDeclaredField("pendingNetworkAction").apply { isAccessible = true }.set(activity, { invoked = true })
                activity.onRequestPermissionsResult(100, arrayOf("android.permission.ACCESS_LOCAL_NETWORK"), intArrayOf(android.content.pm.PackageManager.PERMISSION_GRANTED))
                assertFalse("Permission result started networking before resume", invoked)
                instrumentation.callActivityOnResume(activity)
                assertTrue("Granted network action was lost on resume", invoked)
                invoked = false
                instrumentation.callActivityOnPause(activity)
                instrumentation.callActivityOnResume(activity)
                assertFalse("Granted network action ran twice", invoked)
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }

    @Test fun discoveryReleasesMulticastLockOnStopAndBackgroundWithoutAutomaticRescan() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val manager = context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        org.junit.Assume.assumeTrue("Connected Wi-Fi required", manager.allNetworks.any { manager.getNetworkCapabilities(it)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true })
        val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val activity = instrumentation.startActivitySync(intent) as MainActivity
        val discovery = DiscoveryScreen(activity)
        fun lock(): android.net.wifi.WifiManager.MulticastLock? = DiscoveryScreen::class.java.getDeclaredField("lock").apply { isAccessible = true }.get(discovery) as? android.net.wifi.WifiManager.MulticastLock
        fun button(label: Int) = views(activity.window.decorView).filterIsInstance<android.widget.Button>().first { it.text == activity.getString(label) }
        try {
            instrumentation.runOnMainSync {
                activity.navigate(discovery)
                val first = lock()
                assertNotNull("Scan did not acquire its multicast lock", first)
                assertTrue(first!!.isHeld)
                button(R.string.stop_scan).performClick()
                assertFalse("Stop retained the Wi-Fi multicast lock", first.isHeld)
                assertTrue(button(R.string.search_again).isEnabled)
                button(R.string.search_again).performClick()
                assertTrue(lock()!!.isHeld)
            }
            var activeLock: android.net.wifi.WifiManager.MulticastLock? = null
            instrumentation.runOnMainSync {
                activeLock = lock()
                activity.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            instrumentation.waitForIdleSync()
            val deadline = System.currentTimeMillis() + 3000
            while (activeLock!!.isHeld && System.currentTimeMillis() < deadline) Thread.sleep(50)
            assertFalse("Background retained the Wi-Fi multicast lock", activeLock!!.isHeld)
            context.startActivity(intent)
            var foreground = false
            val resumeDeadline = System.currentTimeMillis() + 3000
            while (!foreground && System.currentTimeMillis() < resumeDeadline) {
                instrumentation.runOnMainSync {
                    foreground = activity.hasWindowFocus() && androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance().getLifecycleStageOf(activity) == androidx.test.runner.lifecycle.Stage.RESUMED
                }
                if (!foreground) Thread.sleep(50)
            }
            assertTrue("Activity did not return to foreground", foreground)
            instrumentation.runOnMainSync {
                assertNull("Resuming silently restarted discovery", lock())
                assertTrue(button(R.string.search_again).isEnabled)
                assertFalse(button(R.string.stop_scan).isEnabled)
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }

    @androidx.test.filters.SdkSuppress(minSdkVersion = 29)
    @android.annotation.TargetApi(29)
    @Test fun detectedCameraUsesAdvertisedAddressAndKeepsAdvancedFieldsCollapsed() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        val original = activity.profiles.toList()
        try {
            instrumentation.runOnMainSync {
                val detected = CameraProfile.fromDiscovery(org.json.JSONObject("{\"name\":\"Discovered fixture\",\"host\":\"192.0.2.56\",\"port\":554,\"controlPort\":34567,\"onvifPort\":8000}"))
                activity.editCamera(discovered = detected)
            }
            // Native dialog windows are separate from the Activity decor view.
            instrumentation.runOnMainSync {
                val roots = android.view.inspector.WindowInspector.getGlobalWindowViews()
                val root = roots.first { views(it).filterIsInstance<EditText>().any { field -> field.text.toString() == "Discovered fixture" } }
                val fields = views(root).filterIsInstance<EditText>()
                assertEquals(listOf("Discovered fixture", "192.0.2.56", "554", "34567", "8000", "1"), fields.map { it.text.toString() })
                assertTrue(fields.take(2).all { it.isShown })
                assertTrue(fields.drop(2).none { it.isShown })
                val advanced = views(root).filterIsInstance<CheckBox>().first { it.text.toString() == activity.getString(R.string.advanced) }
                advanced.performClick()
                assertTrue(fields.all { it.isShown })
                root.findViewById<android.widget.Button>(android.R.id.button1).performClick()
                val saved = activity.profiles.last()
                assertEquals("192.0.2.56", saved.host)
                assertEquals(8000, saved.onvifPort)
                assertEquals(original.size + 1, activity.profiles.size)
            }
        } finally {
            instrumentation.runOnMainSync { activity.profiles = original; activity.persist(); activity.finish() }
        }
    }
}
