package com.aaris.quran;

import android.app.*;
import android.graphics.*;
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
    private final LinearLayout preview,controls,toolbar,root;
    private final FrameLayout previewHost;
    private final TextView heading;
    private final Glass.Backdrop previewBackdrop;
    private ArabicText previewArabic;
    private TextView previewLabel,previewTranslation,previewHint;
    private LinearLayout previewActions;
    private final List<Glass.Icon> previewActionIcons=new ArrayList<>();
    private final List<FrameLayout> previewActionChips=new ArrayList<>();
    private View editingSwatch;
    private final List<String> history=new ArrayList<>();
    private int historyIndex=0,layer=0;
    private boolean binding,advanced,refreshPosted;
    private boolean editHsvValid;
    private int editHsvLayer=-1;
    private float editHue,editSat,editVal,gradientHueOffset,gradientSatOffset,gradientValOffset;
    private final Runnable applied;
    static Dialog show(Activity activity,String sample,String translated,boolean rtl,Runnable applied){return new AppearanceStudio(activity,sample,translated,rtl,applied).dialog;}
    private AppearanceStudio(Activity a,String sample,String translated,boolean rtl,Runnable applied){
        activity=a;this.sample=sample;translationSample=translated;translationRtl=rtl;this.applied=applied;style=Appearance.load(a);history.add(style.encode());
        dialog=new Dialog(a);dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);root=column(a);pad(root,16,12);root.setBackgroundColor(style.background);
        toolbar=row(a);heading=text(a,"Appearance",23,style.appInk());toolbar.addView(heading,new LinearLayout.LayoutParams(0,-2,1));
        toolbar.addView(action("Done",dialog::dismiss));root.addView(toolbar);
        previewHost=new FrameLayout(a);pad(previewHost,10,10);
        previewBackdrop=new Glass.Backdrop(a,true);previewHost.addView(previewBackdrop,new FrameLayout.LayoutParams(-1,-1));
        preview=column(a);pad(preview,18,14);ScrollView previewScroll=new ScrollView(a);previewScroll.setFillViewport(true);previewScroll.setBackgroundColor(Color.TRANSPARENT);previewScroll.addView(preview);
        previewHost.addView(previewScroll,new FrameLayout.LayoutParams(-1,-1));
        root.addView(previewHost,new LinearLayout.LayoutParams(-1,Math.min(dp(a,300),a.getResources().getDisplayMetrics().heightPixels*45/100)));
        ScrollView scroll=new ScrollView(a);controls=column(a);pad(controls,0,10);scroll.addView(controls);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        dialog.setContentView(root);dialog.setOnDismissListener(d->{style.save(a);Glass.apply(style);applied.run();});dialog.show();
        Window window=dialog.getWindow();if(window!=null){window.setLayout(-1,-1);window.setBackgroundDrawableResource(android.R.color.transparent);}
        refresh();renderControls();
    }
    private TextView action(String label,Runnable run){TextView b=text(activity,label,14,style.buttonInk());b.setTag("action");pad(b,12,10);b.setGravity(Gravity.CENTER);b.setMinHeight(dp(activity,48));b.setBackground(Glass.touch(activity,Glass.Surface.Kind.BUTTON,false));b.setOnClickListener(v->run.run());b.setFocusable(true);Glass.motion(b);return b;}
    private void title(String label){TextView t=text(activity,label,13,GOLD);pad(t,2,12);controls.addView(t);}
    private void initPreview(){
        if(previewArabic!=null)return;
        previewLabel=text(activity,"LIVE PREVIEW · 1:1",11,MUTED);preview.addView(previewLabel);
        previewArabic=new ArabicText(activity);previewArabic.setText(sample);previewArabic.setTextDirection(View.TEXT_DIRECTION_RTL);previewArabic.setGravity(Gravity.CENTER);preview.addView(previewArabic);
        previewTranslation=text(activity,translationSample,style.translationSize,style.translationInk());
        previewTranslation.setTextDirection(translationRtl?View.TEXT_DIRECTION_RTL:View.TEXT_DIRECTION_FIRST_STRONG);
        previewTranslation.setGravity(translationRtl?Gravity.RIGHT:Gravity.LEFT);preview.addView(previewTranslation);
        previewActions=row(activity);previewActions.setGravity(Gravity.LEFT);
        for(String icon:new String[]{"play","bookmark","share"}){
            FrameLayout chip=new FrameLayout(activity);Glass.Icon glyph=new Glass.Icon(activity,icon);
            chip.addView(glyph,new FrameLayout.LayoutParams(dp(activity,18),dp(activity,18),Gravity.CENTER));
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,36),dp(activity,32));p.rightMargin=dp(activity,6);previewActions.addView(chip,p);
            previewActionChips.add(chip);previewActionIcons.add(glyph);
        }
        preview.addView(previewActions);
        previewHint=text(activity,"",11,MUTED);preview.addView(previewHint);
    }
    private void refresh(){refresh(true);}
    private void refresh(boolean recolorChrome){
        refreshPosted=false;Glass.apply(style);root.setBackgroundColor(style.background);heading.setTextColor(style.appInk());previewBackdrop.invalidate();
        initPreview();preview.setBackground(new Glass.Surface(activity,Glass.Surface.Kind.MUSHAF,false));
        previewLabel.setTextColor(MUTED);
        previewArabic.setTypeface(style.typeface(activity));previewArabic.setTextSize(style.arabicSize);
        previewArabic.setLineSpacing(dp(activity,style.spacing),1.08f);previewArabic.setReliefEnabled(true);
        previewTranslation.setTextSize(style.translationSize);previewTranslation.setTextColor(style.translationInk());
        for(int i=0;i<previewActionIcons.size();i++){
            FrameLayout chip=previewActionChips.get(i);Glass.Icon glyph=previewActionIcons.get(i);
            chip.setBackground(Glass.touch(activity,Glass.Surface.Kind.BUTTON,false));glyph.color=style.buttonInk();glyph.invalidate();
        }
        previewHint.setText(style.readabilitySummary()+(style.autoBalance?" · Smart balance ON":""));
        previewHint.setTextColor(MUTED);
        applyPreviewBackground();updateEditingSwatch();
        if(recolorChrome){recolor(controls);recolor(toolbar);}
    }
    private void scheduleRefresh(){
        if(refreshPosted)return;refreshPosted=true;
        root.postOnAnimation(()->{if(!refreshPosted)return;refreshPosted=false;if(dialog.isShowing())refresh(false);});
    }
    private void applyPreviewBackground(){
        android.graphics.drawable.GradientDrawable bg;
        if(style.rendersGradient())bg=new android.graphics.drawable.GradientDrawable(gradientOrientation(style.gradientAngle),new int[]{style.background,style.gradientEnd});
        else {bg=new android.graphics.drawable.GradientDrawable();bg.setColor(style.background);}
        bg.setCornerRadius(dp(activity,26));previewHost.setBackground(bg);
    }
    private android.graphics.drawable.GradientDrawable.Orientation gradientOrientation(int angle){
        switch(((angle+23)/45)%8){
            case 0:return android.graphics.drawable.GradientDrawable.Orientation.LEFT_RIGHT;
            case 1:return android.graphics.drawable.GradientDrawable.Orientation.TL_BR;
            case 2:return android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM;
            case 3:return android.graphics.drawable.GradientDrawable.Orientation.TR_BL;
            case 4:return android.graphics.drawable.GradientDrawable.Orientation.RIGHT_LEFT;
            case 5:return android.graphics.drawable.GradientDrawable.Orientation.BR_TL;
            case 6:return android.graphics.drawable.GradientDrawable.Orientation.BOTTOM_TOP;
            default:return android.graphics.drawable.GradientDrawable.Orientation.BL_TR;
        }
    }
    private void updateEditingSwatch(){
        if(editingSwatch==null)return;
        android.graphics.drawable.GradientDrawable sw=new android.graphics.drawable.GradientDrawable();sw.setShape(android.graphics.drawable.GradientDrawable.OVAL);sw.setColor(color());
        sw.setStroke(dp(activity,1),Appearance.mix(color(),style.ink(),.28f));editingSwatch.setBackground(sw);
    }
    private void recolor(View view){
        if("keepColor".equals(view.getTag()))return;
        if(view instanceof TextView){TextView t=(TextView)view;
            if("action".equals(view.getTag())||view.getTag() instanceof Integer){t.setBackground(Glass.touch(activity,Glass.Surface.Kind.BUTTON,false));t.setTextColor(Appearance.readable(view.getTag() instanceof Integer?(Integer)view.getTag():style.buttonInk(),style.buttonSurface()));}
            else if(view.getBackground()==null)t.setTextColor(style.appInk());
        }
        if(view instanceof ViewGroup){ViewGroup group=(ViewGroup)view;for(int i=0;i<group.getChildCount();i++)recolor(group.getChildAt(i));}
    }
    private void commit(){
        String encoded=style.encode();if(!encoded.equals(history.get(historyIndex))){while(history.size()>historyIndex+1)history.remove(history.size()-1);history.add(encoded);if(history.size()>30)history.remove(0);historyIndex=history.size()-1;}
        style.save(activity);refresh();
    }
    private void invalidateEditorColor(){editHsvValid=false;editHsvLayer=-1;}
    private void normalizeEditingLayer(){
        if(layer==5&&!style.gradient){layer=0;invalidateEditorColor();}
    }
    private void syncEditorColor(){
        if(editHsvValid&&editHsvLayer==layer)return;
        float[] h=new float[3];Color.colorToHSV(color(),h);editHue=h[0];editSat=h[1];editVal=h[2];
        gradientHueOffset=0;gradientSatOffset=0;gradientValOffset=0;
        if(layer==0&&style.gradient){
            float[] end=new float[3];Color.colorToHSV(style.gradientEnd,end);
            gradientHueOffset=end[0]-editHue;
            if(gradientHueOffset>180f)gradientHueOffset-=360f;else if(gradientHueOffset<-180f)gradientHueOffset+=360f;
            gradientSatOffset=end[1]-editSat;gradientValOffset=end[2]-editVal;
        }
        editHsvLayer=layer;editHsvValid=true;
    }
    private void applyEditorColor(){
        float sat=Math.max(0f,Math.min(1f,editSat)),val=Math.max(0f,Math.min(1f,editVal));
        color(Color.HSVToColor(new float[]{editHue,sat,val}));
        if(layer==0&&style.gradient){
            float endHue=(editHue+gradientHueOffset)%360f;if(endHue<0f)endHue+=360f;
            float endSat=sat<.035f?0f:Math.max(0f,Math.min(1f,sat+gradientSatOffset));
            float endVal=Math.max(0f,Math.min(1f,val+gradientValOffset));
            style.gradientEnd=Color.HSVToColor(new float[]{endHue,endSat,endVal});
        }
    }
    private void chooseEditorColor(int value){
        syncEditorColor();float[] h=new float[3];Color.colorToHSV(value,h);
        editHue=h[0];editSat=h[1];editVal=h[2];applyEditorColor();
    }
    private View presetCard(Appearance swatch,boolean selected,String label,Runnable run){
        FrameLayout card=new FrameLayout(activity);card.setTag("keepColor");
        int cardTone=Appearance.mix(swatch.background,swatch.gradient?swatch.gradientEnd:swatch.surface,.45f);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable(
            android.graphics.drawable.GradientDrawable.Orientation.TL_BR,
            swatch.gradient?new int[]{swatch.background,swatch.gradientEnd}:new int[]{swatch.background,swatch.surface});
        bg.setCornerRadius(dp(activity,18));
        bg.setStroke(dp(activity,selected?2:1),selected?swatch.accent:Appearance.mix(swatch.accent,cardTone,.72f));
        card.setBackground(bg);
        View art=presetScene(swatch);card.addView(art,new FrameLayout.LayoutParams(-1,-1));

        TextView sample=text(activity,"بِسْمِ",21,swatch.arabicInk());sample.setTag("keepColor");
        sample.setTypeface(swatch.typeface(activity));sample.setGravity(Gravity.CENTER);sample.setTextDirection(View.TEXT_DIRECTION_RTL);
        FrameLayout.LayoutParams sp=new FrameLayout.LayoutParams(-1,-1,Gravity.CENTER);
        sp.setMargins(dp(activity,7),dp(activity,6),dp(activity,7),dp(activity,6));card.addView(sample,sp);

        if(selected){
            TextView check=text(activity,"✓",10,Appearance.readable(swatch.accent,cardTone));check.setTag("keepColor");check.setGravity(Gravity.CENTER);
            android.graphics.drawable.GradientDrawable badge=new android.graphics.drawable.GradientDrawable();badge.setShape(android.graphics.drawable.GradientDrawable.OVAL);
            badge.setColor(Appearance.mix(swatch.accent,cardTone,.16f));check.setBackground(badge);
            FrameLayout.LayoutParams cp=new FrameLayout.LayoutParams(dp(activity,20),dp(activity,20),Gravity.TOP|Gravity.RIGHT);
            cp.setMargins(0,dp(activity,4),dp(activity,4),0);card.addView(check,cp);
        }

        card.setContentDescription(label+" appearance preset"+(selected?", selected":""));card.setTooltipText(label);
        card.setSelected(selected);card.setFocusable(true);card.setClickable(true);card.setOnClickListener(v->run.run());Glass.motion(card);return card;
    }
    private View presetScene(Appearance swatch){
        return new View(activity){
            final Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);
            @Override protected void onDraw(Canvas canvas){
                float w=getWidth(),h=getHeight();if(w<=0||h<=0)return;
                int end=swatch.gradient?swatch.gradientEnd:swatch.surface;
                p.setStyle(Paint.Style.FILL);
                p.setShader(new LinearGradient(0,0,w,h,new int[]{swatch.background,end},null,Shader.TileMode.CLAMP));
                canvas.drawRoundRect(new RectF(0,0,w,h),dp(activity,18),dp(activity,18),p);p.setShader(null);

                if(swatch.scene==1){
                    RadialGradient sun=new RadialGradient(w*.78f,h*.20f,w*.58f,
                        new int[]{0xB8FFF5D2,0x18F0C979,Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    p.setShader(sun);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(Math.max(1f,w*.018f));p.setColor(0x72A06C26);
                    RectF arch=new RectF(w*.08f,h*.08f,w*.92f,h*.90f);canvas.drawArc(arch,180,180,false,p);
                    p.setStyle(Paint.Style.FILL);p.setColor(0x33335D43);
                    canvas.drawOval(new RectF(w*.05f,h*.15f,w*.22f,h*.42f),p);
                    canvas.drawOval(new RectF(w*.78f,h*.10f,w*.94f,h*.34f),p);
                }else if(swatch.scene==2){
                    RadialGradient moon=new RadialGradient(w*.76f,h*.20f,w*.34f,
                        new int[]{0x9AE8F1E9,0x18318A76,Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    p.setShader(moon);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    p.setColor(0x72D8BA72);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(Math.max(1f,w*.014f));
                    canvas.drawArc(new RectF(w*.05f,h*.06f,w*.95f,h*.92f),180,180,false,p);
                }else if(swatch.scene==3){
                    LinearGradient sky=new LinearGradient(0,0,w,h,
                        new int[]{0x784A1731,0x90C75A53,0x10241116},null,Shader.TileMode.CLAMP);
                    p.setShader(sky);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    RadialGradient sun=new RadialGradient(w*.70f,h*.42f,w*.26f,
                        new int[]{0xB8FFAA73,0x28F56C61,Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    p.setShader(sun);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    p.setStyle(Paint.Style.FILL);p.setColor(0xAA2B1320);
                    float base=h*.76f,cx=w*.69f,u=w*.055f;
                    canvas.drawRect(cx-u*2.2f,base-u*.2f,cx+u*2.2f,base+u*.9f,p);
                    canvas.drawArc(new RectF(cx-u*1.9f,base-u*2.0f,cx+u*1.9f,base+u*.1f),180,180,true,p);
                    for(float dx:new float[]{-3.4f,3.4f}){
                        float x=cx+u*dx;canvas.drawRect(x-u*.22f,base-u*2.7f,x+u*.22f,base+u*.7f,p);
                    }
                }else if(swatch.scene==4){
                    LinearGradient mint=new LinearGradient(0,0,w,h,
                        new int[]{0xFFF8F7EF,0xFFE7F0E6},null,Shader.TileMode.CLAMP);
                    p.setShader(mint);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    RadialGradient light=new RadialGradient(w*.72f,h*.18f,w*.58f,
                        new int[]{0xC8FFFCE8,0x20BFD7C4,Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    p.setShader(light);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    p.setStyle(Paint.Style.FILL);p.setColor(0x5532735A);
                    float[][] leaves={{.08f,.18f,-28f},{.16f,.27f,-14f},{.88f,.16f,28f},{.82f,.28f,16f}};
                    for(float[] leaf:leaves){
                        float x=w*leaf[0],y=h*leaf[1];canvas.save();canvas.rotate(leaf[2],x,y);
                        canvas.drawOval(new RectF(x-w*.035f,y-h*.10f,x+w*.035f,y+h*.10f),p);canvas.restore();
                    }
                    p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(Math.max(1f,w*.012f));p.setColor(0x55608E79);
                    canvas.drawArc(new RectF(w*.08f,h*.08f,w*.92f,h*.92f),180,180,false,p);
                }else if(swatch.scene==5){
                    LinearGradient blue=new LinearGradient(0,0,w,h,
                        new int[]{0xFF041938,0xFF0B4E98},null,Shader.TileMode.CLAMP);
                    p.setShader(blue);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    RadialGradient moon=new RadialGradient(w*.73f,h*.20f,w*.34f,
                        new int[]{0xD8F5FBFF,0x306DB7FF,Color.TRANSPARENT},null,Shader.TileMode.CLAMP);
                    p.setShader(moon);canvas.drawRect(0,0,w,h,p);p.setShader(null);
                    p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(Math.max(1f,w*.016f));p.setColor(0x995EBEFF);
                    canvas.drawArc(new RectF(w*.06f,h*.06f,w*.94f,h*.92f),180,180,false,p);
                    p.setStyle(Paint.Style.FILL);p.setColor(0xCC031B3E);
                    float base=h*.76f,cx=w*.68f,u=w*.052f;
                    canvas.drawRect(cx-u*2.2f,base-u*.2f,cx+u*2.2f,base+u*.9f,p);
                    canvas.drawArc(new RectF(cx-u*1.9f,base-u*2f,cx+u*1.9f,base+u*.1f),180,180,true,p);
                }
            }
        };
    }
    private static final String[] LAYER_NAMES={"Screen","Cards","Arabic text","Translation","Buttons","Gradient","Highlights","App Text","Text shadow"};
    private static final String[] LAYER_HELP={
        "Whole background","Card tint and glass","Arabic text only","Translated text only","Button fill color","Second gradient color","Icons, borders and highlights","Headings, labels and normal app text","Arabic shadow color"
    };
    private static final String[] LAYER_ICONS={"sun","cards","book","copy","settings","moon","sun","text","text"};
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
        card.setOnClickListener(v->{if(layer!=index){layer=index;invalidateEditorColor();renderControls();}});Glass.motion(card);
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
        FrameLayout visual=new FrameLayout(activity);visual.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        android.graphics.drawable.GradientDrawable ring=new android.graphics.drawable.GradientDrawable();ring.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        ring.setColor(0x00000000);ring.setStroke(dp(activity,selected?3:1),selected?style.accent:Appearance.mix(value,style.ink(),.22f));visual.setBackground(ring);
        outer.addView(visual,new FrameLayout.LayoutParams(dp(activity,27),dp(activity,27),Gravity.CENTER));
        TextView dot=text(activity,selected?"✓":"",15,Appearance.readable(0xfff7f8fa,value));dot.setTag("keepColor");dot.setGravity(Gravity.CENTER);
        android.graphics.drawable.GradientDrawable fill=new android.graphics.drawable.GradientDrawable();fill.setShape(android.graphics.drawable.GradientDrawable.OVAL);fill.setColor(value);dot.setBackground(fill);
        FrameLayout.LayoutParams inner=new FrameLayout.LayoutParams(dp(activity,20),dp(activity,20),Gravity.CENTER);visual.addView(dot,inner);
        outer.setContentDescription(label+" color for "+LAYER_NAMES[layer]+(selected?", selected":""));outer.setTooltipText(label);outer.setOnClickListener(v->{chooseEditorColor(value);style.name="My style";commit();renderControls();});Glass.motion(outer);
        return outer;
    }
    private View compactChoice(String label,boolean selected,Runnable run){
        TextView b=text(activity,(selected?"✓ ":"")+label,12,selected?Appearance.readable(style.accent,style.effectiveSurface()):style.ink());
        b.setTag("keepColor");b.setGravity(Gravity.CENTER);b.setMinHeight(dp(activity,48));pad(b,8,5);
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(selected?Appearance.mix(style.effectiveSurface(),style.accent,.14f):style.effectiveSurface());bg.setCornerRadius(dp(activity,15));
        bg.setStroke(dp(activity,selected?2:1),selected?style.accent:Appearance.mix(style.accent,style.effectiveSurface(),.72f));b.setBackground(bg);b.setOnClickListener(v->run.run());b.setFocusable(true);Glass.motion(b);return b;
    }
    private View quranWritingCard(int index,String label){
        boolean selected=style.font==index;Appearance sampleStyle=style.copy();sampleStyle.font=index;
        int base=selected?Appearance.mix(style.effectiveSurface(),style.accent,.14f):style.effectiveSurface();
        FrameLayout card=new FrameLayout(activity);card.setTag("keepColor");
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();bg.setColor(base);bg.setCornerRadius(dp(activity,16));
        bg.setStroke(dp(activity,selected?2:1),selected?style.accent:Appearance.mix(style.accent,style.effectiveSurface(),.72f));card.setBackground(bg);

        TextView sample=text(activity,"بِسْمِ",23,Appearance.readable(style.arabic,base));sample.setTag("keepColor");
        sample.setTypeface(sampleStyle.typeface(activity));sample.setGravity(Gravity.CENTER);sample.setTextDirection(View.TEXT_DIRECTION_RTL);
        FrameLayout.LayoutParams sp=new FrameLayout.LayoutParams(-1,-1,Gravity.CENTER);sp.setMargins(dp(activity,5),dp(activity,5),dp(activity,5),dp(activity,5));card.addView(sample,sp);

        if(selected){
            TextView check=text(activity,"✓",10,Appearance.readable(style.accent,base));check.setTag("keepColor");check.setGravity(Gravity.CENTER);
            android.graphics.drawable.GradientDrawable badge=new android.graphics.drawable.GradientDrawable();badge.setShape(android.graphics.drawable.GradientDrawable.OVAL);
            badge.setColor(Appearance.mix(style.accent,base,.18f));check.setBackground(badge);
            FrameLayout.LayoutParams cp=new FrameLayout.LayoutParams(dp(activity,20),dp(activity,20),Gravity.TOP|Gravity.RIGHT);cp.setMargins(0,dp(activity,4),dp(activity,4),0);card.addView(check,cp);
        }

        card.setContentDescription(label+" Arabic writing style"+(selected?", selected":""));card.setTooltipText(label);
        card.setClickable(true);card.setFocusable(true);card.setSelected(selected);
        card.setOnClickListener(v->{if(style.font!=index){style.font=index;style.name="My style";commit();renderControls();}});Glass.motion(card);
        return card;
    }
    private void compactSlider(String label,int min,int max,int initial,Change change){
        LinearLayout line=row(activity);TextView caption=text(activity,label,12,style.ink());caption.setTag("keepColor");line.addView(caption,new LinearLayout.LayoutParams(dp(activity,105),-2));
        SeekBar seek=new SeekBar(activity);seek.setMax(max-min);seek.setProgress(initial-min);seek.setContentDescription(label);line.addView(seek,new LinearLayout.LayoutParams(0,dp(activity,48),1));
        TextView value=text(activity,String.valueOf(initial),12,style.ink());value.setTag("keepColor");value.setGravity(Gravity.CENTER);line.addView(value,new LinearLayout.LayoutParams(dp(activity,36),-2));
        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar s){}public void onProgressChanged(SeekBar s,int v,boolean user){if(!user||binding)return;int actual=min+v;change.set(actual);style.name="My style";value.setText(String.valueOf(actual));scheduleRefresh();}public void onStopTrackingTouch(SeekBar s){commit();}});
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
        normalizeEditingLayer();
        binding=true;controls.removeAllViews();editingSwatch=null;

        title("Start with a look");
        HorizontalScrollView presets=new HorizontalScrollView(activity);presets.setHorizontalScrollBarEnabled(false);LinearLayout strip=row(activity);
        for(int i=0;i<Appearance.PRESETS.length;i++){
            final int index=i;Appearance swatch=style.copy();swatch.preset(i);
            View b=presetCard(swatch,style.name.equals(Appearance.PRESETS[i]),Appearance.PRESETS[i],()->{style.preset(index);invalidateEditorColor();commit();renderControls();});
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,88),dp(activity,62));p.rightMargin=dp(activity,6);strip.addView(b,p);
        }
        presets.addView(strip);controls.addView(presets);

        title("Customize");
        for(int first=0;first<4;first+=2){
            LinearLayout pair=row(activity);
            for(int j=0;j<2;j++){
                View card=layerCard(first+j);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(activity,54),1);if(j==0)p.rightMargin=dp(activity,7);pair.addView(card,p);
            }
            controls.addView(pair);View gap=new View(activity);controls.addView(gap,new LinearLayout.LayoutParams(1,dp(activity,7)));
        }
        controls.addView(layerCard(7),new LinearLayout.LayoutParams(-1,dp(activity,54)));

        title("Color theme");
        int[] spectrum={0xffd64b5c,0xffe9853f,0xffe3bd38,0xff35a66f,0xff3f7ce8,0xff4d55b9,0xff9b63d7};
        String[] spectrumNames={"Red","Orange","Yellow","Green","Blue","Indigo","Violet"};
        int[] neutrals={0xff050505,0xff7d858c,0xfff7f8fa};String[] neutralNames={"Black","Gray","White"};
        HorizontalScrollView palette=new HorizontalScrollView(activity);palette.setHorizontalScrollBarEnabled(false);palette.setFillViewport(true);
        LinearLayout dots=row(activity);dots.setGravity(Gravity.CENTER_VERTICAL);dots.setClipToPadding(false);
        for(int i=0;i<spectrum.length;i++){
            View dot=colorDot(spectrumNames[i],spectrum[i],false);
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,48),dp(activity,48));if(i<spectrum.length-1)p.rightMargin=dp(activity,1);dots.addView(dot,p);
        }
        View divider=new View(activity);divider.setBackgroundColor(Appearance.mix(style.ink(),style.background,.72f));
        LinearLayout.LayoutParams dpv=new LinearLayout.LayoutParams(dp(activity,1),dp(activity,28));dpv.leftMargin=dp(activity,3);dpv.rightMargin=dp(activity,3);dots.addView(divider,dpv);
        for(int i=0;i<neutrals.length;i++){
            View dot=colorDot(neutralNames[i],neutrals[i],true);
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,48),dp(activity,48));if(i<neutrals.length-1)p.rightMargin=dp(activity,1);dots.addView(dot,p);
        }
        palette.addView(dots,new HorizontalScrollView.LayoutParams(-2,-2));controls.addView(palette);

        title("Adjust");
        syncEditorColor();boolean neutralColor=editSat<.04f;
        int darkness=(int)Math.round((1f-editVal)*100);
        compactSlider("Light / Dark",0,100,darkness,v->{editVal=1f-(v/100f);applyEditorColor();});
        if(!neutralColor){
            int strength=(int)Math.round(Math.max(0,Math.min(1,(editSat-.05f)/.95f))*100);
            compactSlider("Color strength",0,100,strength,v->{editSat=.05f+.95f*(v/100f);applyEditorColor();});
        }
        if(layer==1)compactSlider("Card opacity",25,100,style.opacity,v->style.opacity=v);

        title("Arabic writing · Quran + Hadith");
        HorizontalScrollView writingScroll=new HorizontalScrollView(activity);writingScroll.setHorizontalScrollBarEnabled(false);writingScroll.setClipToPadding(false);
        LinearLayout writing=row(activity);
        String[] writingNames={"Mushaf","Amiri","Bold","Scheherazade","Lateef","Harmattan","Noto Naskh","Noto Kufi"};
        for(int i=0;i<Appearance.FONTS.length;i++){
            View b=quranWritingCard(i,writingNames[i]);
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,82),dp(activity,60));if(i<Appearance.FONTS.length-1)p.rightMargin=dp(activity,6);writing.addView(b,p);
        }
        writingScroll.addView(writing);controls.addView(writingScroll);

        title("Reading");
        compactSlider("Arabic size",24,54,style.arabicSize,v->style.arabicSize=v);
        compactSlider("Line spacing",2,24,style.spacing,v->style.spacing=v);
        compactSlider("Translation",14,28,style.translationSize,v->style.translationSize=v);

        title("Arabic text finish");
        LinearLayout textFinishes=row(activity);
        for(int i=0;i<Appearance.TEXT_FINISHES.length;i++){
            final int finishIndex=i;View option=compactChoice(Appearance.TEXT_FINISHES[i],style.textFinish==i,()->{style.textFinish=finishIndex;style.textGlass=finishIndex==Appearance.TEXT_GLASS;style.name="My style";commit();renderControls();});
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(activity,48),1);if(i<Appearance.TEXT_FINISHES.length-1)p.rightMargin=dp(activity,5);textFinishes.addView(option,p);
        }
        controls.addView(textFinishes);

        title("Finish style");
        LinearLayout finish=row(activity);
        View glass=compactChoice("Glass cards",style.glass,()->{style.glass=true;style.name="My style";commit();renderControls();});
        View plain=compactChoice("Plain cards",!style.glass,()->{style.glass=false;style.name="My style";commit();renderControls();});
        LinearLayout.LayoutParams fp=new LinearLayout.LayoutParams(0,dp(activity,48),1);fp.rightMargin=dp(activity,6);finish.addView(glass,fp);finish.addView(plain,new LinearLayout.LayoutParams(0,dp(activity,48),1));controls.addView(finish);
        LinearLayout effects=row(activity);
        effects.addView(compactChoice("Smart balance",style.autoBalance,()->{style.autoBalance=!style.autoBalance;style.name="My style";commit();renderControls();}),new LinearLayout.LayoutParams(0,dp(activity,48),1));
        LinearLayout.LayoutParams ep=new LinearLayout.LayoutParams(0,dp(activity,48),1);ep.leftMargin=dp(activity,6);
        effects.addView(compactChoice("Reduced effects",style.reducedEffects,()->{style.reducedEffects=!style.reducedEffects;style.name="My style";commit();renderControls();}),ep);controls.addView(effects);

        TextView advancedButton=action((advanced?"Hide":"Advanced"),()->{advanced=!advanced;if(!advanced&&(layer==4||layer==5||layer==6||layer==8)){layer=0;invalidateEditorColor();}renderControls();});
        controls.addView(advancedButton);
        if(advanced){
            title("Advanced");
            LinearLayout advLayers=row(activity);
            advLayers.addView(compactChoice("Buttons",layer==4,()->{layer=4;invalidateEditorColor();renderControls();}),new LinearLayout.LayoutParams(0,dp(activity,48),1));
            LinearLayout.LayoutParams ap=new LinearLayout.LayoutParams(0,dp(activity,48),1);ap.leftMargin=dp(activity,6);
            advLayers.addView(compactChoice("Gradient",layer==5,()->{style.gradient=true;style.name="My style";layer=5;invalidateEditorColor();commit();renderControls();}),ap);controls.addView(advLayers);
            LinearLayout detailLayers=row(activity);
            detailLayers.addView(compactChoice("Highlight",layer==6,()->{layer=6;invalidateEditorColor();renderControls();}),new LinearLayout.LayoutParams(0,dp(activity,48),1));
            LinearLayout.LayoutParams sp=new LinearLayout.LayoutParams(0,dp(activity,48),1);sp.leftMargin=dp(activity,6);
            detailLayers.addView(compactChoice(style.autoShadowColor?"Shadow · Auto":"Shadow color",layer==8,()->{layer=8;invalidateEditorColor();renderControls();}),sp);controls.addView(detailLayers);
            controls.addView(compactChoice("Auto shadow color",style.autoShadowColor,()->{style.autoShadowColor=!style.autoShadowColor;style.name="My style";invalidateEditorColor();commit();renderControls();}));
            compactSlider("Text depth",0,12,style.textDepth,v->style.textDepth=v);
            compactSlider("Shadow strength",0,70,style.shadowStrength,v->style.shadowStrength=v);
            compactSlider("Shadow softness",0,16,style.shadowSoftness,v->style.shadowSoftness=v);
            compactSlider("Shadow angle",0,359,style.shadowAngle,v->style.shadowAngle=v);
            compactSlider("Shadow distance",0,20,style.shadowDistance,v->style.shadowDistance=v);
            compactSlider("Text sheen",0,100,style.textSheen,v->style.textSheen=v);
            compactSlider("Text glow",0,30,style.glow,v->style.glow=v);
            compactSlider("Arabic opacity",20,100,style.arabicOpacity,v->style.arabicOpacity=v);
            compactSlider("Translation opacity",20,100,style.translationOpacity,v->style.translationOpacity=v);
            compactSlider("Glass strength",0,100,style.glassStrength,v->style.glassStrength=v);
            compactSlider("Border strength",0,100,style.borderStrength,v->style.borderStrength=v);
            compactSlider("Corners",0,36,style.corners,v->style.corners=v);
            if(style.gradient)compactSlider("Gradient angle",0,359,style.gradientAngle,v->style.gradientAngle=v);
            controls.addView(compactChoice("Auto balance now",false,()->{style.autoBalance=true;style.autoBalanceEffects();style.name="My style";commit();renderControls();}));
            if(style.gradient)controls.addView(compactChoice("Two-color background",true,()->{style.gradient=false;style.name="My style";if(layer==5)layer=0;invalidateEditorColor();commit();renderControls();}));
        }

        title("My styles");
        LinearLayout edits=row(activity);
        View undo=compactChoice("Undo",false,()->{if(historyIndex>0){style=Appearance.decode(history.get(--historyIndex));invalidateEditorColor();style.save(activity);refresh();renderControls();}});
        View redo=compactChoice("Redo",false,()->{if(historyIndex+1<history.size()){style=Appearance.decode(history.get(++historyIndex));invalidateEditorColor();style.save(activity);refresh();renderControls();}});
        boolean canUndo=historyIndex>0,canRedo=historyIndex+1<history.size();
        undo.setEnabled(canUndo);undo.setFocusable(canUndo);undo.setAlpha(canUndo?1f:.45f);
        redo.setEnabled(canRedo);redo.setFocusable(canRedo);redo.setAlpha(canRedo?1f:.45f);
        View reset=compactChoice("Reset",false,()->{style=new Appearance();invalidateEditorColor();commit();renderControls();});
        Runnable saveRun=()->{EditText name=new EditText(activity);name.setHint("My style");new AlertDialog.Builder(activity).setTitle("Save style").setView(name).setNegativeButton("Cancel",null).setPositiveButton("Save",(d,w)->{String n=name.getText().toString().trim();if(n.isEmpty())n="My style";style.name=n;activity.getSharedPreferences("saved_styles",0).edit().putString(n,style.encode()).apply();commit();renderControls();}).show();};
        View save=compactChoice("Save",true,saveRun);
        for(View v:new View[]{undo,redo,reset,save}){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(activity,48),1);p.rightMargin=dp(activity,5);edits.addView(v,p);}controls.addView(edits);

        Map<String,?> saved=activity.getSharedPreferences("saved_styles",0).getAll();
        if(!saved.isEmpty()){
            HorizontalScrollView savedScroll=new HorizontalScrollView(activity);savedScroll.setHorizontalScrollBarEnabled(false);LinearLayout savedRow=row(activity);
            for(Map.Entry<String,?> entry:saved.entrySet())if(entry.getValue() instanceof String){
                String name=entry.getKey();String encoded=(String)entry.getValue();View b=compactChoice(name,false,()->{style=Appearance.decode(encoded);invalidateEditorColor();commit();renderControls();});
                LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(activity,118),dp(activity,48));p.rightMargin=dp(activity,6);savedRow.addView(b,p);
            }
            savedScroll.addView(savedRow);controls.addView(savedScroll);
        }
        recolor(controls);binding=false;
    }
    private interface Change{void set(int value);}
    private void slider(String label,int min,int max,int initial,Change change){TextView caption=text(activity,label+" · "+initial,13,INK);controls.addView(caption);SeekBar seek=new SeekBar(activity);seek.setMax(max-min);seek.setProgress(initial-min);seek.setContentDescription(label);seek.setMinimumHeight(dp(activity,48));controls.addView(seek);seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar s){}public void onProgressChanged(SeekBar s,int value,boolean user){if(!user||binding)return;change.set(min+value);style.name="My style";caption.setText(label+" · "+(min+value));scheduleRefresh();}public void onStopTrackingTouch(SeekBar s){commit();}});}
    private int color(){return layer==0?style.background:layer==1?style.surface:layer==2?style.arabic:layer==3?style.translation:layer==4?(style.customButtons?style.buttonColor:style.surface):layer==5?style.gradientEnd:layer==6?style.accent:layer==7?style.appText:style.resolvedShadowColor();}
    private void color(int color){if(layer==0)style.background=color;else if(layer==1)style.surface=color;else if(layer==2)style.arabic=color;else if(layer==3)style.translation=color;else if(layer==4){style.buttonColor=color;style.customButtons=true;}else if(layer==5)style.gradientEnd=color;else if(layer==6)style.accent=color;else if(layer==7)style.appText=color;else{style.shadowColor=color;style.autoShadowColor=false;}}
}
