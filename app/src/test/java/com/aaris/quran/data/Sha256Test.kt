package com.aaris.quran.data

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Test

class Sha256Test {
    @Test
    fun knownVector() {
        val value = Sha256.of(ByteArrayInputStream("abc".toByteArray()))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", value)
    }
}
