package com.aaris.quran.core;

import java.text.Normalizer;
import java.util.*;

/** Search shadows only. Never pass any of these strings to the scripture renderer. */
public final class Arabic {
    private Arabic() {}
    public static String safe(String input) {
        String text = Normalizer.normalize(input == null ? "" : input, Normalizer.Form.NFC);
        StringBuilder out = new StringBuilder();
        text.codePoints().forEach(cp -> {
            int type = Character.getType(cp);
            if ((cp >= 0x610 && cp <= 0x61A) || (cp >= 0x64B && cp <= 0x65F) || cp == 0x670 ||
                (cp >= 0x6D6 && cp <= 0x6ED) || cp == 0x640) return;
            if (cp == 0x671) cp = 0x627;
            if (Character.isLetterOrDigit(cp) || type == Character.NON_SPACING_MARK ||
                type == Character.COMBINING_SPACING_MARK) out.appendCodePoint(Character.toLowerCase(cp));
            else out.append(' ');
        });
        return out.toString().trim().replaceAll("\\s+", " ");
    }
    public static String tolerant(String input) {
        return safe(input).replace('أ','ا').replace('إ','ا').replace('آ','ا')
            .replace('ى','ي').replace('ی','ي').replace('ک','ك');
        // Deliberately do not collapse ta marbuta to ha or delete negation.
    }
    public static List<String> tokens(String text) {
        String s = safe(text);
        return s.isEmpty() ? Collections.emptyList() : Arrays.asList(s.split(" "));
    }
    /** Fold Latin pronunciation accents only; Hindi/Urdu vowel signs keep their meaning. */
    public static String glossSearch(String input) {
        String decomposed=Normalizer.normalize(input==null?"":input,Normalizer.Form.NFD);
        StringBuilder out=new StringBuilder();boolean latin=false;
        for(int offset=0;offset<decomposed.length();) {
            int cp=decomposed.codePointAt(offset);offset+=Character.charCount(cp);
            int type=Character.getType(cp);
            boolean mark=type==Character.NON_SPACING_MARK||type==Character.COMBINING_SPACING_MARK;
            if(mark&&latin)continue;
            if(!mark)latin=Character.UnicodeScript.of(cp)==Character.UnicodeScript.LATIN;
            out.appendCodePoint(cp);
        }
        return tolerant(Normalizer.normalize(out,Normalizer.Form.NFC));
    }
    public static boolean hasArabic(String text) {
        return text.codePoints().anyMatch(c -> c >= 0x620 && c <= 0x6ff);
    }
    public static String asciiDigits(String input) {
        StringBuilder b = new StringBuilder();
        input.codePoints().forEach(c -> { int d = Character.digit(c, 10); if (d >= 0) b.append(d); else b.appendCodePoint(c); });
        return b.toString();
    }
    public static Set<String> trigrams(String input) {
        String text = "^" + input + "$";
        Set<String> set = new HashSet<>();
        if (text.length() < 3) { set.add(text); return set; }
        for (int i = 0; i + 3 <= text.length(); i++) set.add(text.substring(i, i+3));
        return set;
    }
    public static int editDistance(String a, String b, int limit) {
        if (Math.abs(a.length()-b.length()) > limit) return limit+1;
        int[] prev = new int[b.length()+1], next = new int[b.length()+1];
        for (int j=0;j<prev.length;j++) prev[j]=j;
        for (int i=1;i<=a.length();i++) {
            next[0]=i; int minimum=i;
            for (int j=1;j<=b.length();j++) {
                next[j]=Math.min(Math.min(next[j-1]+1,prev[j]+1),prev[j-1]+(a.charAt(i-1)==b.charAt(j-1)?0:1));
                minimum=Math.min(minimum,next[j]);
            }
            if (minimum>limit) return limit+1;
            int[] swap=prev;prev=next;next=swap;
        }
        return prev[b.length()];
    }
}
