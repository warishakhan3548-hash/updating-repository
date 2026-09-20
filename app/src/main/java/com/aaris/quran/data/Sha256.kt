package com.aaris.quran.data

import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.security.MessageDigest

internal object Sha256 {
    fun of(file: File): String = FileInputStream(file).use(::of)

    fun of(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }
}
