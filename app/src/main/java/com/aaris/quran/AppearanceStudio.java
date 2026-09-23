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
    private final FrameLayout previewHost;
    private View editingSwatch;
    private final List<String> history=new ArrayList<>();
    private int historyIndex=0,layer=0;
    private boolean binding,advanced;
    private boolean editHsvValid;
    private int editHsvLayer=-1;
    private float editHue,editSat,editVal,gradientSatOffset,gradientValOffset;
    private final Runnable applied;
    static Dialog show(Activity activity,String sample,String translated,boolean rtl,Runnable applied){return new AppearanceStudio(activity,sample,translated,rtl,applied).dialog;}
    private AppearanceStudio(Activity a,String sample,String translated,boolean rtl,Runnable applied){
        activity=a;this.sample=sample;translationSample=translated;translationRtl=rtl;this.applied=applied;style=Appearance.load(a);history.add(style.encode());
        dialog=new Dialog(a);dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);LinearLayout root=column(a);pad(root,16,12);root.setBackgroundColor(0xff10171e);
        toolbar=row(a);TextView heading=text(a,"Appearance",23,0xffedf1ed);toolbar.addView(heading,new LinearLayout.LayoutParams(0,-2,1));
        toolbar.addView(action("Done",dialog::dismiss));root.addView(toolbar);
        previewHost=new FrameLayout(a);pad(previewHost,10,10);
        preview=column(a);pad(preview,18,14);ScrollView previewScroll=new ScrollView(a);previewScroll.setFillViewport(true);previewScroll.addView(preview);
        previewHost.addView(previewScroll,new FrameLayout.LayoutParams(-1,-1));
        root.addView(previewHost,new LinearLayout.LayoutParams(-1,Math.min(dp(a,300),a.getResources().getDisplayMetrics().heightPixels*45/100)));
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
        applyPreviewBackground();
        updateEditingSwatch();
        recolor(controls);recolor(toolbar);

    }
    private void applyPreviewBackground(){
        android.graphics.drawable.GradientDrawable bg;
        if(style.gradient&&!style.reducedEffects)bg=new android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TL_BR,new int[]{style.background,style.gradientEnd});
        else {bg=new android.graphics.drawable.GradientDrawable();bg.setColor(style.background);}
        bg.setCornerRadius(dp(activity,26));previewHost.setBackground(bg);
    }
    private void updateEditingSwatch(){
        if(editingSwatch==null)return;
        android.graphics.drawable.GradientDrawable sw=new android.graphics.drawable.GradientDrawable();sw.setShape(android.graphics.drawable.GradientDrawable.OVAL);sw.setColor(color());
        sw.setStroke(dp(activity,1),Appearance.mix(color(),style.ink(),.28f));editingSwatch.setBackground(sw);
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
    private void invalidateEditorColor(){editHsvValid=false;editHsvLayer=-1;}
    private void syncEditorColor(){
        if(editHsvValid&&editHsvLayer==layer)return;
        float[] h=new float[3];Color.colorToHSV(color(),h);editHue=h[0];editSat=h[1];editVal=h[2];
        gradientSatOffset=0;gradientValOffset=0;
        if(layer==0&&style.gradient){
            float[] end=new float[3];Color.colorToHSV(style.gradientEnd,end);
            gradientSatOffset=end[1]-editSat;gradientValOffset=end[2]-editVal;
        }
        editHsvLayer=layer;editHsvValid=true;
    }
    private void applyEditorColor(){
        float sat=Math.max(0f,Math.min(1f,editSat)),val=Math.max(0f,Math.min(1f,editVal));
        color(Color.HSVToColor(new float[]{editHue,sat,val}));
        if(layer==0&&style.gradient){
            float endSat=sat<.035f?0f:Math.max(0f,Math.min(1f,sat+gradientSatOffset));
            float endVal=Math.max(0f,Math.min(1f,val+gradientValOffset));
            style.gradientEnd=Color.HSVToColor(new float[]{editHue,endSat,endVal});
        }
    }
    private void chooseEditorColor(int value){
        syncEditorColor();float[] h=new float[3];Color.colorToHSV(value,h);
        editHue=h[0];editSat=h[1];editVal=h[2];applyEditorColor();
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
    private static final String[] LAYER_NAMES={"Screen","Cards","Quran text","Translation","Buttons","Gradient"};
    private static final String[] LAYER_HELP={
        "Whole background","Card tint and glass","Arabic text only","Translated text only","Buttons and highlights","Second gradient color"
    };
    private static final String[] LAYER_ICONS={"sun","cards","book","copy","settings","moon"};
    private View layerCard(int index){
        boolean selected=layer==index;int base=selected?Appearance.mix(style.effectiveSurface(),style.accent,.16f):style.effectiveSurface();
        LinearLayout card=row(activity);pad(card,9,5);card.setTag("keepColor");card.setGravity(Gravity.CENTER_VERTICAL);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(base);bg.setCornerRadius(dp(activity,16));
        bg.setStroke(dp(activity,selected?2:1),selected?style.accent:Appearance.mix(style.accent,style.effectiveSurface(),.72f));card.setBackground(bg);
        Glass.Icon icon=new Glass.Icon(activity,LAYER_ICONS[index]);icon.color=Appearance.readable(selected?style.accent:style.ink(),base);
        card.addView(icon,new LinearLayout.LayoutParams(dp(activity,30),dp(activity,30)));
        TextView label=text(activity,(selected?"✓ ":"")+LAYER_NAMES[index],13,Appearance.readable(selected?style.accent:style.ink(),base));label.setTag("keepColor");pad(label,7,0);
        card.addView(label,new LinearLayout.LayoutParams(0,-2,1));
        Glass.Icon next=new Glass.Icon(activity,"next");next.color=Appearance.readable(style.muted(),base);card.addView(next,new LinearLayout.LayoutParams(dp(activity,22),dp(activity,22)));
        card.setContentDescription("Edit "+LAYER_NAMES[index]+". "+LAYER_HELP[index]);card.setFocusable(true);card.setClickable(true);
        card.setOnClickListener(v->{if(layer!=index){layer=index;invalidateEditorColor();renderControls();}});
        return card;
    }
    private View editingSummary(){
        int base=style.effectiveSurface();LinearLayout box=row(activity);pad(box,12,10);box.setTag("keepColor");
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(base);bg.setCornerRadius(dp(activity,18));bg.setStroke(dp(activity,2),style.accent);box.setBackground(bg);
        editingSwatch=new View(activity);updateEditingSwatch();
        box.addView(editingSwatch,new LinearLayout.LayoutParams(dp(activity,36),dp(activity,36)));
        LinearLayout words=column(activity);pad(words,9,0);
        TextView now=text(activity,"NOW EDITING · "+LAYER_NAMES[layer].toUpperCase(java.util.Locale.ROOT),13,Appearance.readable(style.accent,base));now.setTag("keepColor");words.addView(now);
        TextView help=text(activity,LAYER_HELP[layer],11,Appearance.readable(Appearance.mix(style.ink(),base,.26f),base));help.setTag("keepColor");words.addView(help);
        box.addView(words,new LinearLayout.LayoutParams(0,-2,1));return box;
    }
    private View colorDot(String label,int value,boolean neutral){
        boolean selected=isColorDotSelected(value,neutral);
        FrameLayout outer=new FrameLayout(activity);outer.setTag("keepColor");outer.setFocusable(true);outer.setClickable(true);
        android.graphics.drawable.GradientDrawable ring=new android.graphics.drawable.GradientDrawable();ring.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        ring.setColor(0x00000000);ring.setStroke(dp(activity,selected?3:1),selected?style.accent:Appearance.mix(value,style.ink(),.22f));outer.setBackground(ring);
        TextView dot=text(activity,selected?"✓":"",15,Appearance.readable(0xfff7f8fa,value));dot.setTag("keepColor");dot.setGravity(Gravity.CENTER);
        android.graphics.drawable.GradientDrawable fill=new android.graphics.drawable.GradientDrawable();fill.setShape(android.graphics.drawable.GradientDrawable.OVAL);fill.setColor(value);dot.setBackground(fill);
        FrameLayout.LayoutParams inner=new FrameLayout.LayoutParams(dp(activity,24),dp(activity,24),Gravity.CENTER);outer.addView(dot,inner);
        outer.setContentDescription(label+" color for "+LAYER_NAMES[layer]+(selected?", selected":""));outer.setTooltipText(label);outer.setOnClickListener(v->{chooseEditorColor(value);style.name="My style";commit();renderControls();});
        return outer;
    }
    private View compactChoice(String label,boolean selected,Runnable run){
        TextView b=text(activity,(selected?"✓ ":"")+label,12,selected?Appearance.readable(style.accent,style.effectiveSurface()):style.ink());
        b.setTag("keepColor");b.setGravity(Gravity.CENTER);b.setMinHeight(dp(activity,42));pad(b,8,5);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(selected?Appearance.mix(style.effectiveSurface(),style.accent,.14f):style.effectiveSurface());bg.setCornerRadius(dp(activity,15));
        bg.setStroke(dp(activity,selected?2:1),selected?style.accent:Appearance.mix(style.accent,style.effectiveSurface(),.72f));b.setBackground(bg);b.setOnClickListener(v->run.run());return b;
    }
    private View quranWritingCard(int index,String label){
        boolean selected=style.font==index;Appearance sampleStyle=style.copy();sampleStyle.font=index;
        int base=selected?Appearance.mix(style.effectiveSurface(),style.accent,.14f):style.effectiveSurface();
        LinearLayout card=column(activity);card.setTag("keepColor");card.setGravity(Gravity.CENTER);pad(card,6,5);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(base);bg.setCornerRadius(dp(activity,16));
        bg.setStroke(dp(activity,selected?2:1),selected?style.accent:Appearance.mix(style.accent,style.effectiveSurface(),.72f));card.setBackground(bg);
        TextView sample=text(activity,"م ح ع",22,Appearance.readable(style.arabic,base));sample.setTag("keepColor");sample.setTypeface(sampleStyle.typeface(activity));sample.setGravity(Gravity.CENTER);sample.setTextDirection(View.TEXT_DIRECTION_RTL);card.addView(sample,new LinearLayout.LayoutParams(-1,dp(activity,32)));
        TextView name=text(activity,(selected?"✓ ":"")+label,11,Appearance.readable(selected?style.accent:style.ink(),base));name.setTag("keepColor");name.setGravity(Gravity.CENTER);card.addView(name,new LinearLayout.LayoutParams(-1,-2));
        card.setContentDescription(label+" Arabic writing style"+(selected?", selected":""));card.setClickable(true);card.setFocusable(true);
        card.setOnClickListener(v->{if(style.font!=index){style.font=index;commit();renderControls();}});
        return card;
    }
    private void compactSlider(String label,int min,int max,int initial,Change change){
        LinearLayout line=row(activity);TextView caption=text(activity,label,12,style.ink());caption.setTag("keepColor");line.addView(caption,new LinearLayout.LayoutParams(dp(activity,105),-2));
        SeekBar seek=new SeekBar(activity);seek.setMax(max-min);seek.setProgress(initial-min);seek.setContentDescription(label);line.addView(seek,new LinearLayout.LayoutParams(0,dp(activity,42),1));
        TextView value=text(activity,String.valueOf(initial),12,style.ink());value.setTag("keepColor");value.setGravity(Gravity.CENTER);line.addView(value,new LinearLayout.LayoutParams(dp(activity,36),-2));
        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar s){}public void onProgressChanged(SeekBar s,int v,boolean user){if(!user||binding)return;int actual=min+v;change.set(actual);style.name="My style";value.setText(String.valueOf(actual));refresh();}public void onStopTrackingTouch(SeekBar s){commit();}});
        controls.addView(line);
    }
    private boolean isColorDotSelected(int dotColor,boolean neutral){
        syncEditorColor();float[] dot=new float[3];Color.colorToHSV(dotColor,dot);
        if(neutral){
            if(editSat>.035f)return false;
            int currentBand=editVal<.25f?0:editVal<.78f?1:2;
            int dotBand=dot[2]<.25f?0:dot[2]<.78f?1:2;return currentBand==dotBand;
        }
        if(editSat<=.035f)return false;
        float diff=Math.abs(editHue-dot[0]);diff=Math.min(diff,360f-diff);return diff<18f;
    }
    private void renderControls(){
        binding=true;controls.removeAllViews();editingSwatch=null;

        title("Start with a look");
        HorizontalScrollView presets=new HorizontalScrollView(activity);presets.setHorizontalScrollBarEnabled(false);LinearLayout strip=row(activity);
        for(int i=0;i<Appearance.PRESETS.length;i++){
            final int index=i;Appearance swatch=style.copy();swatch.preset(i);
            View b=presetCard(swatch,style.name.equals(Appearance.PRESETS[i]),Appearance.PRESETS[i],()->{style.preset(index);invalidateEditorColor();commit();renderControls();});
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,116),dp(activity,78));p.rightMargin=dp(activity,7);strip.addView(b,p);
        }
        presets.addView(strip);controls.addView(presets);

        title("Customize");
        for(int first=0;first<4;first+=2){
            LinearLayout pair=row(activity);
            for(int j=0;j<2;j++){
                View card=layerCard(first+j);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(activity,54),1);if(j==0)p.rightMargin=dp(activity,7);pair.addView(card,p);
            }
            controls.addView(pair);if(first==0){View gap=new View(activity);controls.addView(gap,new LinearLayout.LayoutParams(1,dp(activity,7)));}
        }

        title("Color theme");
        int[] spectrum={0xffd64b5c,0xffe9853f,0xffe3bd38,0xff35a66f,0xff3f7ce8,0xff4d55b9,0xff9b63d7};
        String[] spectrumNames={"Red","Orange","Yellow","Green","Blue","Indigo","Violet"};
        int[] neutrals={0xff050505,0xff7d858c,0xfff7f8fa};String[] neutralNames={"Black","Gray","White"};
        LinearLayout dots=row(activity);dots.setGravity(Gravity.CENTER);
        for(int i=0;i<spectrum.length;i++){View dot=colorDot(spectrumNames[i],spectrum[i],false);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,31),dp(activity,31));p.rightMargin=dp(activity,3);dots.addView(dot,p);}
        View divider=new View(activity);divider.setBackgroundColor(Appearance.mix(style.ink(),style.background,.72f));LinearLayout.LayoutParams dpv=new LinearLayout.LayoutParams(dp(activity,1),dp(activity,26));dpv.leftMargin=dp(activity,5);dpv.rightMargin=dp(activity,5);dots.addView(divider,dpv);
        for(int i=0;i<neutrals.length;i++){View dot=colorDot(neutralNames[i],neutrals[i],true);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,31),dp(activity,31));if(i<neutrals.length-1)p.rightMargin=dp(activity,4);dots.addView(dot,p);}
        controls.addView(dots);

        title("Adjust");
        syncEditorColor();boolean neutralColor=editSat<.04f;
        int darkness=(int)Math.round((1f-editVal)*100);
        compactSlider("Light / Dark",0,100,darkness,v->{editVal=1f-(v/100f);applyEditorColor();});
        if(!neutralColor){
            int strength=(int)Math.round(Math.max(0,Math.min(1,(editSat-.05f)/.95f))*100);
            compactSlider("Color strength",0,100,strength,v->{editSat=.05f+.95f*(v/100f);applyEditorColor();});
        }
        if(layer==1)compactSlider("Card opacity",25,100,style.opacity,v->style.opacity=v);

        title("Quran writing");
        LinearLayout writing=row(activity);
        String[] writingNames={"Quran","Naskh","Bold Naskh"};
        for(int i=0;i<Appearance.FONTS.length;i++){
            View b=quranWritingCard(i,writingNames[i]);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(activity,64),1);if(i<Appearance.FONTS.length-1)p.rightMargin=dp(activity,6);writing.addView(b,p);
        }
        controls.addView(writing);

        title("Reading");
        compactSlider("Arabic size",24,54,style.arabicSize,v->style.arabicSize=v);
        compactSlider("Line spacing",2,24,style.spacing,v->style.spacing=v);
        compactSlider("Translation",14,28,style.translationSize,v->style.translationSize=v);

        title("Finish style");
        LinearLayout finish=row(activity);
        View glass=compactChoice("Glass cards",style.glass,()->{style.glass=true;commit();renderControls();});
        View plain=compactChoice("Plain cards",!style.glass,()->{style.glass=false;commit();renderControls();});
        LinearLayout.LayoutParams fp=new LinearLayout.LayoutParams(0,dp(activity,42),1);fp.rightMargin=dp(activity,6);finish.addView(glass,fp);finish.addView(plain,new LinearLayout.LayoutParams(0,dp(activity,42),1));controls.addView(finish);
        LinearLayout effects=row(activity);
        effects.addView(compactChoice("Glass text",style.textGlass,()->{style.textGlass=!style.textGlass;commit();renderControls();}),new LinearLayout.LayoutParams(0,dp(activity,42),1));
        LinearLayout.LayoutParams ep=new LinearLayout.LayoutParams(0,dp(activity,42),1);ep.leftMargin=dp(activity,6);
        effects.addView(compactChoice("Reduced effects",style.reducedEffects,()->{style.reducedEffects=!style.reducedEffects;commit();renderControls();}),ep);controls.addView(effects);

        TextView advancedButton=action((advanced?"Hide":"Advanced"),()->{advanced=!advanced;if(!advanced&&layer>=4){layer=0;invalidateEditorColor();}renderControls();});
        controls.addView(advancedButton);
        if(advanced){
            title("Advanced");
            LinearLayout advLayers=row(activity);
            advLayers.addView(compactChoice("Buttons",layer==4,()->{layer=4;invalidateEditorColor();renderControls();}),new LinearLayout.LayoutParams(0,dp(activity,42),1));
            LinearLayout.LayoutParams ap=new LinearLayout.LayoutParams(0,dp(activity,42),1);ap.leftMargin=dp(activity,6);
            advLayers.addView(compactChoice("Gradient",layer==5,()->{style.gradient=true;layer=5;invalidateEditorColor();commit();renderControls();}),ap);controls.addView(advLayers);
            compactSlider("Arabic opacity",20,100,style.arabicOpacity,v->style.arabicOpacity=v);
            compactSlider("Translation opacity",20,100,style.translationOpacity,v->style.translationOpacity=v);
            compactSlider("Glass strength",0,100,style.glassStrength,v->style.glassStrength=v);
            compactSlider("Border strength",0,100,style.borderStrength,v->style.borderStrength=v);
            compactSlider("Corners",0,36,style.corners,v->style.corners=v);
            if(style.gradient)controls.addView(compactChoice("Two-color background",true,()->{style.gradient=false;if(layer==5)layer=0;invalidateEditorColor();commit();renderControls();}));
        }

        title("My styles");
        LinearLayout edits=row(activity);
        View undo=compactChoice("Undo",false,()->{if(historyIndex>0){style=Appearance.decode(history.get(--historyIndex));invalidateEditorColor();style.save(activity);refresh();renderControls();}});
        View redo=compactChoice("Redo",false,()->{if(historyIndex+1<history.size()){style=Appearance.decode(history.get(++historyIndex));invalidateEditorColor();style.save(activity);refresh();renderControls();}});
        View reset=compactChoice("Reset",false,()->{style=new Appearance();invalidateEditorColor();commit();renderControls();});
        Runnable saveRun=()->{EditText name=new EditText(activity);name.setHint("My style");new AlertDialog.Builder(activity).setTitle("Save style").setView(name).setNegativeButton("Cancel",null).setPositiveButton("Save",(d,w)->{String n=name.getText().toString().trim();if(n.isEmpty())n="My style";style.name=n;activity.getSharedPreferences("saved_styles",0).edit().putString(n,style.encode()).apply();commit();renderControls();}).show();};
        View save=compactChoice("Save",true,saveRun);
        for(View v:new View[]{undo,redo,reset,save}){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(activity,42),1);p.rightMargin=dp(activity,5);edits.addView(v,p);}controls.addView(edits);

        Map<String,?> saved=activity.getSharedPreferences("saved_styles",0).getAll();
        if(!saved.isEmpty()){
            HorizontalScrollView savedScroll=new HorizontalScrollView(activity);savedScroll.setHorizontalScrollBarEnabled(false);LinearLayout savedRow=row(activity);
            for(Map.Entry<String,?> entry:saved.entrySet())if(entry.getValue() instanceof String){
                String name=entry.getKey();String encoded=(String)entry.getValue();View b=compactChoice(name,false,()->{style=Appearance.decode(encoded);invalidateEditorColor();commit();renderControls();});
                LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,118),dp(activity,40));p.rightMargin=dp(activity,6);savedRow.addView(b,p);
            }
            savedScroll.addView(savedRow);controls.addView(savedScroll);
        }
        recolor(controls);binding=false;
    }
    private interface Change{void set(int value);}
    private void slider(String label,int min,int max,int initial,Change change){TextView caption=text(activity,label+" · "+initial,13,INK);controls.addView(caption);SeekBar seek=new SeekBar(activity);seek.setMax(max-min);seek.setProgress(initial-min);seek.setContentDescription(label);seek.setMinimumHeight(dp(activity,48));controls.addView(seek);seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar s){}public void onProgressChanged(SeekBar s,int value,boolean user){if(!user||binding)return;change.set(min+value);style.name="My style";caption.setText(label+" · "+(min+value));refresh();}public void onStopTrackingTouch(SeekBar s){commit();}});}
    private int color(){return layer==0?style.background:layer==1?style.surface:layer==2?style.arabic:layer==3?style.translation:layer==4?style.accent:style.gradientEnd;}
    private void color(int color){if(layer==0)style.background=color;else if(layer==1)style.surface=color;else if(layer==2)style.arabic=color;else if(layer==3)style.translation=color;else if(layer==4)style.accent=color;else style.gradientEnd=color;}
}
