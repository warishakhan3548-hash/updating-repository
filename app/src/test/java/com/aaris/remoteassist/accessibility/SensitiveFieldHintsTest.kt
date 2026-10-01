package com.aaris.remoteassist.accessibility

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SensitiveFieldHintsTest {
    @Test
    fun detectsCommonCredentialIdentifiers() {
        assertTrue(
            SensitiveFieldHints.isSensitive(
                "com.example:id/otp_input"
            )
        )
        assertTrue(
            SensitiveFieldHints.isSensitive(
                "verificationCode"
            )
        )
        assertTrue(
            SensitiveFieldHints.isSensitive(
                "password_field"
            )
        )
        assertTrue(
            SensitiveFieldHints.isSensitive(
                "upi_pin"
            )
        )
        assertTrue(
            SensitiveFieldHints.isSensitive(
                "cardCvv"
            )
        )
        assertTrue(
            SensitiveFieldHints.isSensitive(
                "Enter PIN"
            )
        )
    }

    @Test
    fun doesNotTreatPostalPinAsCredentialByMetadataAlone() {
        assertFalse(
            SensitiveFieldHints.isSensitive(
                "Postal PIN code"
            )
        )
        assertFalse(
            SensitiveFieldHints.isSensitive(
                "shipping_pin"
            )
        )
    }
}
