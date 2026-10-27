package io.github.ndelanhese.reversedicsee

import org.junit.Assert.*
import org.junit.Test

class CameraProfileTest {
    @Test fun profileRoundTripPreservesIdentityAndCustomPorts() {
        val p = CameraProfile(name = "Front door", host = "192.0.2.10", port = 8554, channel = 2)
        assertTrue(p.valid())
        assertEquals(p, CameraProfile.fromJson(p.json()))
        assertFalse(p.json().has("password"))
    }
    @Test fun profileRejectsPathsEmptyNamesAndInvalidRanges() {
        val p = CameraProfile(name = "Front door", host = "camera.test")
        assertTrue(p.valid())
        for (bad in listOf(p.copy(host = "camera/evil"), p.copy(name = ""), p.copy(port = 0), p.copy(channel = 65), p.copy(controlPort = 65536))) assertFalse(bad.valid())
    }
    @Test fun discoveryPrefillsProfileWithoutCredentials() {
        val result = org.json.JSONObject().put("name", "Garage").put("host", "192.168.0.116").put("port", 554).put("controlPort", 34567).put("onvifPort", 8899)
        val camera = CameraProfile.fromDiscovery(result)
        assertTrue(camera.valid())
        assertEquals("Garage", camera.name)
        assertEquals("192.168.0.116", camera.host)
        assertEquals(8899, camera.onvifPort)
        assertEquals(554, camera.port)
        assertEquals(34567, camera.controlPort)
        assertEquals(1, camera.channel)
        assertTrue(camera.substream)
        assertFalse(camera.json().has("password"))
    }
    @Test fun discoveryRejectsMalformedResults() {
        val result = org.json.JSONObject().put("name", "Camera").put("host", "192.168.0.116").put("port", 554).put("controlPort", 34567).put("onvifPort", 8899)
        for (bad in listOf(result.toString().replace("192.168.0.116", "https://example.com"), result.toString().replace("8899", "0"), result.toString().replace("192.168.0.116", "999.1.1.1"))) {
            assertThrows(Exception::class.java) { CameraProfile.fromDiscovery(org.json.JSONObject(bad)) }
        }
    }
}
