package io.github.noice912.richpresence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RetryTest {
    @Test fun waitsLongerEachTimeThenEveryTenMinutes() {
        assertEquals(5_000L, Retry.delayMs(0))
        assertEquals(30_000L, Retry.delayMs(1))
        assertEquals(120_000L, Retry.delayMs(2))
        assertEquals(600_000L, Retry.delayMs(3))
        assertEquals(600_000L, Retry.delayMs(4))
        assertEquals(600_000L, Retry.delayMs(1_000_000))
    }

    @Test fun aNegativeAttemptIsTreatedAsTheFirst() {
        assertEquals(5_000L, Retry.delayMs(-1))
    }

    @Test fun theLogOnlyPresenceNeverAsksForTheAppToBeOpened() {
        assertFalse(LogOnlyPresence().needsApp)
    }
}
