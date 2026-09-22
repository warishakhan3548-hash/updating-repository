package com.aaris.quran.core;

/** A directed learning edge, never a new or concatenated scripture record. */
public final class AyahTransition {
    public final String id;
    public final Ayah from,to;
    public final SourceText.Range ending,opening;
    public AyahTransition(Ayah from,Ayah to) {
        if(from==null||to==null||from.surah!=to.surah||to.number!=from.number+1||to.ordinal!=from.ordinal+1)
            throw new IllegalArgumentException("Only consecutive ayahs in the same surah");
        this.from=from;this.to=to;id=RecallTarget.transition(from.id,to.number);
        SourceText a=new SourceText(from.arabic),b=new SourceText(to.arabic);
        if(a.tokens.isEmpty()||b.tokens.isEmpty())throw new IllegalArgumentException("Missing source words");
        ending=a.range(Math.max(0,a.tokens.size()-3),a.tokens.size());
        opening=b.range(0,Math.min(3,b.tokens.size()));
    }
}
