package com.aaris.quran;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.view.*;
import android.widget.*;

/** Static soft-light artwork: no GPU blur of Quran glyphs, no animation battery cost. */
final class Glass {
    static final int INK=Color.rgb(238,246,237),MUTED=Color.rgb(172,199,194),GOLD=Color.rgb(218,199,153),MINT=Color.rgb(169,222,200);
    static int dp(Context c,float value){return (int)(c.getResources().getDisplayMetrics().density*value+0.5f);}
    static final class Backdrop extends View {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        boolean highContrast;
        Backdrop(Context c){super(c);setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onDraw(Canvas c){
            int w=getWidth(),h=getHeight();
            c.drawColor(highContrast?Color.rgb(7,17,22):Color.rgb(7,27,35));
            if(!highContrast) {
                paint.setShader(new RadialGradient(w*.1f,h*.15f,w*.95f,new int[]{0xA8547651,0x00365544},null,Shader.TileMode.CLAMP));c.drawRect(0,0,w,h,paint);
                paint.setShader(new RadialGradient(w*.93f,h*.50f,w*.93f,new int[]{0xB5196775,0x00144961},null,Shader.TileMode.CLAMP));c.drawRect(0,0,w,h,paint);
                paint.setShader(new RadialGradient(w*.2f,h*.95f,w*.85f,new int[]{0x554B365F,0x00151D3C},null,Shader.TileMode.CLAMP));c.drawRect(0,0,w,h,paint);
                paint.setShader(null);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(dp(getContext(),0.6f));paint.setColor(0x0FD8CEA9);
                float size=dp(getContext(),84);
                for(float y=0;y<h;y+=size)for(float x=0;x<w;x+=size){c.save();c.translate(x+size/2,y+size/2);c.drawRect(-size*.32f,-size*.32f,size*.32f,size*.32f,paint);c.rotate(45);c.drawRect(-size*.32f,-size*.32f,size*.32f,size*.32f,paint);c.restore();}
                paint.setStyle(Paint.Style.FILL);
            }
        }
    }
    static final class Surface extends Drawable {
        final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);final float radius;final boolean prominent,solid;
        Surface(Context c,boolean prominent,boolean solid){radius=dp(c,26);this.prominent=prominent;this.solid=solid;}
        @Override public void draw(Canvas c){
            Rect b=getBounds();RectF r=new RectF(b.left+1,b.top+1,b.right-1,b.bottom-1);
            p.setStyle(Paint.Style.FILL);
            p.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,solid?new int[]{0xFF10272E,0xFF10232D}:prominent?new int[]{0xCF3B6859,0xCC184B66}:new int[]{0xA52C4947,0xB013303F},null,Shader.TileMode.CLAMP));
            c.drawRoundRect(r,radius,radius,p);p.setShader(null);
            p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1.5f);
            p.setShader(new LinearGradient(b.left,b.top,b.right,b.bottom,new int[]{0x66EBF6D7,0x1AD6EAE7,0x448BBBCD},null,Shader.TileMode.CLAMP));
            c.drawRoundRect(r,radius,radius,p);p.setShader(null);
            p.setColor(0x10FFFFFF);p.setStrokeWidth(1);r.inset(5,5);c.drawRoundRect(r,Math.max(0,radius-5),Math.max(0,radius-5),p);
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
    static LinearLayout column(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.VERTICAL);return l;}
    static LinearLayout row(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
    static TextView text(Context c,String text,float sp,int color){TextView v=new TextView(c);v.setText(text);v.setTextSize(sp);v.setTextColor(color);v.setFontFeatureSettings("kern");v.setIncludeFontPadding(true);v.setLineSpacing(dp(c,2),1.06f);return v;}
    static void pad(View v,int horizontal,int vertical){v.setPadding(dp(v.getContext(),horizontal),dp(v.getContext(),vertical),dp(v.getContext(),horizontal),dp(v.getContext(),vertical));}
}
