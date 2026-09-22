package com.aaris.quran.core;

import java.util.Objects;

/** Scripture identity belongs to coordinates, never to UI or database row IDs. */
public final class Ayah {
    public final String id, arabic, sha256;
    public final int surah, number, ordinal;
    public Ayah(int surah, int number, String arabic, String sha256, int ordinal) {
        if (surah < 1 || surah > 114 || number < 1 || number > 286) throw new IllegalArgumentException("Coordinate");
        this.id = "Q:" + surah + ":" + number;
        this.surah = surah; this.number = number; this.ordinal = ordinal;
        this.arabic = Objects.requireNonNull(arabic); this.sha256 = Objects.requireNonNull(sha256);
    }
}
