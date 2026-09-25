package com.aaris.quran.core;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** One search box; explicit references select their corpus before any text retrieval. */
public final class UnifiedQuery {
    public static final int ALL=0,QURAN=1,HADITH=2;
    private static final Pattern QURAN_COORDINATE=Pattern.compile(
        "^(?:Q\\s*:?\\s*)?([0-9]{1,3})\\s*(?::|/|\\.|\\s+)\\s*([0-9]{1,3})$",Pattern.CASE_INSENSITIVE);
    public final boolean quran,hadith;
    public final String quranText;
    public final HadithQuery hadithQuery;
    private UnifiedQuery(boolean quran,boolean hadith,String text,HadithQuery query){
        this.quran=quran;this.hadith=hadith;quranText=text;hadithQuery=query;
    }
    public static UnifiedQuery parse(String raw,int scope){
        String text=raw==null?"":raw.trim();
        // Long pasted text is free-form evidence. Avoid normalizing the whole paragraph on the
        // UI thread; the Quran/Hadith workers run bounded LongQuery planning in the background.
        if(text.length()>LongQuery.SHORT_CHARS){
            HadithQuery h=HadithQuery.parse("");
            if(scope==QURAN)return new UnifiedQuery(true,false,text,h);
            if(scope==HADITH)return new UnifiedQuery(false,true,text,h);
            return new UnifiedQuery(true,true,text,h);
        }
        String q=Arabic.asciiDigits(text).replace('：',':')
            .replaceFirst("(?iu)^(?:quran|qur'an|कुरान|क़ुरआन|قرآن|القرآن)\\s*[:\\-]?\\s*","");
        Matcher coordinate=QURAN_COORDINATE.matcher(q);
        boolean quranCoordinate=coordinate.matches();
        String quranText=q;
        if(quranCoordinate)
            quranText=Integer.parseInt(coordinate.group(1))+":"+Integer.parseInt(coordinate.group(2));

        HadithQuery h=HadithQuery.parse(text);
        if(scope==QURAN)return new UnifiedQuery(true,false,quranText,h);
        if(scope==HADITH)return new UnifiedQuery(false,true,quranText,h);
        if(quranCoordinate)return new UnifiedQuery(true,false,quranText,h);
        if(h.isHadithIntent())return new UnifiedQuery(false,true,quranText,h);
        return new UnifiedQuery(true,true,quranText,h);
    }
}
