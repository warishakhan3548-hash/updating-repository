package com.aaris.quran.core;

/** One search box; explicit references select their corpus before any text retrieval. */
public final class UnifiedQuery {
    public static final int ALL=0,QURAN=1,HADITH=2;
    public final boolean quran,hadith;
    public final String quranText;
    public final HadithQuery hadithQuery;
    private UnifiedQuery(boolean quran,boolean hadith,String text,HadithQuery query){
        this.quran=quran;this.hadith=hadith;quranText=text;hadithQuery=query;
    }
    public static UnifiedQuery parse(String raw,int scope){
        String text=raw==null?"":raw.trim();
        HadithQuery h=HadithQuery.parse(text);
        String q=Arabic.asciiDigits(text).replace('：',':')
            .replaceFirst("(?iu)^(?:quran|qur'an|कुरान|क़ुरआन|قرآن|القرآن)\\s+","");
        boolean coordinate=q.matches("(?i)(?:Q:)?[0-9]{1,3}\\s*:\\s*[0-9]{1,3}");
        if(h.isHadithIntent())return new UnifiedQuery(false,true,q,h);
        if(coordinate)return new UnifiedQuery(true,false,q,h);
        return new UnifiedQuery(scope!=HADITH,scope!=QURAN,q,h);
    }
}
