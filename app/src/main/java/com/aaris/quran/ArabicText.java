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
    private int cachedBaseline=-1,cachedAdvance=-1,cachedColor;
    private final float density;

    ArabicText(Context context){
        super(context);density=getResources().getDisplayMetrics().density;
        setTextColor(Glass.ARABIC_INK);
    }
    void setReliefEnabled(boolean enabled){
        relief=enabled&&Glass.appearance.textGlass;setTextColor(Glass.ARABIC_INK);face=null;invalidate();
    }
    void setWordHighlighted(boolean highlighted){wordHighlighted=highlighted;invalidate();}
    @Override protected void onDraw(Canvas canvas){
        TextPaint paint=getPaint();Layout layout=getLayout();
        // Android uses the glyph paint for BackgroundColorSpan too. Keep a selected ayah
        // plain so the word's green highlight never inherits the ivory shader or shadow.
        if(relief&&!wordHighlighted&&layout!=null&&layout.getLineCount()>0){
            int baseline=layout.getLineBaseline(0);
            int advance=Math.max(1,layout.getLineCount()>1?layout.getLineBaseline(1)-baseline:layout.getLineBottom(0)-layout.getLineTop(0));
            float size=getTextSize();
            if(face==null||cachedSize!=size||cachedBaseline!=baseline||cachedAdvance!=advance||cachedColor!=getCurrentTextColor()){
                // Repeat per line, not over the entire ayah: long ayahs retain the same contrast.
                float top=baseline-size;
                face=new LinearGradient(0,top,0,top+advance,
                    new int[]{getCurrentTextColor(),Appearance.mix(getCurrentTextColor(),Glass.appearance.ink(),.10f),getCurrentTextColor(),Appearance.mix(getCurrentTextColor(),Glass.appearance.ink(),.08f),getCurrentTextColor()},
                    new float[]{0,.27f,.50f,.72f,1},Shader.TileMode.REPEAT);
                cachedSize=size;cachedBaseline=baseline;cachedAdvance=advance;cachedColor=getCurrentTextColor();
            }
            paint.setShader(face);
            // A short dark contact shadow gives relief without bright halos or doubled text.
            paint.clearShadowLayer();
        }else {paint.setShader(null);paint.clearShadowLayer();}
        try{super.onDraw(canvas);}finally{paint.setShader(null);paint.clearShadowLayer();}
    }
}
