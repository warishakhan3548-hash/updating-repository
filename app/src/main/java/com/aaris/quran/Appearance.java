package com.aaris.quran;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import org.json.JSONObject;
import java.util.HashMap;
import java.util.Map;

/** One persisted visual model for the reader, sheets, navigation and recall surfaces. */
final class Appearance {
    static final int TEXT_PLAIN=0,TEXT_SOFT=1,TEXT_GLASS=2,TEXT_FOIL=3;
    static final String[] TEXT_FINISHES={"Plain","Soft","Glass","Foil"};
    static final String[] PRESETS={"Moonlit Emerald","Light Parchment","Rose Dusk","Ivory Mint","Moonlit Sapphire"};
    static final String[] FONTS={"Amiri Quran","Amiri Naskh","Amiri Naskh Bold","Scheherazade New","Lateef","Harmattan","Noto Naskh Arabic","Noto Kufi Arabic"};
    private static final String[] FONT_FILES={"AmiriQuran.ttf","Amiri-Regular.ttf","Amiri-Bold.ttf","ScheherazadeNew-Regular.ttf","Lateef-Regular.ttf","Harmattan-Regular.ttf","NotoNaskhArabic.ttf","NotoKufiArabic.ttf"};
    int background=0xff021411,surface=0xff0b2a24,accent=0xffd8ba72,arabic=0xffffedcf,translation=0xffeee5d7,appText=0xfff5eddf;
    int font=0,arabicSize=36,translationSize=18,spacing=11,opacity=86,corners=30;
    int arabicOpacity=100,translationOpacity=100,glassStrength=90,borderStrength=68,glow=2,gradientEnd=0xff073c34;
    int textDepth=1,shadowSoftness=6,shadowStrength=14,textSheen=34,buttonColor=0xff103a32;
    int textFinish=TEXT_GLASS,shadowAngle=45,shadowDistance=2,shadowColor=0xff000000,gradientAngle=45;
    int scene=2,sceneStrength=100;
    boolean customButtons=true,autoShadowColor=true,autoBalance=true;
    boolean glass=true,textGlass=true,gradient=true,reducedEffects=false;
    String name=PRESETS[0];
    private static final Map<Integer,Typeface> fonts=new HashMap<>();
    static Appearance load(Context context){return decode(context.getSharedPreferences("appearance",0).getString("current","{}"));}
    static Appearance decode(String raw){
        Appearance a=new Appearance();try{JSONObject j=new JSONObject(raw);
            a.background=j.optInt("background",a.background)|0xff000000;a.surface=j.optInt("surface",a.surface)|0xff000000;
            a.accent=j.optInt("accent",a.accent)|0xff000000;a.arabic=j.optInt("arabic",a.arabic)|0xff000000;a.translation=j.optInt("translation",a.translation)|0xff000000;
            a.font=bound(j.optInt("font",a.font),0,FONTS.length-1);a.arabicSize=bound(j.optInt("size",a.arabicSize),24,54);a.translationSize=bound(j.optInt("translationSize",a.translationSize),14,28);
            a.spacing=bound(j.optInt("spacing",a.spacing),2,24);a.opacity=bound(j.optInt("opacity",a.opacity),25,100);a.corners=bound(j.optInt("corners",a.corners),0,36);
            a.arabicOpacity=bound(j.optInt("arabicOpacity",a.arabicOpacity),20,100);a.translationOpacity=bound(j.optInt("translationOpacity",a.translationOpacity),20,100);
            a.glassStrength=bound(j.optInt("glassStrength",a.glassStrength),0,100);a.borderStrength=bound(j.optInt("borderStrength",a.borderStrength),0,100);a.glow=bound(j.optInt("glow",a.glow),0,30);
            a.textDepth=bound(j.optInt("textDepth",a.textDepth),0,12);a.shadowSoftness=bound(j.optInt("shadowSoftness",a.shadowSoftness),0,16);
            a.scene=bound(j.optInt("scene",a.scene),0,5);a.sceneStrength=bound(j.optInt("sceneStrength",a.sceneStrength),0,100);
            a.shadowStrength=bound(j.optInt("shadowStrength",a.shadowStrength),0,70);a.textSheen=bound(j.optInt("textSheen",a.textSheen),0,100);
            a.textFinish=j.has("textFinish")?bound(j.optInt("textFinish",a.textFinish),TEXT_PLAIN,TEXT_FOIL):(j.optBoolean("textGlass",a.textGlass)?TEXT_GLASS:TEXT_PLAIN);
            a.shadowAngle=bound(j.optInt("shadowAngle",a.shadowAngle),0,359);a.shadowDistance=bound(j.optInt("shadowDistance",a.shadowDistance),0,20);
            a.shadowColor=j.optInt("shadowColor",a.shadowColor)|0xff000000;a.autoShadowColor=j.optBoolean("autoShadowColor",a.autoShadowColor);
            a.gradientAngle=bound(j.optInt("gradientAngle",a.gradientAngle),0,359);a.autoBalance=j.optBoolean("autoBalance",a.autoBalance);
            a.buttonColor=j.optInt("buttonColor",a.buttonColor)|0xff000000;a.customButtons=j.optBoolean("customButtons",a.customButtons);
            a.gradientEnd=j.optInt("gradientEnd",a.gradientEnd)|0xff000000;a.gradient=j.optBoolean("gradient",a.gradient);a.reducedEffects=j.optBoolean("reducedEffects",a.reducedEffects);
            a.glass=j.optBoolean("glass",a.glass);a.textGlass=a.textFinish==TEXT_GLASS;a.name=j.optString("name",a.name);
            a.appText=j.has("appText")?(j.optInt("appText",a.appText)|0xff000000):a.autoAppText();
        }catch(Exception ignored){}return a;
    }
    String encode(){try{return new JSONObject().put("version",9).put("background",background).put("surface",surface).put("accent",accent).put("arabic",arabic).put("translation",translation).put("appText",appText)
        .put("font",font).put("size",arabicSize).put("translationSize",translationSize).put("spacing",spacing).put("opacity",opacity).put("corners",corners)
        .put("arabicOpacity",arabicOpacity).put("translationOpacity",translationOpacity).put("glassStrength",glassStrength).put("borderStrength",borderStrength).put("glow",glow)
        .put("textDepth",textDepth).put("shadowSoftness",shadowSoftness).put("shadowStrength",shadowStrength).put("textSheen",textSheen).put("textFinish",textFinish)
        .put("shadowAngle",shadowAngle).put("shadowDistance",shadowDistance).put("shadowColor",shadowColor).put("autoShadowColor",autoShadowColor)
        .put("gradientAngle",gradientAngle).put("autoBalance",autoBalance).put("buttonColor",buttonColor).put("customButtons",customButtons)
        .put("gradient",gradient).put("gradientEnd",gradientEnd).put("reducedEffects",reducedEffects).put("glass",glass).put("textGlass",textFinish==TEXT_GLASS)
        .put("scene",scene).put("sceneStrength",sceneStrength).put("name",name).toString();}catch(Exception e){throw new IllegalStateException(e);}}
    void save(Context c){c.getSharedPreferences("appearance",0).edit().putString("current",encode()).apply();}
    Appearance copy(){return decode(encode());}
    void preset(int index){
        int i=bound(index,0,PRESETS.length-1);
        font=0;arabicSize=36;translationSize=18;spacing=11;opacity=92;corners=28;
        arabicOpacity=100;translationOpacity=100;glassStrength=86;borderStrength=72;glow=0;
        textDepth=1;shadowSoftness=6;shadowStrength=10;textSheen=30;customButtons=true;
        textFinish=TEXT_GLASS;shadowAngle=45;shadowDistance=2;shadowColor=0xff000000;autoShadowColor=true;gradientAngle=45;autoBalance=true;
        reducedEffects=false;sceneStrength=100;
        switch(i){
            case 0: // Moonlit Emerald: deep green night, ivory Quran ink and warm lantern gold.
                palette(0xff021411,0xff0b2a24,0xffd8ba72,0xffffedcf,0xffeee5d7,0xff073c34);
                appText=0xfff5eddf;buttonColor=0xff103a32;
                glass=true;textGlass=true;gradient=true;scene=2;opacity=86;
                glassStrength=90;borderStrength=68;glow=2;textSheen=34;
                shadowStrength=14;shadowSoftness=6;corners=30;
                break;
            case 1: // Image 3: warm parchment courtyard with dark emerald Quran text.
                palette(0xffe8c991,0xffffefd0,0xffb9852e,0xff123b2c,0xff39412d,0xfff6e3b5);
                appText=0xff17372f;buttonColor=0xfff4dfb7;
                font=0;arabicSize=38;translationSize=18;spacing=11;
                glass=false;textGlass=false;gradient=true;scene=1;opacity=97;
                glassStrength=12;borderStrength=46;glow=0;textSheen=0;
                textDepth=0;shadowStrength=0;shadowSoftness=3;corners=28;
                break;
            case 2: // Selected Image 3: deep rose/burgundy sunset with warm cream scripture.
                palette(0xff210d14,0xff4a202d,0xffff9b80,0xffffefd9,0xffffe8df,0xff6f273a);
                appText=0xffffeee5;buttonColor=0xff552532;
                font=0;arabicSize=38;translationSize=18;spacing=11;
                glass=true;textGlass=true;gradient=true;scene=3;opacity=83;
                glassStrength=90;borderStrength=66;glow=1;textSheen=26;
                textDepth=1;shadowStrength=14;shadowSoftness=6;corners=30;
                break;
            case 3: // Selected Image 5: airy ivory/mint daylight with botanical calm.
                palette(0xfff3f2e8,0xfffbfaf2,0xff2c8b6f,0xff07483b,0xff445c52,0xffe6eee3);
                appText=0xff123f35;buttonColor=0xffedf3e9;
                font=0;arabicSize=38;translationSize=18;spacing=12;
                glass=false;textGlass=false;gradient=true;scene=4;opacity=97;
                glassStrength=10;borderStrength=30;glow=0;textSheen=0;
                textDepth=0;shadowStrength=0;shadowSoftness=3;corners=28;
                break;
            default: // Selected blue Image 1: sapphire night, white scripture, luminous blue glass.
                palette(0xff03162f,0xff0b3f7a,0xff58b8ff,0xffffffff,0xffe7f3ff,0xff062656);
                appText=0xfff5fbff;buttonColor=0xff0b4a8f;
                font=0;arabicSize=39;translationSize=18;spacing=12;
                glass=true;textGlass=true;gradient=true;scene=5;opacity=79;
                glassStrength=94;borderStrength=86;glow=2;textSheen=28;
                textDepth=1;shadowStrength=16;shadowSoftness=7;corners=30;
                break;
        }
        textFinish=textGlass?TEXT_GLASS:TEXT_PLAIN;
        name=PRESETS[i];
    }
    private void palette(int bg,int card,int highlight,int arabicInk,int translationInk,int end){
        background=bg;surface=card;buttonColor=card;accent=highlight;arabic=arabicInk;translation=translationInk;gradientEnd=end;
    }
    int buttonSurface(){return customButtons?mix(background,buttonColor,opacity/100f):effectiveSurface();}
    int effectiveCardOpacity(){
        if(!autoBalance||!gradient)return opacity;
        double spread=contrast(background,gradientEnd);
        int floor=spread>=4.0?62:spread>=2.5?48:25;
        return Math.max(opacity,floor);
    }
    int effectiveBorderStrength(){
        if(!autoBalance||!glass)return borderStrength;
        int transparency=100-effectiveCardOpacity();
        return Math.max(borderStrength,bound(28+(transparency/2),28,68));
    }
    int effectiveShadowStrength(){
        if(!autoBalance)return shadowStrength;
        int cap=textFinish==TEXT_PLAIN?28:textFinish==TEXT_SOFT?36:52;
        return Math.min(shadowStrength,cap);
    }
    int resolvedShadowColor(){
        if(!autoShadowColor)return shadowColor;
        int base=effectiveSurface();
        return luminance(base)>.46?0xff000000:mix(0xff000000,accent,.12f);
    }
    float shadowDx(float density){return (float)(Math.cos(Math.toRadians(shadowAngle))*shadowDistance*density);}
    float shadowDy(float density){return (float)(Math.sin(Math.toRadians(shadowAngle))*shadowDistance*density);}
    void autoBalanceEffects(){
        if(glass)borderStrength=Math.max(borderStrength,bound(28+(100-opacity)/2,28,68));
        shadowStrength=bound(shadowStrength,0,textFinish==TEXT_PLAIN?28:52);shadowSoftness=bound(shadowSoftness,0,12);
        if(textFinish==TEXT_FOIL)textSheen=Math.max(textSheen,48);
        if(textFinish==TEXT_SOFT)textSheen=bound(textSheen,12,55);
        if(reducedEffects){shadowStrength=Math.min(shadowStrength,10);glow=0;}
    }
    int buttonInk(){
        int base=buttonSurface(),primary=mix(base,accent,.15f),highlight=mix(primary,accent,.06f*glassStrength/100f);
        return readableAcross(appText,base,highlight);
    }
    int glassInk(float amount){return textInk(mix(arabicInk(),Color.WHITE,amount),100);}
    int foilInk(float amount){return readableAcross(mix(arabicInk(),accent,amount),effectiveSurface(),surfaceHighlight(),effectiveSurfaceAtGradientEnd());}
    int effectiveSurface(){return effectiveSurfaceOn(background);}
    int effectiveSurfaceAtGradientEnd(){return gradient?effectiveSurfaceOn(gradientEnd):effectiveSurface();}
    private int effectiveSurfaceOn(int backdrop){return mix(backdrop,surface,effectiveCardOpacity()/100f);}
    int surfaceHighlight(){return glass&&!reducedEffects?mix(effectiveSurface(),accent,.06f*glassStrength/100f):effectiveSurface();}
    int arabicInk(){return textInk(arabic,arabicOpacity);}
    int translationInk(){return textInk(translation,translationOpacity);}
    private int textInk(int color,int alpha){
        int on=effectiveSurface(),end=surfaceHighlight(),gradientSurface=effectiveSurfaceAtGradientEnd(),requested=mix(on,color,alpha/100f);
        if(contrast(requested,on)>=4.5&&contrast(requested,end)>=4.5&&contrast(requested,gradientSurface)>=4.5)return requested;
        double white=Math.min(contrast(Color.WHITE,on),Math.min(contrast(Color.WHITE,end),contrast(Color.WHITE,gradientSurface)));
        double black=Math.min(contrast(Color.BLACK,on),Math.min(contrast(Color.BLACK,end),contrast(Color.BLACK,gradientSurface)));
        int target=white>black?Color.WHITE:Color.BLACK;
        for(int n=1;n<=40;n++){int fixed=mix(requested,target,n/40f);if(contrast(fixed,on)>=4.5&&contrast(fixed,end)>=4.5&&contrast(fixed,gradientSurface)>=4.5)return fixed;}return target;
    }
    boolean adjustedText(){return arabicInk()!=mix(effectiveSurface(),arabic,arabicOpacity/100f)||translationInk()!=mix(effectiveSurface(),translation,translationOpacity/100f)||appInk()!=appText;}
    String readabilitySummary(){
        double arabicScore=minContrast(arabicInk()),translationScore=minContrast(translationInk()),uiScore=minContrast(appInk());
        return "Arabic "+grade(arabicScore)+" · Translation "+grade(translationScore)+" · UI "+grade(uiScore)+(adjustedText()?" · Auto-adjusted":"");
    }
    private double minContrast(int ink){return Math.min(contrast(ink,effectiveSurface()),Math.min(contrast(ink,surfaceHighlight()),contrast(ink,effectiveSurfaceAtGradientEnd())));}
    private static String grade(double ratio){return ratio>=7.0?"AAA":ratio>=4.5?"AA":"Protected";}
    private int autoAppText(){
        int on=effectiveSurface();
        return luminance(on)>.38?0xff16202a:0xffedf1ed;
    }
    int appInk(){return readableAcross(appText,background,gradient?gradientEnd:background,effectiveSurface(),effectiveSurfaceAtGradientEnd(),surfaceHighlight());}
    int ink(){return appInk();}
    int muted(){return readableAcross(mix(appInk(),effectiveSurface(),.30f),background,gradient?gradientEnd:background,effectiveSurface(),effectiveSurfaceAtGradientEnd(),surfaceHighlight());}
    static int bound(int x,int lo,int hi){return Math.max(lo,Math.min(hi,x));}
    static int mix(int a,int b,float t){return Color.rgb(Math.round(Color.red(a)*(1-t)+Color.red(b)*t),Math.round(Color.green(a)*(1-t)+Color.green(b)*t),Math.round(Color.blue(a)*(1-t)+Color.blue(b)*t));}
    static double luminance(int c){double v=0;double[] weights={.2126,.7152,.0722};int[] rgb={Color.red(c),Color.green(c),Color.blue(c)};for(int i=0;i<3;i++){double x=rgb[i]/255.;v+=weights[i]*(x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4));}return v;}
    static double contrast(int a,int b){double x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);}
    static int readable(int color,int on){if(contrast(color,on)>=4.5)return color;int target=contrast(Color.WHITE,on)>contrast(Color.BLACK,on)?Color.WHITE:Color.BLACK;for(int n=1;n<=20;n++){int fixed=mix(color,target,n/20f);if(contrast(fixed,on)>=4.5)return fixed;}return target;}
    static int readableAcross(int color,int... surfaces){
        if(surfaces==null||surfaces.length==0)return color;
        boolean ok=true;for(int on:surfaces)if(contrast(color,on)<4.5){ok=false;break;}if(ok)return color;
        double white=Double.MAX_VALUE,black=Double.MAX_VALUE;
        for(int on:surfaces){white=Math.min(white,contrast(Color.WHITE,on));black=Math.min(black,contrast(Color.BLACK,on));}
        int target=white>=black?Color.WHITE:Color.BLACK;
        for(int n=1;n<=40;n++){
            int fixed=mix(color,target,n/40f);boolean readable=true;
            for(int on:surfaces)if(contrast(fixed,on)<4.5){readable=false;break;}
            if(readable)return fixed;
        }
        return target;
    }
    Typeface hadithTypeface(Context c){return typeface(c);}
    Typeface typeface(Context c){return typeface(c,font);}
    private static Typeface typeface(Context c,int font){
        int index=bound(font,0,FONT_FILES.length-1);
        synchronized(fonts){
            Typeface type=fonts.get(index);
            if(type==null){
                type=Typeface.createFromAsset(c.getAssets(),"fonts/"+FONT_FILES[index]);
                fonts.put(index,type);
            }
            return type;
        }
    }
}
