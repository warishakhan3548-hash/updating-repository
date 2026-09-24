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
    static final String[] PRESETS={"Emerald Glass","Ocean Blue","Rose Glass","Midnight","Lavender Aqua","Violet Glass","Burgundy Pearl","Lavender Studio","Pearl Violet","Sapphire Neon","Rose Luxe","Mint Lilac","Amethyst Night","Pearl Rose"};
    static final String[] FONTS={"Amiri Quran","Amiri Naskh","Amiri Naskh Bold","Scheherazade New","Lateef","Harmattan","Noto Naskh Arabic","Noto Kufi Arabic"};
    private static final String[] FONT_FILES={"AmiriQuran.ttf","Amiri-Regular.ttf","Amiri-Bold.ttf","ScheherazadeNew-Regular.ttf","Lateef-Regular.ttf","Harmattan-Regular.ttf","NotoNaskhArabic.ttf","NotoKufiArabic.ttf"};
    int background=0xff030705,surface=0xff14291e,accent=0xff9bc7aa,arabic=0xffe0e4d8,translation=0xffcbd6d0,appText=0xffedf1ed;
    int font=0,arabicSize=32,translationSize=18,spacing=10,opacity=92,corners=26;
    int arabicOpacity=100,translationOpacity=100,glassStrength=100,borderStrength=100,glow=0,gradientEnd=background;
    int textDepth=0,shadowSoftness=4,shadowStrength=0,textSheen=50,buttonColor=surface;
    boolean customButtons=false;
    boolean glass=true,textGlass=true,gradient=false,reducedEffects=false;
    String name=PRESETS[0];
    private static final Map<Integer,Typeface> fonts=new HashMap<>();
    static Appearance load(Context context){return decode(context.getSharedPreferences("appearance",0).getString("current","{}"));}
    static Appearance decode(String raw){
        Appearance a=new Appearance();try{JSONObject j=new JSONObject(raw);
            a.background=j.optInt("background",a.background)|0xff000000;a.surface=j.optInt("surface",a.surface)|0xff000000;
            a.accent=j.optInt("accent",a.accent)|0xff000000;a.arabic=j.optInt("arabic",a.arabic)|0xff000000;a.translation=j.optInt("translation",a.translation)|0xff000000;
            a.font=bound(j.optInt("font",0),0,FONTS.length-1);a.arabicSize=bound(j.optInt("size",32),24,54);a.translationSize=bound(j.optInt("translationSize",18),14,28);
            a.spacing=bound(j.optInt("spacing",10),2,24);a.opacity=bound(j.optInt("opacity",92),25,100);a.corners=bound(j.optInt("corners",26),0,36);
            a.arabicOpacity=bound(j.optInt("arabicOpacity",100),20,100);a.translationOpacity=bound(j.optInt("translationOpacity",100),20,100);
            a.glassStrength=bound(j.optInt("glassStrength",100),0,100);a.borderStrength=bound(j.optInt("borderStrength",100),0,100);a.glow=bound(j.optInt("glow",0),0,30);
            a.textDepth=bound(j.optInt("textDepth",0),0,12);a.shadowSoftness=bound(j.optInt("shadowSoftness",4),0,16);
            a.shadowStrength=bound(j.optInt("shadowStrength",0),0,70);a.textSheen=bound(j.optInt("textSheen",50),0,100);
            a.buttonColor=j.optInt("buttonColor",a.surface)|0xff000000;a.customButtons=j.optBoolean("customButtons",false);
            a.gradientEnd=j.optInt("gradientEnd",a.background)|0xff000000;a.gradient=j.optBoolean("gradient",false);a.reducedEffects=j.optBoolean("reducedEffects",false);
            a.glass=j.optBoolean("glass",true);a.textGlass=j.optBoolean("textGlass",true);a.name=j.optString("name",PRESETS[0]);
            a.appText=j.has("appText")?(j.optInt("appText",a.appText)|0xff000000):a.autoAppText();
        }catch(Exception ignored){}return a;
    }
    String encode(){try{return new JSONObject().put("version",4).put("background",background).put("surface",surface).put("accent",accent).put("arabic",arabic).put("translation",translation).put("appText",appText)
        .put("font",font).put("size",arabicSize).put("translationSize",translationSize).put("spacing",spacing).put("opacity",opacity).put("corners",corners)
        .put("arabicOpacity",arabicOpacity).put("translationOpacity",translationOpacity).put("glassStrength",glassStrength).put("borderStrength",borderStrength).put("glow",glow)
        .put("textDepth",textDepth).put("shadowSoftness",shadowSoftness).put("shadowStrength",shadowStrength).put("textSheen",textSheen).put("buttonColor",buttonColor).put("customButtons",customButtons)
        .put("gradient",gradient).put("gradientEnd",gradientEnd).put("reducedEffects",reducedEffects).put("glass",glass).put("textGlass",textGlass).put("name",name).toString();}catch(Exception e){throw new IllegalStateException(e);}}
    void save(Context c){c.getSharedPreferences("appearance",0).edit().putString("current",encode()).apply();}
    Appearance copy(){return decode(encode());}
    void preset(int index){
        int i=bound(index,0,PRESETS.length-1);
        font=0;arabicSize=32;translationSize=18;spacing=10;opacity=92;corners=26;
        arabicOpacity=100;translationOpacity=100;glassStrength=100;borderStrength=100;glow=0;
        textDepth=0;shadowSoftness=4;shadowStrength=0;textSheen=50;customButtons=false;
        glass=true;textGlass=true;gradient=false;reducedEffects=false;
        switch(i){
            case 0:
                palette(0xff030705,0xff14291e,0xff9bc7aa,0xffe0e4d8,0xffcbd6d0,0xff030705);
                break;
            case 1:
                palette(0xff040b17,0xff13243c,0xff84baff,0xffd9eaff,0xffc8dcf7,0xff040b17);
                break;
            case 2:
                palette(0xff130a12,0xff31192c,0xffecacd3,0xffffe0ed,0xffe8c4d8,0xff130a12);
                break;
            case 3:
                palette(0xff000000,0xff10121a,0xffacc2ff,0xffeeeeef,0xffcfd3df,0xff000000);
                glass=false;textGlass=false;borderStrength=72;
                break;
            case 4:
                palette(0xfff4f0ff,0xfffdfbff,0xff7458f4,0xff2b225a,0xff463d68,0xffe4faf4);
                gradient=true;glassStrength=86;borderStrength=66;glow=5;corners=30;opacity=95;
                break;
            case 5:
                palette(0xffeee8ff,0xfffaf8ff,0xff8057f6,0xff30256a,0xff4a4074,0xffdfd5ff);
                gradient=true;glassStrength=90;borderStrength=76;glow=6;corners=30;opacity=94;
                break;
            case 6:
                palette(0xfffff6f8,0xffffffff,0xffa51442,0xff71162f,0xff4f333d,0xfff7e1e8);
                gradient=true;glass=false;textGlass=false;borderStrength=48;corners=28;opacity=100;
                break;
            case 7:
                palette(0xff4b35bc,0xfff7f3ff,0xff58e2d2,0xff231857,0xff392d65,0xff8b6cec);
                gradient=true;glassStrength=92;borderStrength=78;glow=8;corners=30;opacity=96;
                break;
            case 8:
                palette(0xfff8f7ff,0xffffffff,0xff6d4be8,0xff251a57,0xff433a66,0xffebe6ff);
                gradient=true;glassStrength=78;borderStrength=60;glow=3;corners=30;opacity=97;
                break;
            case 9:
                palette(0xff03172d,0xff082844,0xff56d8ff,0xffeaf8ff,0xffcbe7f5,0xff0b3d65);
                gradient=true;glassStrength=94;borderStrength=90;glow=10;corners=28;opacity=94;
                break;
            case 10:
                palette(0xfffff3f6,0xffffffff,0xffc23e66,0xff8a1b3a,0xff563943,0xfff7dfe7);
                gradient=true;glassStrength=72;borderStrength=58;glow=3;corners=30;opacity=98;
                break;
            case 11:
                palette(0xfff3f6ff,0xffffffff,0xff54cdbb,0xff2a225f,0xff443d68,0xffe9e2ff);
                gradient=true;glassStrength=82;borderStrength=62;glow=4;corners=30;opacity=96;
                break;
            case 12:
                palette(0xff100b27,0xff21163f,0xffa66cff,0xfff4ecff,0xffdacdf0,0xff2a1547);
                gradient=true;glassStrength=92;borderStrength=84;glow=9;corners=28;opacity=94;
                break;
            default:
                palette(0xfffaf7ff,0xffffffff,0xffd25f9f,0xff302353,0xff51445f,0xfffcecf5);
                gradient=true;glassStrength=76;borderStrength=58;glow=4;corners=30;opacity=97;
                break;
        }
        appText=autoAppText();name=PRESETS[i];
    }
    private void palette(int bg,int card,int highlight,int arabicInk,int translationInk,int end){
        background=bg;surface=card;buttonColor=card;accent=highlight;arabic=arabicInk;translation=translationInk;gradientEnd=end;
    }
    int buttonSurface(){return customButtons?mix(background,buttonColor,opacity/100f):effectiveSurface();}
    int buttonInk(){
        int base=buttonSurface(),primary=mix(base,accent,.15f),highlight=mix(primary,accent,.06f*glassStrength/100f);
        return readableAcross(appText,base,highlight);
    }
    int glassInk(float amount){return textInk(mix(arabicInk(),Color.WHITE,amount),100);}
    int effectiveSurface(){return mix(background,surface,opacity/100f);}
    int surfaceHighlight(){return glass&&!reducedEffects?mix(effectiveSurface(),accent,.06f*glassStrength/100f):effectiveSurface();}
    int arabicInk(){return textInk(arabic,arabicOpacity);}
    int translationInk(){return textInk(translation,translationOpacity);}
    private int textInk(int color,int alpha){
        int on=effectiveSurface(),end=surfaceHighlight(),requested=mix(on,color,alpha/100f);
        if(contrast(requested,on)>=4.5&&contrast(requested,end)>=4.5)return requested;
        int target=Math.min(contrast(Color.WHITE,on),contrast(Color.WHITE,end))>Math.min(contrast(Color.BLACK,on),contrast(Color.BLACK,end))?Color.WHITE:Color.BLACK;
        for(int n=1;n<=40;n++){int fixed=mix(requested,target,n/40f);if(contrast(fixed,on)>=4.5&&contrast(fixed,end)>=4.5)return fixed;}return target;
    }
    boolean adjustedText(){return arabicInk()!=mix(effectiveSurface(),arabic,arabicOpacity/100f)||translationInk()!=mix(effectiveSurface(),translation,translationOpacity/100f)||appInk()!=appText;}
    private int autoAppText(){
        int on=effectiveSurface();
        return luminance(on)>.38?0xff16202a:0xffedf1ed;
    }
    int appInk(){return readableAcross(appText,background,effectiveSurface(),surfaceHighlight());}
    int ink(){return appInk();}
    int muted(){return readableAcross(mix(appInk(),effectiveSurface(),.30f),background,effectiveSurface(),surfaceHighlight());}
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
