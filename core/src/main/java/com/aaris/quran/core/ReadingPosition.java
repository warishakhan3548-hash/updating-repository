package com.aaris.quran.core;

/** Portable viewport anchor. Unicode location survives a different font size or line wrap. */
public final class ReadingPosition {
    public final String pageId,anchorId;
    public final int codePoint;
    public final float lineOffsetDp;
    public final boolean atTop;
    public ReadingPosition(String pageId,String anchorId,int codePoint,float lineOffsetDp,boolean atTop) {
        RecallTarget page=RecallTarget.parse(pageId),anchor=RecallTarget.parse(anchorId);
        if(page==null||anchor==null||page.kind!=RecallTarget.Kind.AYAH||anchor.kind!=RecallTarget.Kind.AYAH||
            page.surah!=anchor.surah||anchor.ayah<page.ayah||anchor.ayah>=page.ayah+8||codePoint<0||
            codePoint>30000||!Float.isFinite(lineOffsetDp)||Math.abs(lineOffsetDp)>10000)
            throw new IllegalArgumentException("Invalid reading position");
        this.pageId=pageId;this.anchorId=anchorId;this.codePoint=codePoint;this.lineOffsetDp=lineOffsetDp;this.atTop=atTop;
    }
    public String encode(){return pageId+"|"+anchorId+"|"+codePoint+"|"+lineOffsetDp+"|"+(atTop?"1":"0");}
    public static ReadingPosition parse(String encoded) {
        if(encoded==null||encoded.length()>100)return null;
        String[] p=encoded.split("\\|",-1);if(p.length!=5||(!p[4].equals("0")&&!p[4].equals("1")))return null;
        try{return new ReadingPosition(p[0],p[1],Integer.parseInt(p[2]),Float.parseFloat(p[3]),p[4].equals("1"));}
        catch(IllegalArgumentException invalid){return null;}
    }
}
