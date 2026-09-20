package com.aaris.quran.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SurfaceTapAnchorResolverTest {
    @Test
    fun resolvesSameNonWhitespaceSpansAsReaderContract() {
        val text = "أ ب  ج"
        val first = SurfaceTapAnchorResolver.resolve("qa:001:001", text, 0)
        val second = SurfaceTapAnchorResolver.resolve("qa:001:001", text, 2)
        val third = SurfaceTapAnchorResolver.resolve("qa:001:001", text, 5)

        assertEquals("أ", first?.surface)
        assertEquals("ui-surface:qa:001:001:001", first?.anchorId)
        assertEquals("ب", second?.surface)
        assertEquals(2, second?.ordinal)
        assertEquals("ج", third?.surface)
        assertEquals(3, third?.ordinal)
    }

    @Test
    fun whitespaceDoesNotBecomeAWordAnchor() {
        assertNull(SurfaceTapAnchorResolver.resolve("qa:001:001", "أ ب", 1))
    }

    @Test
    fun diacriticsRemainInsideTheVisualSurfaceWithoutClaimingMorphology() {
        val text = "بِسْمِ اللَّهِ"
        val anchor = SurfaceTapAnchorResolver.resolve("qa:001:001", text, 1)

        assertEquals("بِسْمِ", anchor?.surface)
        assertEquals(0, anchor?.start)
        assertEquals(6, anchor?.end)
    }
}
