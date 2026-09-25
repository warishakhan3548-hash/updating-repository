package com.aaris.quran;

import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.RippleDrawable;
import android.content.res.ColorStateList;
import android.animation.*;
import android.view.*;
import android.view.animation.DecelerateInterpolator;
import android.widget.*;

/** Smoked emerald glass over black. Cached paints; no wallpaper, live blur or bright bloom. */
final class Glass {
    static int BACKGROUND=0xFF030705,INK=0xFFD5D7CB,MUTED=0xFFA6B3AA,
        GOLD=0xFFCDBFA3,MINT=0xFFB7CCB8,ARABIC_INK=0xFFD8D8C9,HIGH_INK=0xFFE8E8DB,
        WORD_HIGHLIGHT=0x40587B63;
    static Appearance appearance=new Appearance();
    static void apply(Appearance a){appearance=a;BACKGROUND=a.background;INK=a.appInk();MUTED=a.muted();
        GOLD=Appearance.readable(a.accent,a.effectiveSurface());MINT=GOLD;ARABIC_INK=a.arabicInk();HIGH_INK=INK;
        WORD_HIGHLIGHT=(a.accent&0xffffff)|0x45000000;}
    static int dp(Context c,float value){return (int)(c.getResources().getDisplayMetrics().density*value+0.5f);}
    static final class Backdrop extends View {
        final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
        boolean highContrast;
        private final boolean preview;
        private Shader ambient,backgroundGradient;private int cachedAccent,cachedBackground,cachedEnd,cachedScene,cachedStrength,cachedGradientAngle;
        Backdrop(Context c){this(c,false);}
        Backdrop(Context c,boolean preview){super(c);this.preview=preview;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
        @Override protected void onSizeChanged(int w,int h,int oldW,int oldH){
            super.onSizeChanged(w,h,oldW,oldH);
            cachedAccent=appearance.accent;cachedBackground=appearance.background;cachedEnd=appearance.gradientEnd;cachedScene=appearance.scene;cachedStrength=appearance.sceneStrength;cachedGradientAngle=appearance.gradientAngle;
            if(w>0&&h>0){
                double radians=Math.toRadians(cachedGradientAngle);float dx=(float)Math.cos(radians),dy=(float)Math.sin(radians);
                float cx=w/2f,cy=h/2f,half=(Math.abs(dx)*w+Math.abs(dy)*h)/2f;
                backgroundGradient=new LinearGradient(cx-dx*half,cy-dy*half,cx+dx*half,cy+dy*half,new int[]{cachedBackground,cachedEnd},null,Shader.TileMode.CLAMP);
            }
            if(w>0&&h>0)ambient=new RadialGradient(w*.55f,h*.26f,Math.max(w,h)*.65f,
                new int[]{(appearance.accent&0xffffff)|0x14000000,appearance.accent&0xffffff},null,Shader.TileMode.CLAMP);
        }
        @Override protected void onDraw(Canvas canvas){
            if(cachedAccent!=appearance.accent||cachedBackground!=appearance.background||cachedEnd!=appearance.gradientEnd||cachedScene!=appearance.scene||cachedStrength!=appearance.sceneStrength||cachedGradientAngle!=appearance.gradientAngle)onSizeChanged(getWidth(),getHeight(),getWidth(),getHeight());
            canvas.drawColor(BACKGROUND);
            if(!highContrast&&!appearance.reducedEffects&&appearance.gradient&&backgroundGradient!=null){paint.setShader(backgroundGradient);canvas.drawRect(0,0,getWidth(),getHeight(),paint);}
            if(!highContrast&&!appearance.reducedEffects&&ambient!=null){paint.setShader(ambient);canvas.drawRect(0,0,getWidth(),getHeight(),paint);}
            if(!highContrast&&!appearance.reducedEffects&&appearance.scene>0)drawScene(canvas);
        }
        private void drawScene(Canvas canvas){
            final int strength=Math.max(0,Math.min(100,appearance.sceneStrength));
            final float a=(preview?1f:.42f)*(strength/100f);
            final float w=getWidth(),h=getHeight();
            paint.setShader(null);paint.setStyle(Paint.Style.FILL);

            if(appearance.scene==1){
                // Light Parchment: warm paper, sunlit arcade hints and quiet manuscript corners.
                paint.setColor(Color.argb(Math.round(20*a),181,139,79));
                canvas.drawRect(0,0,w,h,paint);

                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f,w*.002f));
                paint.setColor(Color.argb(Math.round(58*a),39,100,79));
                float inset=w*.055f;
                RectF arch=new RectF(inset,h*.05f,w-inset,h*.52f);
                canvas.drawArc(arch,180,180,false,paint);
                canvas.drawLine(inset,h*.285f,inset,h*.62f,paint);
                canvas.drawLine(w-inset,h*.285f,w-inset,h*.62f,paint);

                paint.setStrokeWidth(Math.max(1f,w*.0015f));
                paint.setColor(Color.argb(Math.round(48*a),197,158,92));
                float corner=w*.115f;
                canvas.drawLine(inset,corner,inset+corner,corner,paint);
                canvas.drawLine(w-inset-corner,corner,w-inset,corner,paint);

                paint.setStyle(Paint.Style.FILL);
                RadialGradient sun=new RadialGradient(w*.82f,h*.16f,Math.max(w,h)*.43f,
                    new int[]{Color.argb(Math.round(72*a),255,247,222),Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                paint.setShader(sun);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                // Leaf-shadow rhythm, deliberately abstract so scripture stays the visual focus.
                paint.setColor(Color.argb(Math.round(24*a),32,90,65));
                for(int i=0;i<5;i++){
                    float x=w*(.08f+i*.055f),y=h*(.17f+i*.035f);
                    canvas.save();canvas.rotate(-28+i*7,x,y);
                    canvas.drawOval(new RectF(x-w*.018f,y-h*.025f,x+w*.018f,y+h*.025f),paint);canvas.restore();
                }
            }else if(appearance.scene==2){
                // Moonlit Emerald: deep arches, moon haze, lantern warmth and reflected light.
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f,w*.0022f));
                paint.setColor(Color.argb(Math.round(46*a),209,184,113));
                float inset=w*.06f;
                RectF arch=new RectF(inset,h*.045f,w-inset,h*.56f);
                canvas.drawArc(arch,180,180,false,paint);
                canvas.drawLine(inset,h*.30f,inset,h*.64f,paint);
                canvas.drawLine(w-inset,h*.30f,w-inset,h*.64f,paint);

                paint.setStyle(Paint.Style.FILL);
                RadialGradient moon=new RadialGradient(w*.78f,h*.13f,Math.max(w,h)*.18f,
                    new int[]{Color.argb(Math.round(66*a),221,235,229),Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                paint.setShader(moon);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                LinearGradient beam=new LinearGradient(w*.18f,0,w*.36f,h*.65f,
                    new int[]{Color.argb(Math.round(34*a),236,211,152),Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                paint.setShader(beam);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                // Warm lantern pools; subtle on the full app, stronger in the live preview.
                for(float x:new float[]{.12f,.88f}){
                    RadialGradient lamp=new RadialGradient(w*x,h*.33f,w*.12f,
                        new int[]{Color.argb(Math.round(72*a),236,179,88),Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    paint.setShader(lamp);canvas.drawRect(0,0,w,h,paint);
                }
                paint.setShader(null);
                paint.setColor(Color.argb(Math.round(30*a),193,216,205));
                for(int i=0;i<4;i++)canvas.drawRoundRect(new RectF(w*.08f,h*(.71f+i*.045f),w*.92f,h*(.715f+i*.045f)),w*.01f,w*.01f,paint);
            }else if(appearance.scene==3){
                // Rose Dusk: burgundy twilight, a low sunset and quiet mosque silhouette.
                LinearGradient dusk=new LinearGradient(0,h*.02f,w,h*.72f,
                    new int[]{Color.argb(Math.round(82*a),92,35,57),Color.argb(Math.round(54*a),211,87,77),Color.TRANSPARENT},
                    null,Shader.TileMode.CLAMP);
                paint.setShader(dusk);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                RadialGradient sun=new RadialGradient(w*.72f,h*.33f,Math.max(w,h)*.16f,
                    new int[]{Color.argb(Math.round(112*a),255,166,111),Color.argb(Math.round(32*a),247,111,94),Color.TRANSPARENT},
                    null,Shader.TileMode.CLAMP);
                paint.setShader(sun);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f,w*.002f));
                paint.setColor(Color.argb(Math.round(48*a),255,167,143));
                float inset=w*.055f;
                RectF arch=new RectF(inset,h*.045f,w-inset,h*.56f);
                canvas.drawArc(arch,180,180,false,paint);
                canvas.drawLine(inset,h*.30f,inset,h*.62f,paint);
                canvas.drawLine(w-inset,h*.30f,w-inset,h*.62f,paint);

                paint.setStyle(Paint.Style.FILL);
                int silhouette=Color.argb(Math.round(92*a),39,16,28);
                drawMosqueSilhouette(canvas,w,h,silhouette,h*.57f);

                // Soft reflected sunset and floral haze near the lower edges.
                paint.setColor(Color.argb(Math.round(30*a),255,129,112));
                for(int i=0;i<4;i++)canvas.drawRoundRect(new RectF(w*.10f,h*(.68f+i*.045f),w*.90f,h*(.685f+i*.045f)),w*.012f,w*.012f,paint);
                for(float x:new float[]{.08f,.15f,.86f,.93f}){
                    RadialGradient bloom=new RadialGradient(w*x,h*.72f,w*.11f,
                        new int[]{Color.argb(Math.round(38*a),202,70,103),Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    paint.setShader(bloom);canvas.drawRect(0,0,w,h,paint);
                }
                paint.setShader(null);
            }else if(appearance.scene==4){
                // Ivory Mint: soft daylight, pale botanical corners and faint mosque architecture.
                LinearGradient veil=new LinearGradient(0,0,w,h,
                    new int[]{Color.argb(Math.round(46*a),255,255,248),Color.argb(Math.round(24*a),205,229,213),Color.TRANSPARENT},
                    null,Shader.TileMode.CLAMP);
                paint.setShader(veil);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                RadialGradient daylight=new RadialGradient(w*.72f,h*.18f,Math.max(w,h)*.48f,
                    new int[]{Color.argb(Math.round(104*a),255,252,230),Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                paint.setShader(daylight);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f,w*.0018f));
                paint.setColor(Color.argb(Math.round(32*a),50,126,99));
                float inset=w*.06f;
                RectF arch=new RectF(inset,h*.055f,w-inset,h*.55f);
                canvas.drawArc(arch,180,180,false,paint);

                paint.setStyle(Paint.Style.FILL);
                paint.setColor(Color.argb(Math.round(25*a),46,116,89));
                float[][] leaves={{.06f,.15f,-30f},{.12f,.21f,-18f},{.91f,.12f,28f},{.85f,.20f,18f},{.10f,.73f,-18f},{.90f,.69f,22f}};
                for(float[] leaf:leaves){
                    float x=w*leaf[0],y=h*leaf[1];
                    canvas.save();canvas.rotate(leaf[2],x,y);
                    canvas.drawOval(new RectF(x-w*.020f,y-h*.030f,x+w*.020f,y+h*.030f),paint);
                    canvas.restore();
                }

                // Distant mosque silhouette kept very faint so the page stays calm and readable.
                drawMosqueSilhouette(canvas,w,h,Color.argb(Math.round(20*a),54,112,91),h*.63f);
            }else if(appearance.scene==5){
                // Moonlit Sapphire: saturated royal-blue night with white scripture and electric glass.
                LinearGradient sapphire=new LinearGradient(0,0,w,h,
                    new int[]{Color.argb(Math.round(86*a),8,49,111),Color.argb(Math.round(56*a),13,86,170),Color.TRANSPARENT},
                    null,Shader.TileMode.CLAMP);
                paint.setShader(sapphire);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                RadialGradient moon=new RadialGradient(w*.72f,h*.13f,Math.max(w,h)*.20f,
                    new int[]{Color.argb(Math.round(104*a),244,250,255),Color.argb(Math.round(30*a),115,186,255),Color.TRANSPARENT},
                    null,Shader.TileMode.CLAMP);
                paint.setShader(moon);canvas.drawRect(0,0,w,h,paint);paint.setShader(null);

                // Cool architectural arch and luminous cyan edge rhythm.
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(Math.max(1f,w*.0021f));
                paint.setColor(Color.argb(Math.round(62*a),103,192,255));
                float inset=w*.052f;
                RectF arch=new RectF(inset,h*.045f,w-inset,h*.56f);
                canvas.drawArc(arch,180,180,false,paint);
                canvas.drawLine(inset,h*.30f,inset,h*.63f,paint);
                canvas.drawLine(w-inset,h*.30f,w-inset,h*.63f,paint);

                // Mosque silhouette and water reflection.
                drawMosqueSilhouette(canvas,w,h,Color.argb(Math.round(104*a),2,26,61),h*.59f);
                paint.setStyle(Paint.Style.FILL);
                paint.setColor(Color.argb(Math.round(38*a),116,190,255));
                for(int i=0;i<5;i++){
                    float y=h*(.69f+i*.038f);
                    canvas.drawRoundRect(new RectF(w*.09f,y,w*.91f,y+h*.005f),w*.012f,w*.012f,paint);
                }

                // Warm lantern contrast from Image 1.
                for(float x:new float[]{.08f,.91f}){
                    RadialGradient lantern=new RadialGradient(w*x,h*.42f,w*.13f,
                        new int[]{Color.argb(Math.round(86*a),255,191,92),Color.argb(Math.round(24*a),255,159,57),Color.TRANSPARENT},
                        null,Shader.TileMode.CLAMP);
                    paint.setShader(lantern);canvas.drawRect(0,0,w,h,paint);
                }
                paint.setShader(null);
            }
        }
        private void drawMosqueSilhouette(Canvas canvas,float w,float h,int color,float baseY){
            paint.setShader(null);paint.setStyle(Paint.Style.FILL);paint.setColor(color);
            float cx=w*.67f,base=baseY,unit=w*.035f;
            canvas.drawRect(cx-unit*2.7f,base-unit*.35f,cx+unit*2.7f,base+unit*1.5f,paint);
            RectF dome=new RectF(cx-unit*2.3f,base-unit*2.35f,cx+unit*2.3f,base+unit*.1f);
            canvas.drawArc(dome,180,180,true,paint);
            canvas.drawRect(cx-unit*.12f,base-unit*2.65f,cx+unit*.12f,base-unit*2.1f,paint);
            Path finial=new Path();finial.moveTo(cx,base-unit*3.0f);finial.lineTo(cx-unit*.18f,base-unit*2.62f);finial.lineTo(cx+unit*.18f,base-unit*2.62f);finial.close();canvas.drawPath(finial,paint);
            for(float dx:new float[]{-4.25f,4.25f}){
                float x=cx+unit*dx;
                canvas.drawRect(x-unit*.28f,base-unit*3.0f,x+unit*.28f,base+unit*1.2f,paint);
                canvas.drawCircle(x,base-unit*3.05f,unit*.42f,paint);
                Path cap=new Path();cap.moveTo(x,base-unit*3.75f);cap.lineTo(x-unit*.36f,base-unit*3.1f);cap.lineTo(x+unit*.36f,base-unit*3.1f);cap.close();canvas.drawPath(cap,paint);
            }
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
            boolean button=kind==Kind.BUTTON||kind==Kind.PRIMARY;
            int base=button?appearance.buttonSurface():appearance.surface;
            if(kind==Kind.PRIMARY)base=Appearance.mix(base,appearance.accent,.15f);
            int highlight=appearance.glass&&!appearance.reducedEffects&&!solid?Appearance.mix(base,appearance.accent,.06f*appearance.glassStrength/100f):base;
            int cardAlpha=!solid&&!button?Math.round(255*appearance.opacity/100f):255;
            int[] colors=new int[]{(highlight&0xffffff)|(cardAlpha<<24),(base&0xffffff)|(cardAlpha<<24)};
            fill=new LinearGradient(outer.left,outer.top,outer.right,outer.bottom,colors,null,Shader.TileMode.CLAMP);
            int border=appearance.effectiveBorderStrength();
            rim=new LinearGradient(outer.left,outer.top,outer.right,outer.bottom,
                new int[]{(appearance.accent&0xffffff)|((112*border/100)<<24),(appearance.accent&0xffffff)|((23*border/100)<<24)},null,Shader.TileMode.CLAMP);
        }
        @Override public void draw(Canvas canvas){
            if(fill==null||outer.isEmpty())return;
            int fillAlpha=opacity;
            if(!solid&&appearance.scene>0&&(kind==Kind.MUSHAF||kind==Kind.HERO)){
                float sceneAlpha=appearance.scene==1?.88f:appearance.scene==3?.76f:appearance.scene==4?.92f:appearance.scene==5?.74f:.80f;
                fillAlpha=Math.round(opacity*sceneAlpha);
            }else if(!solid&&(appearance.scene==2||appearance.scene==3||appearance.scene==5)&&appearance.glass&&kind==Kind.PANEL)
                fillAlpha=Math.round(opacity*.93f);
            p.setColor(Color.WHITE);p.setAlpha(fillAlpha);p.setStyle(Paint.Style.FILL);p.setShader(fill);
            canvas.drawRoundRect(outer,radius,radius,p);
            p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(stroke);p.setShader(rim);p.setAlpha(opacity);
            canvas.drawRoundRect(outer,radius,radius,p);p.setShader(null);
            int border=appearance.effectiveBorderStrength();
            if(!solid&&!appearance.reducedEffects&&border>0&&(kind==Kind.MUSHAF||kind==Kind.HERO)){
                p.setColor(0xFF8EA18F);p.setAlpha(18*opacity*border/255/100);p.setStrokeWidth(stroke*.6f);
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
                case "mic":c.drawRoundRect(9,3,15,14,3,3,p);c.drawArc(5,6,19,18,0,180,false,p);c.drawLine(12,18,12,22,p);c.drawLine(8,22,16,22,p);break;
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
                case "plus":c.drawLine(12,4,12,20,p);c.drawLine(4,12,20,12,p);break;
                case "repeat":c.drawArc(4,5,20,17,205,245,false,p);c.drawLine(5,7,5,3,p);c.drawLine(5,3,9,3,p);c.drawArc(4,7,20,19,25,245,false,p);c.drawLine(19,17,19,21,p);c.drawLine(19,21,15,21,p);break;
                case "text":c.drawLine(4,6,14,6,p);c.drawLine(9,6,9,19,p);c.drawLine(17,10,21,10,p);c.drawLine(19,10,19,19,p);break;
                default:for(int i=0;i<3;i++)c.drawCircle(5+i*7,12,0.7f,p);
            }c.restore();
        }
    }
    static Drawable touch(Context c,Surface.Kind kind,boolean solid){
        int ripple=(appearance.accent&0x00ffffff)|0x24000000;
        return new RippleDrawable(ColorStateList.valueOf(ripple),new Surface(c,kind,solid),new Surface(c,Surface.Kind.PRIMARY,true));
    }
    private static boolean motionEnabled(){return !appearance.reducedEffects&&ValueAnimator.areAnimatorsEnabled();}
    static <T extends View> T motion(T view){
        if(!motionEnabled()){
            view.animate().cancel();view.setStateListAnimator(null);view.setScaleX(1f);view.setScaleY(1f);return view;
        }
        StateListAnimator states=new StateListAnimator();
        AnimatorSet pressed=new AnimatorSet();
        pressed.playTogether(ObjectAnimator.ofFloat(view,View.SCALE_X,.985f),ObjectAnimator.ofFloat(view,View.SCALE_Y,.985f));
        pressed.setDuration(70L);
        AnimatorSet released=new AnimatorSet();
        released.playTogether(ObjectAnimator.ofFloat(view,View.SCALE_X,1f),ObjectAnimator.ofFloat(view,View.SCALE_Y,1f));
        released.setDuration(135L);released.setInterpolator(new DecelerateInterpolator());
        states.addState(new int[]{android.R.attr.state_pressed},pressed);
        states.addState(new int[]{},released);
        view.setStateListAnimator(states);return view;
    }
    static <T extends View> T reveal(T view){
        if(!motionEnabled()){view.animate().cancel();view.setAlpha(1f);view.setTranslationX(0f);view.setTranslationY(0f);return view;}
        view.animate().cancel();view.setTranslationX(0f);view.setAlpha(.94f);view.setTranslationY(dp(view.getContext(),4));
        view.animate().alpha(1f).translationY(0f).setDuration(145L).setInterpolator(new DecelerateInterpolator()).start();
        return view;
    }
    static <T extends View> T revealHorizontal(T view,int direction){
        if(!motionEnabled()){view.animate().cancel();view.setAlpha(1f);view.setTranslationX(0f);view.setTranslationY(0f);return view;}
        view.animate().cancel();view.setTranslationY(0f);view.setAlpha(.96f);
        view.setTranslationX((direction<0?-1:1)*dp(view.getContext(),12));
        view.animate().alpha(1f).translationX(0f).setDuration(165L).setInterpolator(new DecelerateInterpolator()).start();
        return view;
    }
    static LinearLayout column(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.VERTICAL);return l;}
    static LinearLayout row(Context c){LinearLayout l=new LinearLayout(c);l.setOrientation(LinearLayout.HORIZONTAL);l.setGravity(Gravity.CENTER_VERTICAL);return l;}
    static TextView text(Context c,String text,float sp,int color){TextView v=new TextView(c);v.setText(text);v.setTextSize(sp);v.setTextColor(color);v.setFontFeatureSettings("kern");v.setIncludeFontPadding(true);v.setLineSpacing(dp(c,2),1.06f);return v;}
    static void pad(View v,int horizontal,int vertical){v.setPadding(dp(v.getContext(),horizontal),dp(v.getContext(),vertical),dp(v.getContext(),horizontal),dp(v.getContext(),vertical));}
}
