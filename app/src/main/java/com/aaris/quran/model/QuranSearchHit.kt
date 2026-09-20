package com.aaris.quran.model

enum class QuranSearchMatchKind {
    STRICT,
    COMPATIBILITY,
}

data class QuranSearchHit(
    val ayah: QuranAyah,
    val matchKind: QuranSearchMatchKind,
) {
    val isApproximate: Boolean
        get() = matchKind == QuranSearchMatchKind.COMPATIBILITY
}
