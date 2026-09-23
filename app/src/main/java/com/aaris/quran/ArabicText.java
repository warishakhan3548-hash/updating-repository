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
    private int cachedBaseline=-1,cachedAdvance=-1,cachedColor,cachedSheen=-1,cachedSurface,cachedHighlight;
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
        if(effects&&style.textGlass&&layout!=null&&layout.getLineCount()>0){
            int baseline=layout.getLineBaseline(0);
            int advance=Math.max(1,layout.getLineCount()>1?layout.getLineBaseline(1)-baseline:layout.getLineBottom(0)-layout.getLineTop(0));
            float size=getTextSize();
            if(face==null||cachedSize!=size||cachedBaseline!=baseline||cachedAdvance!=advance||cachedColor!=getCurrentTextColor()||
                cachedSheen!=style.textSheen||cachedSurface!=style.effectiveSurface()||cachedHighlight!=style.surfaceHighlight()){
                // Repeat per line, not over the entire ayah: long ayahs retain the same contrast.
                float top=baseline-size;
                face=new LinearGradient(0,top,0,top+advance,
                    new int[]{getCurrentTextColor(),style.glassInk(.25f*style.textSheen/100f),getCurrentTextColor(),style.glassInk(.12f*style.textSheen/100f),getCurrentTextColor()},
                    new float[]{0,.27f,.50f,.72f,1},Shader.TileMode.REPEAT);
                cachedSize=size;cachedBaseline=baseline;cachedAdvance=advance;cachedColor=getCurrentTextColor();
                cachedSheen=style.textSheen;cachedSurface=style.effectiveSurface();cachedHighlight=style.surfaceHighlight();
            }
            paint.setShader(face);
            paint.clearShadowLayer();
        }else {paint.setShader(null);paint.clearShadowLayer();}
        if(effects&&(style.textDepth>0||style.shadowStrength>0)){
            float depth=density*style.textDepth/4f;
            int alpha=Math.min(190,(style.shadowStrength*2)+(style.textDepth>0?35:0));
            paint.setShadowLayer(Math.max(.1f,density*style.shadowSoftness/4f),depth,depth,alpha<<24);
        }else if(effects&&style.glow>0)
            paint.setShadowLayer(density,0,0,(getCurrentTextColor()&0xffffff)|((style.glow*2)<<24));
        try{super.onDraw(canvas);}finally{paint.setShader(null);paint.clearShadowLayer();}
    }
}
