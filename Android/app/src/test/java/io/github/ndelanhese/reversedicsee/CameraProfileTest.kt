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
}
