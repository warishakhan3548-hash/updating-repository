package com.aaris.quran;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.RippleDrawable;
import android.content.res.ColorStateList;
import android.view.*;
import android.widget.*;

/** Static soft-light artwork: no GPU blur of Quran glyphs, no animation battery cost. */
final class Glass {
    static final int INK=0xFFF5F4EA,MUTED=0xFFAEC7C5,GOLD=0xFFE3CCA1,MINT=0xFFB5E5CD;
    static int dp(Context c,float value){return (int)(c.getResources().getDisplayMetrics().density*value+0.5f);}
    static final class Backdrop extends View {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        boolean highContrast;
        Backdrop(Context c){super(c);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onDraw(Canvas c){
            int w=getWidth(),h=getHeight();
            c.drawColor(highContrast?0xFF071116:0xFF061E29);
            if(!highContrast) {
                paint.setShader(new RadialGradient(w*.08f,h*.08f,w*1.1f,new int[]{0xAB757444,0x00203333},null,Shader.TileMode.CLAMP));c.drawRect(0,0,w,h,paint);
                paint.setShader(new RadialGradient(w*.05f,h*.65f,w*1.2f,new int[]{0x9A0A746D,0x00144961},null,Shader.TileMode.CLAMP));c.drawRect(0,0,w,h,paint);
                paint.setShader(new RadialGradient(w,h*.84f,w*1.1f,new int[]{0xAD185C9B,0x00151D3C},null,Shader.TileMode.CLAMP));c.drawRect(0,0,w,h,paint);
                paint.setShader(null);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(dp(getContext(),0.6f));paint.setColor(0x09E3CCA1);
                float size=dp(getContext(),108);
                for(float y=0;y<h;y+=size)for(float x=0;x<w;x+=size){c.save();c.translate(x+size/2,y+size/2);c.drawRect(-size*.32f,-size*.32f,size*.32f,size*.32f,paint);c.rotate(45);c.drawRect(-size*.32f,-size*.32f,size*.32f,size*.32f,paint);c.restore();}
                paint.setStyle(Paint.Style.FILL);
            }
        }
    }
    static final class Surface extends Drawable {
        enum Kind { PANEL, HERO, MUSHAF, SHEET, NAV, BUTTON, PRIMARY }
        final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);final float radius;final Kind kind;final boolean solid;
        Surface(Context c,Kind kind,boolean solid){radius=dp(c,kind==Kind.BUTTON||kind==Kind.PRIMARY?16:kind==Kind.NAV?28:30);this.kind=kind;this.solid=solid;}
        @Override public void draw(Canvas c){
            Rect b=getBounds();RectF r=new RectF(b.left+1,b.top+1,b.right-1,b.bottom-1);
            p.setStyle(Paint.Style.FILL);
            int[] colors;
            if(kind==Kind.PRIMARY)colors=new int[]{0xFFD3EFDA,0xFF9EDAC9};
            else if(kind==Kind.SHEET)colors=new int[]{0xFF274A47,0xFF103C52};
            else if(solid)colors=new int[]{0xFF122E35,0xFF0E2734};
            else if(kind==Kind.HERO||kind==Kind.MUSHAF)colors=new int[]{0xCC56715A,0xE5245A68,0xDD17466C};
            else if(kind==Kind.NAV)colors=new int[]{0xF21A363E,0xF0112C3C};
            else if(kind==Kind.BUTTON)colors=new int[]{0xB33A5656,0xB022414D};
            else colors=new int[]{0x754B6C65,0xAA173D50};
            p.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,colors,null,Shader.TileMode.CLAMP));
            c.drawRoundRect(r,radius,radius,p);p.setShader(null);
            p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.5f);
            p.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,new int[]{0x66EBF6D7,0x1AD6EAE7,0x448BBBCD},null,Shader.TileMode.CLAMP));
            c.drawRoundRect(r,radius,radius,p);p.setShader(null);
            if(kind==Kind.MUSHAF||kind==Kind.HERO){p.setColor(0x22ECEDD6);p.setStrokeWidth(1);r.inset(8,8);c.drawRoundRect(r,Math.max(0,radius-8),Math.max(0,radius-8),p);}
            p.setStyle(Paint.Style.FILL);
        }
        @Override public void setAlpha(int alpha){} @Override public void setColorFilter(ColorFilter f){} @Override public int getOpacity(){return PixelFormat.TRANSLUCENT;}
    }
    static final class Icon extends View {
        final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);final String type;int color=INK;
        Icon(Context c,String type){super(c);this.type=type;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onDraw(Canvas canvas){
            Canvas c=canvas;c.save();float scale=Math.min(getWidth(),getHeight())/24f;c.translate((getWidth()-24*scale)/2,(getHeight()-24*scale)/2);c.scale(scale,scale);
            p.setColor(color);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.55f);p.setStrokeCap(Paint.Cap.ROUND);p.setStrokeJoin(Paint.Join.ROUND);
            Path a=new Path();
            switch(type){
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
                case "moon":a.moveTo(17,3);a.cubicTo(5,1,1,17,12,21);a.cubicTo(18,23,22,18,22,14);a.cubicTo(13,18,9,8,17,3);c.drawPath(a,p);break;
                default:for(int i=0;i<3;i++)c.drawCircle(5+i*7,12,0.7f,p);
            }c.restore();
        }
    }
    static Drawable touch(Context c,Surface.Kind kind,boolean solid){return new RippleDrawable(ColorStateList.valueOf(0x22FFFFFF),new Surface(c,kind,solid),new Surface(c,Surface.Kind.PRIMARY,true));}
    static LinearLayout column(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.VERTICAL);return l;}
    static LinearLayout row(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
    static TextView text(Context c,String text,float sp,int color){TextView v=new TextView(c);v.setText(text);v.setTextSize(sp);v.setTextColor(color);v.setFontFeatureSettings("kern");v.setIncludeFontPadding(true);v.setLineSpacing(dp(c,2),1.06f);return v;}
    static void pad(View v,int horizontal,int vertical){v.setPadding(dp(v.getContext(),horizontal),dp(v.getContext(),vertical),dp(v.getContext(),horizontal),dp(v.getContext(),vertical));}
}
