package com.aaris.quran.core;

import java.util.regex.*;

/** Our own stable coordinates. Phrase bounds refer to immutable source word positions. */
public final class RecallTarget {
    public enum Kind { AYAH, WORD, PREFATORY_WORD, PHRASE }
    private static final Pattern FORMAT=Pattern.compile("^Q:([1-9][0-9]{0,2}):([1-9][0-9]{0,2})(?::(W|B|P):([1-9][0-9]{0,3})(?:-([1-9][0-9]{0,3}))?)?$");
    public final String id,ayahId;
    public final Kind kind;
    public final int surah,ayah,first,last;
    private RecallTarget(String id,int surah,int ayah,Kind kind,int first,int last) {
        this.id=id;this.surah=surah;this.ayah=ayah;this.kind=kind;this.first=first;this.last=last;ayahId="Q:"+surah+":"+ayah;
    }
    public static RecallTarget parse(String id) {
        if(id==null)return null;Matcher m=FORMAT.matcher(id);if(!m.matches())return null;
        int surah=Integer.parseInt(m.group(1)),ayah=Integer.parseInt(m.group(2));if(surah>114||ayah>286)return null;
        if(m.group(3)==null)return new RecallTarget(id,surah,ayah,Kind.AYAH,0,0);
        int first=Integer.parseInt(m.group(4)),last=m.group(5)==null?first:Integer.parseInt(m.group(5));
        switch(m.group(3)) {
            case "W":return first<=1000&&m.group(5)==null?new RecallTarget(id,surah,ayah,Kind.WORD,first,first):null;
            case "B":return first<=4&&m.group(5)==null?new RecallTarget(id,surah,ayah,Kind.PREFATORY_WORD,first,first):null;
            case "P":return first<last&&last<=1000?new RecallTarget(id,surah,ayah,Kind.PHRASE,first,last):null;
            default:return null;
        }
    }
    public static String phrase(String ayahId,int first,int last) {
        String id=ayahId+":P:"+first+"-"+last;RecallTarget target=parse(id);
        if(target==null||target.kind!=Kind.PHRASE)throw new IllegalArgumentException("Invalid phrase range");return id;
    }
}
