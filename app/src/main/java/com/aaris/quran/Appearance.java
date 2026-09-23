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
    static final String[] PRESETS={"Emerald Glass","Ocean Blue","Rose Glass","Midnight","Clean White","Warm Paper","Easy Reading"};
    static final String[] FONTS={"Amiri Quran","Amiri Naskh","Amiri Naskh Bold"};
    int background=0xff030705,surface=0xff14291e,accent=0xff9bc7aa,arabic=0xffe0e4d8,translation=0xffcbd6d0;
    int font=0,arabicSize=32,translationSize=18,spacing=10,opacity=92,corners=26;
    int arabicOpacity=100,translationOpacity=100,glassStrength=100,borderStrength=100,glow=0,gradientEnd=background;
    boolean glass=true,textGlass=true,gradient=false,reducedEffects=false;
    String name=PRESETS[0];
    private static final Map<Integer,Typeface> fonts=new HashMap<>();
    static Appearance load(Context context){return decode(context.getSharedPreferences("appearance",0).getString("current","{}"));}
    static Appearance decode(String raw){
        Appearance a=new Appearance();try{JSONObject j=new JSONObject(raw);
            a.background=j.optInt("background",a.background)|0xff000000;a.surface=j.optInt("surface",a.surface)|0xff000000;
            a.accent=j.optInt("accent",a.accent)|0xff000000;a.arabic=j.optInt("arabic",a.arabic)|0xff000000;a.translation=j.optInt("translation",a.translation)|0xff000000;
            a.font=bound(j.optInt("font",0),0,2);a.arabicSize=bound(j.optInt("size",32),24,54);a.translationSize=bound(j.optInt("translationSize",18),14,28);
            a.spacing=bound(j.optInt("spacing",10),2,24);a.opacity=bound(j.optInt("opacity",92),25,100);a.corners=bound(j.optInt("corners",26),0,36);
            a.arabicOpacity=bound(j.optInt("arabicOpacity",100),20,100);a.translationOpacity=bound(j.optInt("translationOpacity",100),20,100);
            a.glassStrength=bound(j.optInt("glassStrength",100),0,100);a.borderStrength=bound(j.optInt("borderStrength",100),0,100);a.glow=bound(j.optInt("glow",0),0,30);
            a.gradientEnd=j.optInt("gradientEnd",a.background)|0xff000000;a.gradient=j.optBoolean("gradient",false);a.reducedEffects=j.optBoolean("reducedEffects",false);
            a.glass=j.optBoolean("glass",true);a.textGlass=j.optBoolean("textGlass",true);a.name=j.optString("name",PRESETS[0]);
        }catch(Exception ignored){}return a;
    }
    String encode(){try{return new JSONObject().put("version",2).put("background",background).put("surface",surface).put("accent",accent).put("arabic",arabic).put("translation",translation)
        .put("font",font).put("size",arabicSize).put("translationSize",translationSize).put("spacing",spacing).put("opacity",opacity).put("corners",corners)
        .put("arabicOpacity",arabicOpacity).put("translationOpacity",translationOpacity).put("glassStrength",glassStrength).put("borderStrength",borderStrength).put("glow",glow)
        .put("gradient",gradient).put("gradientEnd",gradientEnd).put("reducedEffects",reducedEffects).put("glass",glass).put("textGlass",textGlass).put("name",name).toString();}catch(Exception e){throw new IllegalStateException(e);}}
    void save(Context c){c.getSharedPreferences("appearance",0).edit().putString("current",encode()).apply();}
    Appearance copy(){return decode(encode());}
    void preset(int index){
        int[][] palettes={{0xff030705,0xff14291e,0xff9bc7aa,0xffe0e4d8},{0xff040b17,0xff13243c,0xff84baff,0xffd9eaff},
            {0xff130a12,0xff31192c,0xffecacd3,0xffffe0ed},{0xff000000,0xff10121a,0xffacc2ff,0xffeeeeef},
            {0xfff4f6f9,0xffffffff,0xff215db0,0xff182d45},{0xfff1e9da,0xfffff7e7,0xff78512e,0xff322b21},{0xfffaf8f2,0xfffffdf7,0xff285c49,0xff15261d}};
        int i=bound(index,0,palettes.length-1);int[] p=palettes[i];background=p[0];surface=p[1];accent=p[2];arabic=p[3];translation=p[3];
        name=PRESETS[i];glass=i<3;textGlass=i<3;opacity=92;arabicOpacity=100;translationOpacity=100;glassStrength=100;borderStrength=100;glow=0;
        gradient=false;gradientEnd=background;reducedEffects=i==6;
        if(i==6){font=2;arabicSize=38;translationSize=21;spacing=16;opacity=100;}
    }
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
    boolean adjustedText(){return arabicInk()!=mix(effectiveSurface(),arabic,arabicOpacity/100f)||translationInk()!=mix(effectiveSurface(),translation,translationOpacity/100f);}
    int ink(){return readable(luminance(effectiveSurface())>.38?0xff16202a:0xffedf1ed,effectiveSurface());}
    int muted(){return readable(mix(ink(),effectiveSurface(),.25f),effectiveSurface());}
    static int bound(int x,int lo,int hi){return Math.max(lo,Math.min(hi,x));}
    static int mix(int a,int b,float t){return Color.rgb(Math.round(Color.red(a)*(1-t)+Color.red(b)*t),Math.round(Color.green(a)*(1-t)+Color.green(b)*t),Math.round(Color.blue(a)*(1-t)+Color.blue(b)*t));}
    static double luminance(int c){double v=0;double[] weights={.2126,.7152,.0722};int[] rgb={Color.red(c),Color.green(c),Color.blue(c)};for(int i=0;i<3;i++){double x=rgb[i]/255.;v+=weights[i]*(x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4));}return v;}
    static double contrast(int a,int b){double x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);}
    static int readable(int color,int on){if(contrast(color,on)>=4.5)return color;int target=contrast(Color.WHITE,on)>contrast(Color.BLACK,on)?Color.WHITE:Color.BLACK;for(int n=1;n<=20;n++){int fixed=mix(color,target,n/20f);if(contrast(fixed,on)>=4.5)return fixed;}return target;}
    Typeface typeface(Context c){synchronized(fonts){Typeface type=fonts.get(font);if(type==null){String file=font==1?"Amiri-Regular.ttf":font==2?"Amiri-Bold.ttf":"AmiriQuran.ttf";type=Typeface.createFromAsset(c.getAssets(),"fonts/"+file);fonts.put(font,type);}return type;}}
}
