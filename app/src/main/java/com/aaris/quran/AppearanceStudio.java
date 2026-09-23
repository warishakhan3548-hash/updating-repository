package com.aaris.quran;

import android.app.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import java.util.*;
import static com.aaris.quran.Glass.*;

/** Photo-editor style controls; preview uses the same typeface and surface renderer as reading. */
final class AppearanceStudio {
    private final Activity activity;
    private final Dialog dialog;
    private Appearance style;
    private final String sample,translationSample;
    private final boolean translationRtl;
    private final LinearLayout preview,controls,toolbar;
    private final List<String> history=new ArrayList<>();
    private int historyIndex=0,layer=0;
    private boolean binding,advanced;
    private final Runnable applied;
    static Dialog show(Activity activity,String sample,String translated,boolean rtl,Runnable applied){return new AppearanceStudio(activity,sample,translated,rtl,applied).dialog;}
    private AppearanceStudio(Activity a,String sample,String translated,boolean rtl,Runnable applied){
        activity=a;this.sample=sample;translationSample=translated;translationRtl=rtl;this.applied=applied;style=Appearance.load(a);history.add(style.encode());
        dialog=new Dialog(a);dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);LinearLayout root=column(a);pad(root,16,12);root.setBackgroundColor(0xff10171e);
        toolbar=row(a);TextView heading=text(a,"Appearance",23,0xffedf1ed);toolbar.addView(heading,new LinearLayout.LayoutParams(0,-2,1));
        toolbar.addView(action("Done",dialog::dismiss));root.addView(toolbar);
        preview=column(a);pad(preview,18,14);ScrollView previewScroll=new ScrollView(a);previewScroll.addView(preview);root.addView(previewScroll,new LinearLayout.LayoutParams(-1,Math.min(dp(a,300),a.getResources().getDisplayMetrics().heightPixels*45/100)));
        ScrollView scroll=new ScrollView(a);controls=column(a);pad(controls,0,10);scroll.addView(controls);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        dialog.setContentView(root);dialog.setOnDismissListener(d->{style.save(a);Glass.apply(style);applied.run();});dialog.show();
        Window window=dialog.getWindow();if(window!=null){window.setLayout(-1,-1);window.setBackgroundDrawableResource(android.R.color.transparent);}
        refresh();renderControls();
    }
    private TextView action(String label,Runnable run){TextView b=text(activity,label,14,INK);b.setTag("action");pad(b,12,10);b.setGravity(Gravity.CENTER);b.setMinHeight(dp(activity,48));b.setBackground(Glass.touch(activity,Glass.Surface.Kind.BUTTON,false));b.setOnClickListener(v->run.run());b.setFocusable(true);return b;}
    private void title(String label){TextView t=text(activity,label,13,GOLD);pad(t,2,12);controls.addView(t);}
    private void refresh(){
        Glass.apply(style);preview.removeAllViews();preview.setBackground(new Glass.Surface(activity,Glass.Surface.Kind.MUSHAF,false));
        preview.addView(text(activity,"LIVE PREVIEW · 1:1",11,MUTED));
        ArabicText arabic=new ArabicText(activity);arabic.setText(sample);arabic.setTypeface(style.typeface(activity));arabic.setTextSize(style.arabicSize);
        arabic.setTextDirection(View.TEXT_DIRECTION_RTL);arabic.setGravity(Gravity.CENTER);arabic.setLineSpacing(dp(activity,style.spacing),1.08f);arabic.setReliefEnabled(style.textGlass);preview.addView(arabic);
        TextView translation=text(activity,translationSample,style.translationSize,style.translationInk());translation.setTextDirection(translationRtl?View.TEXT_DIRECTION_RTL:View.TEXT_DIRECTION_FIRST_STRONG);translation.setGravity(translationRtl?Gravity.RIGHT:Gravity.LEFT);preview.addView(translation);
        LinearLayout actions=row(activity);for(String icon:new String[]{"play","bookmark","share"}){Glass.Icon v=new Glass.Icon(activity,icon);actions.addView(v,new LinearLayout.LayoutParams(dp(activity,48),dp(activity,38)));}preview.addView(actions);
        boolean adjusted=style.adjustedText();
        preview.addView(text(activity,adjusted?"Text contrast adjusted for readable letters":"Your colors · Clear letters · Offline fonts",11,MUTED));
        if(style.gradient&&!style.reducedEffects)((View)preview.getParent()).setBackground(new android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TL_BR,new int[]{style.background,style.gradientEnd}));
        else ((View)preview.getParent()).setBackgroundColor(style.background);
        recolor(controls);recolor(toolbar);

    }
    private void recolor(View view){
        if("keepColor".equals(view.getTag()))return;
        if(view instanceof TextView){TextView t=(TextView)view;
            if("action".equals(view.getTag())||view.getTag() instanceof Integer){t.setBackground(Glass.touch(activity,Glass.Surface.Kind.BUTTON,false));t.setTextColor(Appearance.readable(view.getTag() instanceof Integer?(Integer)view.getTag():style.ink(),style.effectiveSurface()));}
            else if(view.getBackground()==null)t.setTextColor(0xffedf1ed);
        }
        if(view instanceof ViewGroup){ViewGroup group=(ViewGroup)view;for(int i=0;i<group.getChildCount();i++)recolor(group.getChildAt(i));}
    }
    private void commit(){
        String encoded=style.encode();if(!encoded.equals(history.get(historyIndex))){while(history.size()>historyIndex+1)history.remove(history.size()-1);history.add(encoded);if(history.size()>30)history.remove(0);historyIndex=history.size()-1;}
        style.save(activity);refresh();
    }
    private View presetCard(Appearance swatch,boolean selected,String label,Runnable run){
        LinearLayout card=column(activity);pad(card,9,8);card.setGravity(Gravity.CENTER_HORIZONTAL);card.setTag("keepColor");
        int cardTone=Appearance.mix(swatch.background,swatch.gradient?swatch.gradientEnd:swatch.surface,.45f);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable(
            android.graphics.drawable.GradientDrawable.Orientation.TL_BR,
            swatch.gradient?new int[]{swatch.background,swatch.gradientEnd}:new int[]{swatch.background,swatch.surface});
        bg.setCornerRadius(dp(activity,20));bg.setStroke(dp(activity,selected?2:1),selected?swatch.accent:Appearance.mix(swatch.accent,cardTone,.55f));card.setBackground(bg);
        TextView mini=text(activity,"بِسْمِ",17,swatch.arabicInk());mini.setTypeface(swatch.typeface(activity));mini.setGravity(Gravity.CENTER);mini.setTextDirection(View.TEXT_DIRECTION_RTL);
        android.graphics.drawable.GradientDrawable miniBg=new android.graphics.drawable.GradientDrawable();miniBg.setColor(swatch.effectiveSurface());miniBg.setCornerRadius(dp(activity,12));miniBg.setStroke(dp(activity,1),Appearance.mix(swatch.accent,swatch.surface,.55f));mini.setBackground(miniBg);
        card.addView(mini,new LinearLayout.LayoutParams(-1,dp(activity,36)));
        TextView name=text(activity,(selected?"✓ ":"")+label,12,Appearance.readable(swatch.ink(),cardTone));name.setGravity(Gravity.CENTER);pad(name,2,5);card.addView(name,new LinearLayout.LayoutParams(-1,-2));
        card.setContentDescription(label+" appearance preset");card.setFocusable(true);card.setClickable(true);card.setOnClickListener(v->run.run());return card;
    }
    private static final String[] LAYER_NAMES={"Background","Card background","Arabic text","Translation text","Buttons & accents","Gradient end"};
    private View layerChip(int index){
        boolean selected=layer==index;int base=selected?Appearance.mix(style.effectiveSurface(),style.accent,.18f):style.effectiveSurface();
        TextView chip=text(activity,(selected?"✓ ":"")+LAYER_NAMES[index],12,Appearance.readable(selected?style.accent:style.ink(),base));
        chip.setTag("keepColor");chip.setGravity(Gravity.CENTER);chip.setMinHeight(dp(activity,48));pad(chip,12,8);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(base);bg.setCornerRadius(dp(activity,18));
        bg.setStroke(dp(activity,selected?2:1),selected?style.accent:Appearance.mix(style.accent,style.effectiveSurface(),.68f));chip.setBackground(bg);
        chip.setContentDescription("Edit "+LAYER_NAMES[index]);chip.setFocusable(true);chip.setOnClickListener(v->{if(layer!=index){layer=index;renderControls();}});
        return chip;
    }
    private View colorSwatch(String label,int value){
        boolean selected=colorDistance(color(),value)<34;
        TextView sw=text(activity,(selected?"✓ ":"")+label,12,Appearance.readable(style.ink(),value));
        sw.setTag("keepColor");sw.setGravity(Gravity.CENTER);sw.setMinHeight(dp(activity,52));pad(sw,11,8);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(value);bg.setCornerRadius(dp(activity,18));
        bg.setStroke(dp(activity,selected?3:1),selected?style.accent:Appearance.mix(value,style.ink(),.28f));sw.setBackground(bg);
        sw.setContentDescription(label+" color for "+LAYER_NAMES[layer]);sw.setFocusable(true);sw.setOnClickListener(v->{color(value);style.name="My style";commit();renderControls();});
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,86),dp(activity,52));p.rightMargin=dp(activity,7);sw.setLayoutParams(p);return sw;
    }
    private int colorDistance(int a,int b){int dr=Color.red(a)-Color.red(b),dg=Color.green(a)-Color.green(b),db=Color.blue(a)-Color.blue(b);return (int)Math.sqrt(dr*dr+dg*dg+db*db);}
    private void renderControls(){
        binding=true;controls.removeAllViews();
        title("Start with a look");HorizontalScrollView presets=new HorizontalScrollView(activity);presets.setHorizontalScrollBarEnabled(false);LinearLayout strip=row(activity);
        for(int i=0;i<Appearance.PRESETS.length;i++){final int index=i;Appearance swatch=style.copy();swatch.preset(i);View b=presetCard(swatch,style.name.equals(Appearance.PRESETS[i]),Appearance.PRESETS[i],()->{style.preset(index);commit();renderControls();});LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,138),dp(activity,92));p.rightMargin=dp(activity,9);strip.addView(b,p);}presets.addView(strip);controls.addView(presets);
        title("Choose what to change");
        HorizontalScrollView layerScroll=new HorizontalScrollView(activity);layerScroll.setHorizontalScrollBarEnabled(false);LinearLayout layerStrip=row(activity);
        for(int i=0;i<LAYER_NAMES.length;i++){View chip=layerChip(i);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-2,dp(activity,48));p.rightMargin=dp(activity,7);layerStrip.addView(chip,p);}layerScroll.addView(layerStrip);controls.addView(layerScroll);
        TextView editing=text(activity,"Editing · "+LAYER_NAMES[layer]+" · tap a color, then use the sliders",12,MUTED);editing.setTag("keepColor");editing.setTextColor(0xffb9c4cc);pad(editing,2,8);controls.addView(editing);

        title("Seven-color spectrum");
        int[] spectrum={0xffd64b5c,0xffe9853f,0xffe3bd38,0xff35a66f,0xff3f7ce8,0xff4d55b9,0xff9b63d7};
        String[] spectrumNames={"Red","Orange","Yellow","Green","Blue","Indigo","Violet"};
        HorizontalScrollView paletteScroll=new HorizontalScrollView(activity);paletteScroll.setHorizontalScrollBarEnabled(false);LinearLayout palette=row(activity);
        for(int i=0;i<spectrum.length;i++)palette.addView(colorSwatch(spectrumNames[i],spectrum[i]));paletteScroll.addView(palette);controls.addView(paletteScroll);

        title("Neutral");
        LinearLayout neutral=row(activity);neutral.addView(colorSwatch("Black",0xff050505));neutral.addView(colorSwatch("Gray",0xff7d858c));neutral.addView(colorSwatch("White",0xfff7f8fa));controls.addView(neutral);

        float[] hsv=new float[3];Color.colorToHSV(color(),hsv);
        slider("Hue · color family",0,359,(int)hsv[0],v->{float[] h=new float[3];Color.colorToHSV(color(),h);h[0]=v;if(h[1]<.08f)h[1]=.45f;color(Color.HSVToColor(h));});
        slider("Intensity · faded ↔ vivid",0,100,(int)(hsv[1]*100),v->{float[] h=new float[3];Color.colorToHSV(color(),h);h[1]=v/100f;color(Color.HSVToColor(h));});
        slider("Brightness · dark ↔ light",0,100,(int)(hsv[2]*100),v->{float[] h=new float[3];Color.colorToHSV(color(),h);h[2]=v/100f;color(Color.HSVToColor(h));});
        if(layer==1)slider("Card transparency",25,100,style.opacity,v->style.opacity=v);
        title("Finish");LinearLayout finish=row(activity);finish.addView(action((style.glass?"✓ ":"")+"Glass cards",()->{style.glass=true;commit();renderControls();}));finish.addView(action((!style.glass?"✓ ":"")+"Plain cards",()->{style.glass=false;commit();renderControls();}));controls.addView(finish);
        controls.addView(action((style.textGlass?"✓ ":"")+"Glass text",()->{style.textGlass=!style.textGlass;commit();renderControls();}));
        controls.addView(action((advanced?"Hide":"Show")+" advanced finish controls",()->{advanced=!advanced;renderControls();}));
        if(advanced){
            slider("Arabic opacity",20,100,style.arabicOpacity,v->style.arabicOpacity=v);
            slider("Translation opacity",20,100,style.translationOpacity,v->style.translationOpacity=v);
            controls.addView(text(activity,"Opacity stops at a readable contrast. The preview shows the final text color.",12,MUTED));
            slider("Glass strength",0,100,style.glassStrength,v->style.glassStrength=v);slider("Border strength",0,100,style.borderStrength,v->style.borderStrength=v);
            slider("Soft text glow",0,30,style.glow,v->style.glow=v);
            if(layer!=1)slider("Card opacity",25,100,style.opacity,v->style.opacity=v);slider("Corners",0,36,style.corners,v->style.corners=v);
            controls.addView(action((style.gradient?"✓ ":"")+"Two-color background",()->{style.gradient=!style.gradient;commit();renderControls();}));
            controls.addView(text(activity,"Choose Background and Gradient end above to set the two colors.",12,MUTED));
        }
        controls.addView(action((style.reducedEffects?"✓ ":"")+"Reduced effects",()->{style.reducedEffects=!style.reducedEffects;commit();renderControls();}));
        title("Quran font · Same original text");for(int i=0;i<Appearance.FONTS.length;i++){final int index=i;TextView b=action((style.font==i?"✓ ":"")+Appearance.FONTS[i],()->{style.font=index;commit();renderControls();});controls.addView(b);}
        controls.addView(text(activity,"Bold uses a real font weight. Fonts do not change the Quran text or its reading tradition.",12,MUTED));
        slider("Arabic size",24,54,style.arabicSize,v->style.arabicSize=v);slider("Line spacing",2,24,style.spacing,v->style.spacing=v);slider("Translation size",14,28,style.translationSize,v->style.translationSize=v);
        title("My styles");LinearLayout edits=row(activity);
        edits.addView(action("Undo",()->{if(historyIndex>0){style=Appearance.decode(history.get(--historyIndex));style.save(activity);refresh();renderControls();}}));
        edits.addView(action("Redo",()->{if(historyIndex+1<history.size()){style=Appearance.decode(history.get(++historyIndex));style.save(activity);refresh();renderControls();}}));
        edits.addView(action("Reset",()->{style=new Appearance();commit();renderControls();}));controls.addView(edits);
        controls.addView(action("Save this style",()->{EditText name=new EditText(activity);name.setHint("My night reading");new AlertDialog.Builder(activity).setTitle("Name your style").setView(name).setNegativeButton("Cancel",null).setPositiveButton("Save",(d,w)->{String n=name.getText().toString().trim();if(n.isEmpty())n="My style";style.name=n;activity.getSharedPreferences("saved_styles",0).edit().putString(n,style.encode()).apply();commit();renderControls();}).show();}));
        for(Map.Entry<String,?> entry:activity.getSharedPreferences("saved_styles",0).getAll().entrySet())if(entry.getValue() instanceof String)controls.addView(action(entry.getKey(),()->{style=Appearance.decode((String)entry.getValue());commit();renderControls();}));
        recolor(controls);binding=false;
    }
    private interface Change{void set(int value);}
    private void slider(String label,int min,int max,int initial,Change change){TextView caption=text(activity,label+" · "+initial,13,INK);controls.addView(caption);SeekBar seek=new SeekBar(activity);seek.setMax(max-min);seek.setProgress(initial-min);seek.setContentDescription(label);seek.setMinimumHeight(dp(activity,48));controls.addView(seek);seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar s){}public void onProgressChanged(SeekBar s,int value,boolean user){if(!user||binding)return;change.set(min+value);style.name="My style";caption.setText(label+" · "+(min+value));refresh();}public void onStopTrackingTouch(SeekBar s){commit();}});}
    private int color(){return layer==0?style.background:layer==1?style.surface:layer==2?style.arabic:layer==3?style.translation:layer==4?style.accent:style.gradientEnd;}
    private void color(int color){if(layer==0)style.background=color;else if(layer==1)style.surface=color;else if(layer==2)style.arabic=color;else if(layer==3)style.translation=color;else if(layer==4)style.accent=color;else style.gradientEnd=color;}
}
