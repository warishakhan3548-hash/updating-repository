package com.aaris.quran;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Shader;
import android.text.Layout;
import android.text.TextPaint;
import android.widget.TextView;

/** Shared, single-pass Arabic glass finish. Android still shapes and positions every glyph. */
class ArabicText extends TextView {
    private boolean relief=true;
    private boolean wordHighlighted;
    private Shader face;
    private float cachedSize=-1;
    private int cachedBaseline=-1,cachedAdvance=-1,cachedColor,cachedSheen=-1,cachedSurface,cachedHighlight,cachedFinish=-1,cachedAccent;
    private final float density;

    ArabicText(Context context){
        super(context);density=getResources().getDisplayMetrics().density;
        setTextColor(Glass.ARABIC_INK);
    }
    void setReliefEnabled(boolean enabled){
        relief=enabled;setTextColor(Glass.ARABIC_INK);face=null;invalidate();
    }
    void setWordHighlighted(boolean highlighted){wordHighlighted=highlighted;invalidate();}
    @Override protected void onDraw(Canvas canvas){
        TextPaint paint=getPaint();Layout layout=getLayout();
        // Android uses the glyph paint for BackgroundColorSpan too. Keep a selected ayah
        // plain so the word's green highlight never inherits the ivory shader or shadow.
        Appearance style=Glass.appearance;
        boolean selection=wordHighlighted||getSelectionStart()!=getSelectionEnd();
        boolean effects=relief&&!style.reducedEffects&&!selection;
        if(effects&&style.textFinish!=Appearance.TEXT_PLAIN&&layout!=null&&layout.getLineCount()>0){
            int baseline=layout.getLineBaseline(0);
            int advance=Math.max(1,layout.getLineCount()>1?layout.getLineBaseline(1)-baseline:layout.getLineBottom(0)-layout.getLineTop(0));
            float size=getTextSize();
            if(face==null||cachedSize!=size||cachedBaseline!=baseline||cachedAdvance!=advance||cachedColor!=getCurrentTextColor()||
                cachedSheen!=style.textSheen||cachedSurface!=style.effectiveSurface()||cachedHighlight!=style.surfaceHighlight()||cachedFinish!=style.textFinish||cachedAccent!=style.accent){
                // Repeat per line, not over the entire ayah: long ayahs retain the same contrast.
                float top=baseline-size;int base=getCurrentTextColor();
                if(style.textFinish==Appearance.TEXT_FOIL){
                    int warm=style.foilInk(.34f),shine=style.foilInk(.12f);
                    face=new LinearGradient(0,top,0,top+advance,new int[]{base,warm,shine,warm,base},new float[]{0,.24f,.48f,.72f,1},Shader.TileMode.REPEAT);
                }else if(style.textFinish==Appearance.TEXT_SOFT){
                    int soft=style.glassInk(.08f*Math.max(18,style.textSheen)/100f);
                    face=new LinearGradient(0,top,0,top+advance,new int[]{base,soft,base},new float[]{0,.48f,1},Shader.TileMode.REPEAT);
                }else{
                    face=new LinearGradient(0,top,0,top+advance,
                        new int[]{base,style.glassInk(.25f*style.textSheen/100f),base,style.glassInk(.12f*style.textSheen/100f),base},
                        new float[]{0,.27f,.50f,.72f,1},Shader.TileMode.REPEAT);
                }
                cachedSize=size;cachedBaseline=baseline;cachedAdvance=advance;cachedColor=getCurrentTextColor();
                cachedSheen=style.textSheen;cachedSurface=style.effectiveSurface();cachedHighlight=style.surfaceHighlight();cachedFinish=style.textFinish;cachedAccent=style.accent;
            }
            paint.setShader(face);
            paint.clearShadowLayer();
        }else {paint.setShader(null);paint.clearShadowLayer();}
        int shadowStrength=style.effectiveShadowStrength();
        if(effects&&(style.textDepth>0||shadowStrength>0)){
            float depth=density*style.textDepth/4f;
            float dx=style.shadowDistance>0?style.shadowDx(density):depth,dy=style.shadowDistance>0?style.shadowDy(density):depth;
            int alpha=Math.min(190,(shadowStrength*2)+(style.textDepth>0?35:0));
            int shadow=(style.resolvedShadowColor()&0xffffff)|(alpha<<24);
            paint.setShadowLayer(Math.max(.1f,density*style.effectiveShadowSoftness()/4f),dx,dy,shadow);
        }else if(effects&&style.glow>0)
            paint.setShadowLayer(density,0,0,(getCurrentTextColor()&0xffffff)|((style.glow*2)<<24));
        try{super.onDraw(canvas);}finally{paint.setShader(null);paint.clearShadowLayer();}
    }
}
