package com.aaris.quran;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.RippleDrawable;
import android.content.res.ColorStateList;
import android.view.*;
import android.widget.*;

/** Smoked emerald glass over black. Cached paints; no wallpaper, live blur or bright bloom. */
final class Glass {
    static int BACKGROUND=0xFF030705,INK=0xFFD5D7CB,MUTED=0xFFA6B3AA,
        GOLD=0xFFCDBFA3,MINT=0xFFB7CCB8,ARABIC_INK=0xFFD8D8C9,HIGH_INK=0xFFE8E8DB,
        WORD_HIGHLIGHT=0x40587B63;
    static Appearance appearance=new Appearance();
    static void apply(Appearance a){appearance=a;BACKGROUND=a.background;INK=a.ink();MUTED=a.muted();
        GOLD=Appearance.readable(a.accent,a.effectiveSurface());MINT=GOLD;ARABIC_INK=Appearance.readable(a.arabic,a.effectiveSurface());HIGH_INK=INK;
        WORD_HIGHLIGHT=(a.accent&0xffffff)|0x45000000;}
    static int dp(Context c,float value){return (int)(c.getResources().getDisplayMetrics().density*value+0.5f);}
    static final class Backdrop extends View {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        boolean highContrast;
        private Shader ambient;private int cachedAccent;
        Backdrop(Context c){super(c);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onSizeChanged(int w,int h,int oldW,int oldH){
            super.onSizeChanged(w,h,oldW,oldH);
            cachedAccent=appearance.accent;if(w>0&&h>0)ambient=new RadialGradient(w*.55f,h*.26f,Math.max(w,h)*.65f,
                new int[]{(appearance.accent&0xffffff)|0x14000000,appearance.accent&0xffffff},null,Shader.TileMode.CLAMP);
        }
        @Override protected void onDraw(Canvas canvas){
            if(cachedAccent!=appearance.accent)onSizeChanged(getWidth(),getHeight(),getWidth(),getHeight());
            canvas.drawColor(BACKGROUND);
            if(!highContrast&&ambient!=null){paint.setShader(ambient);canvas.drawRect(0,0,getWidth(),getHeight(),paint);}
        }
    }
    static final class Surface extends Drawable {
        enum Kind { PANEL, HERO, MUSHAF, SHEET, NAV, BUTTON, PRIMARY }
        private final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF outer=new RectF(),inner=new RectF();
        private final float radius,inset,stroke;
        private final Kind kind;
        private final boolean solid;
        private Shader fill,rim;
        private int opacity=255;
        Surface(Context c,Kind kind,boolean solid){
            float density=c.getResources().getDisplayMetrics().density;
            radius=dp(c,appearance.corners);
            inset=3*density;stroke=.65f*density;this.kind=kind;this.solid=solid;
        }
        @Override protected void onBoundsChange(Rect b){
            super.onBoundsChange(b);outer.set(b.left+stroke,b.top+stroke,b.right-stroke,b.bottom-stroke);
            inner.set(outer);inner.inset(inset,inset);if(outer.isEmpty())return;
            int base=appearance.effectiveSurface();
            if(kind==Kind.PRIMARY)base=Appearance.mix(base,appearance.accent,.15f);
            int[] colors=appearance.glass&&!solid?new int[]{Appearance.mix(base,appearance.accent,.06f),base}:new int[]{base,base};
            fill=new LinearGradient(outer.left,outer.top,outer.right,outer.bottom,colors,null,Shader.TileMode.CLAMP);
            rim=new LinearGradient(outer.left,outer.top,outer.right,outer.bottom,
                new int[]{(appearance.accent&0xffffff)|0x70000000,(appearance.accent&0xffffff)|0x17000000},null,Shader.TileMode.CLAMP);
        }
        @Override public void draw(Canvas canvas){
            if(fill==null||outer.isEmpty())return;
            p.setColor(Color.WHITE);p.setAlpha(opacity);p.setStyle(Paint.Style.FILL);p.setShader(fill);
            canvas.drawRoundRect(outer,radius,radius,p);
            p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(stroke);p.setShader(rim);
            canvas.drawRoundRect(outer,radius,radius,p);p.setShader(null);
            if(!solid&&(kind==Kind.MUSHAF||kind==Kind.HERO)){
                p.setColor(0xFF8EA18F);p.setAlpha(18*opacity/255);p.setStrokeWidth(stroke*.6f);
                canvas.drawRoundRect(inner,Math.max(0,radius-inset),Math.max(0,radius-inset),p);
            }
        }
        @Override public void setAlpha(int value){opacity=Math.max(0,Math.min(255,value));invalidateSelf();}
        @Override public void setColorFilter(ColorFilter filter){p.setColorFilter(filter);invalidateSelf();}
        @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
    static final class Icon extends View {
        final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);final String type;int color=INK;
        Icon(Context c,String type){super(c);this.type=type;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onDraw(Canvas canvas){
            Canvas c=canvas;c.save();float scale=Math.min(getWidth(),getHeight())/24f;c.translate((getWidth()-24*scale)/2,(getHeight()-24*scale)/2);c.scale(scale,scale);
            p.setColor(color);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.55f);p.setStrokeCap(Paint.Cap.ROUND);p.setStrokeJoin(Paint.Join.ROUND);
            Path a=new Path();
            switch(type){
                case "play":a.moveTo(8,4);a.lineTo(20,12);a.lineTo(8,20);a.close();c.drawPath(a,p);break;
                case "pause":c.drawLine(8,5,8,19,p);c.drawLine(16,5,16,19,p);break;
                case "copy":c.drawRoundRect(8,7,21,21,2,2,p);a.moveTo(16,3);a.lineTo(3,3);a.lineTo(3,16);c.drawPath(a,p);break;
                case "download":c.drawLine(12,3,12,16,p);c.drawLine(7,11,12,16,p);c.drawLine(12,16,17,11,p);a.moveTo(3,17);a.lineTo(3,21);a.lineTo(21,21);a.lineTo(21,17);c.drawPath(a,p);break;
                case "search":c.drawCircle(10.5f,10.5f,6.5f,p);c.drawLine(15.5f,15.5f,21,21,p);break;
                case "rosette":c.drawRect(5,5,19,19,p);c.rotate(45,12,12);c.drawRect(5,5,19,19,p);break;
                case "back":c.drawLine(15,5,8,12,p);c.drawLine(8,12,15,19,p);break;
                case "next":c.drawLine(9,5,16,12,p);c.drawLine(16,12,9,19,p);break;
                case "book":a.moveTo(3,5);a.quadTo(8,3,12,7);a.quadTo(16,3,21,5);a.lineTo(21,20);a.quadTo(16,18,12,21);a.quadTo(8,18,3,20);a.close();c.drawPath(a,p);c.drawLine(12,7,12,21,p);break;
                case "hadith":c.drawRoundRect(5,3,19,21,2,2,p);c.drawLine(8,3,8,21,p);c.drawLine(11,8,16,8,p);c.drawLine(11,12,16,12,p);c.drawLine(11,16,14,16,p);break;
                case "cards":c.drawRoundRect(3,7,18,21,3,3,p);a.moveTo(8,3);a.lineTo(18,3);a.quadTo(22,3,22,7);a.lineTo(22,15);c.drawPath(a,p);c.drawLine(7,12,14,12,p);c.drawLine(7,16,12,16,p);break;
                case "clock":c.drawCircle(12,12,9,p);c.drawLine(12,6,12,12,p);c.drawLine(12,12,16,14,p);break;
                case "bookmark":a.moveTo(6,3);a.lineTo(18,3);a.lineTo(18,21);a.lineTo(12,17);a.lineTo(6,21);a.close();c.drawPath(a,p);break;
                case "sun":c.drawCircle(12,12,4,p);for(int i=0;i<8;i++){c.save();c.rotate(i*45,12,12);c.drawLine(12,2,12,4,p);c.restore();}break;
                case "map":c.drawCircle(6,7,2.5f,p);c.drawCircle(18,6,2.5f,p);c.drawCircle(14,19,2.5f,p);c.drawLine(8.5f,7,15.5f,6,p);c.drawLine(7.5f,9,12.5f,17,p);c.drawLine(18,8.5f,15,16.5f,p);break;
                case "settings":for(int i=0;i<3;i++){float y=5+i*7;c.drawLine(3,y,21,y,p);c.drawCircle(i==1?9:16,y,2,p);}break;
                case "close":c.drawLine(6,6,18,18,p);c.drawLine(6,18,18,6,p);break;
                case "check":a.moveTo(4,12);a.lineTo(9,17);a.lineTo(20,6);c.drawPath(a,p);break;
                case "share":c.drawCircle(5,12,2,p);c.drawCircle(19,5,2,p);c.drawCircle(19,19,2,p);c.drawLine(7,11,17,6,p);c.drawLine(7,13,17,18,p);break;
                case "speaker":a.moveTo(4,10);a.lineTo(8,10);a.lineTo(13,6);a.lineTo(13,18);a.lineTo(8,14);a.lineTo(4,14);a.close();c.drawPath(a,p);c.drawArc(14,8,20,16,-55,110,false,p);c.drawArc(14,5,23,19,-55,110,false,p);break;
                case "moon":a.moveTo(17,3);a.cubicTo(5,1,1,17,12,21);a.cubicTo(18,23,22,18,22,14);a.cubicTo(13,18,9,8,17,3);c.drawPath(a,p);break;
                default:for(int i=0;i<3;i++)c.drawCircle(5+i*7,12,0.7f,p);
            }c.restore();
        }
    }
    static Drawable touch(Context c,Surface.Kind kind,boolean solid){return new RippleDrawable(ColorStateList.valueOf(0x1ADCE5D6),new Surface(c,kind,solid),new Surface(c,Surface.Kind.PRIMARY,true));}
    static LinearLayout column(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.VERTICAL);return l;}
    static LinearLayout row(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
    static TextView text(Context c,String text,float sp,int color){TextView v=new TextView(c);v.setText(text);v.setTextSize(sp);v.setTextColor(color);v.setFontFeatureSettings("kern");v.setIncludeFontPadding(true);v.setLineSpacing(dp(c,2),1.06f);return v;}
    static void pad(View v,int horizontal,int vertical){v.setPadding(dp(v.getContext(),horizontal),dp(v.getContext(),vertical),dp(v.getContext(),horizontal),dp(v.getContext(),vertical));}
}
