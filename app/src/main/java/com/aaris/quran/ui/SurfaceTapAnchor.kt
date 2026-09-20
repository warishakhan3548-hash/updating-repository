package com.aaris.quran.ui

data class SurfaceTapAnchor(
    val anchorId: String,
    val ayahId: String,
    val ordinal: Int,
    val start: Int,
    val end: Int,
    val surface: String,
)

object SurfaceTapAnchorResolver {
    fun resolve(ayahId: String, text: String, offset: Int): SurfaceTapAnchor? {
        if (text.isEmpty() || offset !in text.indices || text[offset].isWhitespace()) {
            return null
        }

        var start = offset
        while (start > 0 && !text[start - 1].isWhitespace()) start -= 1

        var end = offset + 1
        while (end < text.length && !text[end].isWhitespace()) end += 1

        var ordinal = 0
        var insideSurface = false
        for (index in 0 until start) {
            val nonWhitespace = !text[index].isWhitespace()
            if (nonWhitespace && !insideSurface) ordinal += 1
            insideSurface = nonWhitespace
        }
        ordinal += 1

        return SurfaceTapAnchor(
            anchorId = "ui-surface:$ayahId:%03d".format(ordinal),
            ayahId = ayahId,
            ordinal = ordinal,
            start = start,
            end = end,
            surface = text.substring(start, end),
        )
    }
}
