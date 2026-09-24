package com.aaris.quran;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.provider.Settings;
import android.content.pm.PackageManager;
import android.text.*;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import com.aaris.quran.Glass.Surface;
import com.aaris.quran.core.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import static com.aaris.quran.Glass.*;

public final class MainActivity extends Activity {
    private QuranApp app;
    private ContentStore content;
    private LearningStore learning;
    private Typeface arabicFont;
    private Appearance appearance;
    private String translationId="hindi_omari";
    private int pendingVoiceScope=-1;
    private TranslationSpeech translationSpeech;
    private FrameLayout root,overlay;
    private LinearLayout layout,body,header,bottom;
    private Glass.Backdrop backdrop;
    private int tab=1,readerSurah=1,readerStart=1;
    private boolean reading=true,searching=false,highContrast=false,quietReader=false;
    private float arabicSize=32;
    private String language="hi",selectedWordId="";
    private ScrollView readerScroll,restoringReader;
    private String renderedPage="";
    private ReadingPosition readingPosition;
    private final Map<String,QuranText> readerVerses=new LinkedHashMap<>();
    private QuranText selectedVerse;
    private Dialog activeDialog;
    private final Handler ui=new Handler(Looper.getMainLooper());
    private final AtomicInteger searchGeneration=new AtomicInteger();
    private Future<?> searchTask,quranSearchTask;
    private CancellationSignal searchCancellation;
    private Runnable searchTimeout;
    private int pendingCorpora,pendingSearchJobs;
    private Runnable debounce;
    private String pendingExport;
    private boolean preparingExport,recitationDownloadQueued;
    private boolean pendingAmbient,previewAmbient,ambientSheetRequested,resumed,ambientResumePending,openOtherAppsAfterAmbientStart;
    private JSONObject pendingRestore;
    private String searchQuery="",hadithQuery="";
    private final List<HadithStore.Hit> hadithHits=new ArrayList<>();
    private final Set<String> selectedHadith=new LinkedHashSet<>();
    private final List<SearchEngine.Result> quranHits=new ArrayList<>();
    private int hadithTotal;
    private int searchScope=UnifiedQuery.ALL;
    private boolean sharingPdf;
    private TextView recitationBanner,recitationDownloadStatus;
    private Runnable recitationListener;
    private final LinkedHashSet<String> selectedEvidence=new LinkedHashSet<>();
    private final Map<String,JSONObject> selectionTrace=new LinkedHashMap<>();
    private final Map<String,List<TextView>> evidenceControls=new HashMap<>();
    private static final int EXPORT=700,IMPORT=701,OVERLAY_PERMISSION=702,NOTIFICATIONS=703,VOICE_SEARCH=704;
    private static final int SEARCH_RENDER_BATCH=8;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);app=(QuranApp)getApplication();
        if(state!=null){pendingVoiceScope=state.getInt("voice_scope",-1);hadithQuery=state.getString("hadith_query","");}
        if(state!=null){pendingAmbient=state.getBoolean("pending_ambient");previewAmbient=state.getBoolean("preview_ambient");ambientResumePending=state.getBoolean("ambient_resume_pending");openOtherAppsAfterAmbientStart=state.getBoolean("ambient_open_other_apps");}
        if(state!=null&&ExportStaging.validToken(state.getString("pending_export")))pendingExport=state.getString("pending_export");
        appearance=Appearance.load(this);Glass.apply(appearance);arabicFont=appearance.typeface(this);
        if(Build.VERSION.SDK_INT>=30)getWindow().setDecorFitsSystemWindows(false);
        root=new FrameLayout(this);backdrop=new Glass.Backdrop(this);root.addView(backdrop,new FrameLayout.LayoutParams(-1,-1));
        layout=column(this);root.addView(layout,new FrameLayout.LayoutParams(-1,-1));
        overlay=new FrameLayout(this);root.addView(overlay,new FrameLayout.LayoutParams(-1,-1));
        root.setOnApplyWindowInsetsListener((view,insets)->{
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets edges=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout()|WindowInsets.Type.ime());view.setPadding(edges.left,edges.top,edges.right,edges.bottom);}
            else view.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());return insets;
        });setContentView(root);
        TextView loading=text(this,"Aaris Quran\nOpening your offline Mushaf…",20,INK);loading.setGravity(Gravity.CENTER);layout.addView(loading,new LinearLayout.LayoutParams(-1,-1));
        app.ready(()->{
            if(isFinishing()||isDestroyed())return;
            if(app.loadError!=null){loading.setText(app.loadError+"\nOpen the app again. Your learning data remains stored separately.");return;}
            content=app.content;learning=app.learning;recitationListener=this::refreshRecitation;app.recitationChanged=recitationListener;
            language=learning.get("language","hi");translationId=learning.get("translation_edition","hindi_omari");translationSpeech=new TranslationSpeech(this);
            highContrast=Boolean.parseBoolean(learning.get("contrast","false"));
            arabicSize=appearance.arabicSize;
            String last=learning.get("position","Q:1:1");Ayah a=content.ayah(last);
            if(a!=null){readerSurah=a.surah;readerStart=a.number;}
            if(state!=null){tab=state.getInt("tab",1);reading=state.getBoolean("reading",true);quietReader=state.getBoolean("quiet_reader",false);readerSurah=state.getInt("surah",readerSurah);readerStart=state.getInt("start",readerStart);
                searchQuery=state.getString("query","");searchScope=state.getInt("search_scope",UnifiedQuery.ALL);ArrayList<String> ids=state.getStringArrayList("evidence");if(ids!=null)for(String id:ids)if(selectedEvidence.size()<50&&content.ayah(id)!=null)selectedEvidence.add(id);
                try{JSONObject traces=new JSONObject(state.getString("selection_trace","{}"));for(String id:selectedEvidence)selectionTrace.put(id,traces.has(id)?traces.getJSONObject(id):selectionOrigin("RESTORED_SELECTION_WITHOUT_TRACE"));}catch(JSONException ignored){}
            }
            readingPosition=content.readingPosition(state==null?learning.get("reader_anchor",""):state.getString("reader_anchor",""));
            if(readingPosition!=null){Ayah page=content.ayah(readingPosition.pageId);readerSurah=page.surah;readerStart=page.number;}
            if(getIntent().getBooleanExtra("open_ambient",false)){tab=3;ambientSheetRequested=true;getIntent().removeExtra("open_ambient");}
            tab=Math.max(0,Math.min(3,tab));show();
            if(state!=null&&state.getBoolean("search_open",false))searchScreen();
            if(ambientSheetRequested){ambientSheetRequested=false;ambientSettings();}
        });
    }
    private static float clamp(float x,float min,float max){return Math.max(min,Math.min(max,x));}
    private static float parseFloat(String value,float fallback){try{return Float.parseFloat(value);}catch(Exception e){return fallback;}}
    @Override protected void onSaveInstanceState(Bundle state){captureReaderPosition();super.onSaveInstanceState(state);state.putBoolean("pending_ambient",pendingAmbient);state.putBoolean("ambient_resume_pending",ambientResumePending);state.putBoolean("preview_ambient",previewAmbient);state.putBoolean("ambient_open_other_apps",openOtherAppsAfterAmbientStart);state.putString("pending_export",pendingExport);state.putInt("tab",tab);state.putBoolean("reading",reading);state.putBoolean("quiet_reader",quietReader);state.putInt("surah",readerSurah);state.putInt("start",readerStart);if(readingPosition!=null)state.putString("reader_anchor",readingPosition.encode());state.putString("query",searchQuery);state.putBoolean("search_open",searching);state.putInt("search_scope",searchScope);state.putString("hadith_query",hadithQuery);state.putInt("voice_scope",pendingVoiceScope);state.putStringArrayList("evidence",new ArrayList<>(selectedEvidence));String trace=new JSONObject(selectionTrace).toString();if(trace.length()<=64000)state.putString("selection_trace",trace);}
    @Override protected void onPostResume(){super.onPostResume();resumed=true;if(ambientResumePending){ambientResumePending=false;beginAmbient();}}
    @Override protected void onPause(){resumed=false;captureReaderPosition();if(learning!=null&&readingPosition!=null){learning.set("reader_anchor",readingPosition.encode());learning.set("position",readingPosition.anchorId);}super.onPause();}
    @Override protected void onDestroy(){ui.removeCallbacksAndMessages(null);searchGeneration.incrementAndGet();cancelSearchWork();Dialog dialog=activeDialog;activeDialog=null;if(dialog!=null)dialog.dismiss();if(app!=null&&app.recitationChanged==recitationListener)app.recitationChanged=null;if(translationSpeech!=null)translationSpeech.close();super.onDestroy();}
    @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);if(intent.getBooleanExtra("open_ambient",false)){intent.removeExtra("open_ambient");if(content==null){ambientSheetRequested=true;return;}tab=3;show();ambientSettings();}}
    private void show(){
        if(content==null||isDestroyed()||isFinishing())return;
        int bars=getWindow().getDecorView().getSystemUiVisibility();int light=View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        getWindow().getDecorView().setSystemUiVisibility(Appearance.luminance(appearance.background)>.38?bars|light:bars&~light);
        getWindow().setStatusBarColor(appearance.background);getWindow().setNavigationBarColor(appearance.background);captureReaderPosition();hideKeyboard();readerScroll=null;restoringReader=null;readerVerses.clear();evidenceControls.clear();searchGeneration.incrementAndGet();cancelSearchWork();if(debounce!=null)ui.removeCallbacks(debounce);hidePeek();layout.removeAllViews();searching=false;backdrop.highContrast=highContrast;backdrop.invalidate();
        header=row(this);pad(header,20,10);layout.addView(header,new LinearLayout.LayoutParams(-1,-2));
        body=column(this);layout.addView(body,new LinearLayout.LayoutParams(-1,0,1));
        recitationBanner=button("",()->audioControls(content.ayah("Q:"+app.recitationSurah+":"+app.recitationAyah)));layout.addView(recitationBanner);refreshRecitation();
        bottom=row(this);pad(bottom,6,5);bottom.setBackground(new Surface(this,Surface.Kind.NAV,highContrast));LinearLayout.LayoutParams navSize=new LinearLayout.LayoutParams(-1,-2);navSize.setMargins(dp(this,16),dp(this,6),dp(this,16),dp(this,10));layout.addView(bottom,navSize);
        if(tab==0)today();else if(tab==1){if(reading)reader();else library();}else if(tab==2)hadithLibrary();else map();
        nav("sun","Today",0);nav("book","Quran",1);nav("hadith","Hadith",2);nav("cards","Recall",3);
        Glass.reveal(body);
    }
    private void nav(String icon,String title,int index){
        LinearLayout v=column(this);v.setGravity(Gravity.CENTER);pad(v,4,7);
        if(tab==index)v.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));
        Glass.Icon i=new Glass.Icon(this,icon);i.color=tab==index?appearance.buttonInk():MUTED;v.addView(i,new LinearLayout.LayoutParams(dp(this,22),dp(this,22)));
        TextView t=text(this,title,11,tab==index?appearance.buttonInk():MUTED);t.setGravity(Gravity.CENTER);v.addView(t);
        v.setContentDescription(title);v.setSelected(tab==index);v.setFocusable(true);v.setMinimumHeight(dp(this,56));v.setOnClickListener(x->{if(tab==index&&(index!=1||reading))return;tab=index;quietReader=false;if(index==1)reading=true;show();});Glass.motion(v);
        LinearLayout.LayoutParams item=new LinearLayout.LayoutParams(0,-2,1);item.setMargins(dp(this,3),0,dp(this,3),0);bottom.addView(v,item);
    }
    private View iconButton(String icon,String description,Runnable action){
        FrameLayout f=new FrameLayout(this);f.setMinimumHeight(dp(this,48));f.setMinimumWidth(dp(this,48));f.setContentDescription(description);f.setTooltipText(description);f.setFocusable(true);f.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));
        Glass.Icon view=new Glass.Icon(this,icon);view.color=appearance.buttonInk();FrameLayout.LayoutParams p=new FrameLayout.LayoutParams(dp(this,23),dp(this,23),Gravity.CENTER);f.addView(view,p);f.setOnClickListener(v->action.run());Glass.motion(f);return f;
    }
    private void heading(String eyebrow,String title){
        LinearLayout label=column(this);TextView e=text(this,eyebrow,10,INK);e.setLetterSpacing(.18f);label.addView(e);
        TextView h=text(this,title,23,INK);h.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));label.addView(h);
        header.addView(label,new LinearLayout.LayoutParams(0,-2,1));header.addView(iconButton("settings","Reading settings",this::settings));
    }
    private LinearLayout scrollBody(){ScrollView sc=new ScrollView(this);sc.setFillViewport(false);sc.setClipToPadding(false);sc.setOverScrollMode(View.OVER_SCROLL_NEVER);body.addView(sc,new LinearLayout.LayoutParams(-1,-1));LinearLayout page=column(this);pad(page,20,12);sc.addView(page);return page;}
    private LinearLayout card(LinearLayout parent,Surface.Kind kind){LinearLayout v=column(this);pad(v,22,20);v.setBackground(new Surface(this,kind,highContrast));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(this,16);parent.addView(v,lp);return v;}
    private TextView button(String title,Runnable click){return action(title,click,false);}
    private TextView primary(String title,Runnable click){return action(title,click,true);}
    private View settingsRow(String icon,String title,Runnable click){
        LinearLayout row=row(this);pad(row,14,9);row.setMinimumHeight(dp(this,52));row.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));row.setFocusable(true);row.setClickable(true);
        Glass.Icon glyph=new Glass.Icon(this,icon);glyph.color=MINT;row.addView(glyph,new LinearLayout.LayoutParams(dp(this,24),dp(this,24)));
        TextView label=text(this,title,15,INK);label.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));pad(label,12,0);row.addView(label,new LinearLayout.LayoutParams(0,-2,1));
        Glass.Icon next=new Glass.Icon(this,"next");next.color=MUTED;row.addView(next,new LinearLayout.LayoutParams(dp(this,20),dp(this,20)));
        row.setContentDescription(title);row.setOnClickListener(v->click.run());Glass.motion(row);return row;
    }
    private View quickAction(String icon,String title,String meta,Runnable click){
        LinearLayout box=column(this);box.setGravity(Gravity.CENTER);pad(box,8,10);box.setMinimumHeight(dp(this,82));
        box.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));box.setFocusable(true);box.setClickable(true);
        Glass.Icon glyph=new Glass.Icon(this,icon);glyph.color=MINT;LinearLayout.LayoutParams gp=new LinearLayout.LayoutParams(dp(this,28),dp(this,28));gp.gravity=Gravity.CENTER;box.addView(glyph,gp);
        TextView name=text(this,title,13,INK);name.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));name.setGravity(Gravity.CENTER);box.addView(name);
        if(meta!=null&&!meta.isEmpty()){TextView small=text(this,meta,10,MUTED);small.setGravity(Gravity.CENTER);box.addView(small);}
        box.setContentDescription(title+(meta==null||meta.isEmpty()?"":", "+meta));box.setOnClickListener(v->click.run());Glass.motion(box);return box;
    }
    private View actionChip(String icon,String title,Runnable click){
        LinearLayout chip=row(this);pad(chip,12,9);chip.setGravity(Gravity.CENTER);chip.setMinimumHeight(dp(this,46));
        chip.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));chip.setFocusable(true);chip.setClickable(true);
        Glass.Icon glyph=new Glass.Icon(this,icon);glyph.color=appearance.buttonInk();chip.addView(glyph,new LinearLayout.LayoutParams(dp(this,20),dp(this,20)));
        TextView name=text(this,title,13,appearance.buttonInk());name.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));pad(name,8,0);chip.addView(name);
        chip.setContentDescription(title);chip.setOnClickListener(v->click.run());Glass.motion(chip);return chip;
    }
    private TextView action(String title,Runnable click,boolean primary){TextView b=text(this,title,14,appearance.buttonInk());b.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));b.setGravity(Gravity.CENTER);pad(b,16,13);b.setMinimumHeight(dp(this,48));b.setBackground(Glass.touch(this,primary?Surface.Kind.PRIMARY:Surface.Kind.BUTTON,highContrast));b.setFocusable(true);b.setOnClickListener(v->click.run());Glass.motion(b);return b;}
    private TextView label(String text){TextView v=Glass.text(this,text,11,INK);v.setLetterSpacing(.12f);return v;}
    private void gap(LinearLayout v,int dp){View gap=new View(this);v.addView(gap,new LinearLayout.LayoutParams(1,Glass.dp(this,dp)));}
    private ArabicText arabic(String value,float size){ArabicText v=new ArabicText(this);v.setText(value);v.setTextSize(size);v.setReliefEnabled(!highContrast);v.setTypeface(arabicFont);v.setTextDirection(View.TEXT_DIRECTION_RTL);v.setGravity(Gravity.CENTER);v.setLineSpacing(dp(this,appearance.spacing),1.08f);return v;}
    private ArabicText hadithArabic(String value,float size){
        ArabicText v=new ArabicText(this);v.setText(value);v.setTextSize(size);v.setTypeface(appearance.hadithTypeface(this));
        v.setReliefEnabled(!highContrast);v.setTextDirection(View.TEXT_DIRECTION_RTL);v.setGravity(Gravity.RIGHT);
        v.setIncludeFontPadding(true);v.setLineSpacing(dp(this,appearance.spacing*.4f),1f);
        if(Build.VERSION.SDK_INT>=28)v.setFallbackLineSpacing(false);
        return v;
    }
    private void caption(LinearLayout v,String value){TextView t=text(this,value,13,MUTED);t.setLineSpacing(dp(this,3),1.12f);v.addView(t);}
    private void toast(String value){if(!isDestroyed()&&!isFinishing())Toast.makeText(this,value,Toast.LENGTH_SHORT).show();}

    private void today(){
        heading("QURAN, WITH YOU", "Aaris");LinearLayout page=scrollBody();

        TextView intro=text(this,"A little time.\nPeace for the heart.",29,INK);
        intro.setTypeface(Typeface.create("serif",Typeface.NORMAL));page.addView(intro);gap(page,8);
        caption(page,"The Quran is always here for you.");gap(page,20);

        ContentStore.Surah s=content.surah(readerSurah);
        int resumeAyah=readingPosition==null?readerStart:RecallTarget.parse(readingPosition.anchorId).ayah;
        Ayah resume=content.ayah("Q:"+readerSurah+":"+resumeAyah);
        if(resume==null){resumeAyah=readerStart;resume=content.ayah("Q:"+readerSurah+":"+resumeAyah);}
        if(resume==null){readerSurah=1;resumeAyah=1;s=content.surah(1);resume=content.ayah("Q:1:1");}

        LinearLayout hero=card(page,Surface.Kind.HERO);
        hero.addView(label("WHERE YOU LEFT OFF"));gap(hero,18);
        hero.addView(arabic(resume.arabic,34));gap(hero,20);
        hero.addView(text(this,"Surah "+s.name,22,INK));
        caption(hero,"Ayah "+resumeAyah+" · Your last place");gap(hero,18);

        LinearLayout actions=row(this);
        TextView openQuran=primary("Open Quran  →",()->{tab=1;reading=true;show();});
        TextView openBookmarks=button("Open Bookmarks  →",this::bookmarks);
        openQuran.setSingleLine(true);openBookmarks.setSingleLine(true);
        openQuran.setTextSize(13);openBookmarks.setTextSize(13);
        LinearLayout.LayoutParams left=new LinearLayout.LayoutParams(0,-2,1);
        left.rightMargin=dp(this,6);
        LinearLayout.LayoutParams right=new LinearLayout.LayoutParams(0,-2,1);
        right.leftMargin=dp(this,6);
        actions.addView(openQuran,left);actions.addView(openBookmarks,right);
        hero.addView(actions);gap(hero,10);

        TextView bookmarkCount=text(this,learning.bookmarks().size()+" bookmarks · Always offline",11,MUTED);
        bookmarkCount.setGravity(Gravity.CENTER);hero.addView(bookmarkCount);
        gap(page,18);
        LinearLayout personal=card(page,Surface.Kind.PANEL);personal.addView(label("PERSONALIZE AARIS"));gap(personal,10);
        personal.addView(button("Appearance · Colors & fonts",this::appearanceStudio));gap(personal,8);
        personal.addView(button("Translation & reading",this::settings));gap(personal,8);
        personal.addView(button("Reciter & downloads",()->audioControls(content.ayah("Q:"+readerSurah+":"+readerStart))));gap(personal,8);
        personal.addView(button("Study · Pins & collections",this::studyLibrary));
    }
    private void appearanceStudio(){
        Dialog previous=activeDialog;activeDialog=null;if(previous!=null)previous.dismiss();
        TranslationStore.Entry sample=app.translations==null?null:app.translations.get(translationId,"Q:1:1");
        activeDialog=AppearanceStudio.show(this,content.ayah("Q:1:1").arabic,sample==null?"Selected translation is not installed.":sample.text+"\n"+sample.edition.attribution(),sample!=null&&"ur".equals(sample.edition.language),()->{
            activeDialog=null;if(isFinishing()||isChangingConfigurations())return;
            appearance=Appearance.load(this);Glass.apply(appearance);arabicFont=appearance.typeface(this);arabicSize=appearance.arabicSize;show();
        });
    }
    private void hadithLibrary(){
        heading("HADITH · OFFLINE", "Hadith Library");
        hadithHits.clear();selectedHadith.clear();hadithTotal=0;LinearLayout page=scrollBody();
        HadithStore store=app.hadith;
        if(store==null){
            LinearLayout unavailable=card(page,Surface.Kind.HERO);
            unavailable.addView(label("LOCAL CONTENT ONLY"));gap(unavailable,12);
            unavailable.addView(text(this,"Offline Hadith pack\nnot installed yet.",26,INK));gap(unavailable,12);
            caption(unavailable,app.hadithLoadError==null?"This screen no longer opens a website. A verified Hadith pack must be bundled in the APK before collections are shown.":app.hadithLoadError);
            gap(unavailable,14);caption(unavailable,"Quran remains fully offline and unchanged.");
            return;
        }

        LinearLayout intro=card(page,Surface.Kind.HERO);
        intro.addView(label(store.collectionCount+" COLLECTIONS · "+store.recordCount+" RECORDS"));gap(intro,10);
        intro.addView(text(this,"Read Hadith,\nwithout leaving Aaris.",27,INK));gap(intro,10);
        caption(intro,store.hasLanguage("en")?"Arabic with available translations · Offline":"Arabic edition · Translations are not installed in this pack.");
        intro.addView(button("About this edition",()->{
            LinearLayout details=sheet("Hadith edition");caption(details,store.sourceName+" · "+store.sourceVersion);
            caption(details,store.redistributionBasis);caption(details,"Reference numbering follows this edition. Other editions can use different numbers.");
        }));
        TextView searchEntry=button("Search Quran & Hadith",()->{searchScope=UnifiedQuery.ALL;searchScreen();});
        searchEntry.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_menu_search,0,0,0);
        page.addView(searchEntry,new LinearLayout.LayoutParams(-1,-2));gap(page,14);
        LinearLayout list=column(this);page.addView(list);

        Runnable collections=()->{
            list.removeAllViews();int index=0;
            for(HadithStore.CollectionInfo info:store.collections()){
                LinearLayout c=card(list,Surface.Kind.PANEL);LinearLayout line=row(this);
                TextView number=text(this,String.format(Locale.ROOT,"%02d",++index),12,GOLD);
                line.addView(number,new LinearLayout.LayoutParams(dp(this,38),-2));
                LinearLayout names=column(this);names.addView(text(this,info.nameEn,18,INK));
                TextView ar=hadithArabic(info.nameAr,24);names.addView(ar);
                line.addView(names,new LinearLayout.LayoutParams(0,-2,1));
                TextView arrow=text(this,"›",28,MINT);line.addView(arrow);c.addView(line);gap(c,8);
                caption(c,info.count+" Hadith records · Offline");
                c.setFocusable(true);c.setContentDescription(info.nameEn+", "+info.count+" records, offline");
                c.setOnClickListener(v->hadithCollection(info.id));Glass.motion(c);
            }
        };
        collections.run();

    }
    private void cancelSearchWork(){
        if(searchTimeout!=null)ui.removeCallbacks(searchTimeout);searchTimeout=null;
        if(searchCancellation!=null)searchCancellation.cancel();searchCancellation=null;
        if(searchTask!=null)searchTask.cancel(true);
        if(quranSearchTask!=null)quranSearchTask.cancel(true);
    }
    private CancellationSignal beginSearch(int generation,TextView status){
        CancellationSignal signal=new CancellationSignal();searchCancellation=signal;
        searchTimeout=()->{
            if(searchGeneration.get()!=generation||searchCancellation!=signal)return;
            cancelSearchWork();pendingCorpora=0;pendingSearchJobs=0;
            status.setText("Search took too long. Try a shorter phrase or a book and number.");
        };
        ui.postDelayed(searchTimeout,20000);return signal;
    }
    private void finishSearch(CancellationSignal signal){
        if(searchCancellation!=signal)return;
        if(searchTimeout!=null)ui.removeCallbacks(searchTimeout);searchTimeout=null;searchCancellation=null;
    }
    private void loadHadithSearch(String q,int offset,int generation,LinearLayout list,TextView status){
        final CancellationSignal signal=searchCancellation!=null?searchCancellation:beginSearch(generation,status);
        pendingSearchJobs++;
        searchTask=app.searchWorker.submit(()->{try{
            HadithStore.SearchPage response=app.hadith.searchPage(q,50,offset,signal);
            ui.post(()->{if(isDestroyed()||!searching||signal.isCanceled()||searchGeneration.get()!=generation)return;
                appendHadithResults(q,response,generation,list,status);if(--pendingSearchJobs==0)finishSearch(signal);
            });
        }catch(CancellationException|OperationCanceledException ignored){}catch(Exception error){ui.post(()->{
            if(!isDestroyed()&&searching&&!signal.isCanceled()&&searchGeneration.get()==generation){
                if(--pendingSearchJobs==0)finishSearch(signal);status.setText("Hadith search could not finish. Please try again.");
            }
        });}});
    }
    private void appendHadithResults(String q,HadithStore.SearchPage response,int generation,LinearLayout list,TextView status){
        hadithTotal=response.total;hadithHits.addAll(response.hits);
        if(response.offset==0)showSearchShortcut(list,true,q);
        appendHadithBatch(q,response,generation,list,status,0);
    }
    private void appendHadithBatch(String q,HadithStore.SearchPage response,int generation,LinearLayout list,TextView status,int cursor){
        if(isDestroyed()||!searching||searchGeneration.get()!=generation)return;
        boolean browse=HadithQuery.parse(q).isCollectionBrowse();
        int end=Math.min(cursor+SEARCH_RENDER_BATCH,response.hits.size());
        for(HadithStore.Hit hit:response.hits.subList(cursor,end)){
            LinearLayout wrapper=column(this);list.addView(wrapper);
            wrapper.addView(label(browse?"COLLECTION RECORD":hit.reference?"REFERENCE MATCH":hit.match.band+" TEXT MATCH"));
            if(!hit.reference&&!browse)caption(wrapper,hit.match.explanation());
            hadithResultCard(wrapper,hit.record);
            wrapper.addView(button("Remember this match",()->rememberSearch(true,q,hit.record.id)));
            CheckBox select=new CheckBox(this);select.setText("Select for PDF");select.setTextColor(INK);select.setMinHeight(dp(this,48));select.setChecked(selectedHadith.contains(hit.record.id));wrapper.addView(select);
            select.setOnCheckedChangeListener((v,checked)->{if(checked)selectedHadith.add(hit.record.id);else selectedHadith.remove(hit.record.id);});gap(wrapper,16);
        }
        if(end<response.hits.size()){
            status.setText("Showing "+(response.offset+end)+" of "+response.total+"…");
            list.postOnAnimation(()->appendHadithBatch(q,response,generation,list,status,end));return;
        }
        status.setText(response.total==0?(HadithQuery.parse(q).isReference()?"This reference is not in the installed edition. Check its numbering or search an Arabic phrase.":"No Hadith text match in the installed edition."):hadithHits.size()+" of "+response.total+(response.limited?" closest Hadith matches · Narrow the phrase for more precision":" Hadith matches"));
        if(hadithHits.size()<response.total){TextView more=button("Load next 50 Hadith matches",()->{});list.addView(more);more.setOnClickListener(v->{more.setEnabled(false);list.removeView(more);loadHadithSearch(q,hadithHits.size(),generation,list,status);});}
    }

    private void hadithResultCard(LinearLayout parent,HadithStore.Record record){
        HadithStore store=app.hadith;if(store==null)return;
        HadithStore.CollectionInfo info=store.collection(record.collectionId);
        LinearLayout c=card(parent,Surface.Kind.PANEL);
        c.addView(label((info==null?record.collectionId:info.nameEn)+" · "+record.number));gap(c,10);
        TextView ar=hadithArabic(record.matnAr==null?record.arabic:record.matnAr,Math.min(appearance.arabicSize,28));ar.setMaxLines(5);ar.setEllipsize(TextUtils.TruncateAt.END);c.addView(ar);gap(c,8);
        HadithStore.DisplayTranslation translation=store.translation(record,readingLanguage());
        if(translation!=null){
            TextView translated=text(this,translation.text,appearance.translationSize,appearance.translationInk());
            translated.setMaxLines(4);translated.setEllipsize(TextUtils.TruncateAt.END);
            if("ur".equals(translation.language)||"ar".equals(translation.language)){
                translated.setTextDirection(View.TEXT_DIRECTION_RTL);translated.setGravity(Gravity.RIGHT);
            }
            c.addView(translated);gap(c,6);caption(c,translation.provenance);
            if(!readingLanguage().equals(translation.language))caption(c,"Showing "+languageName(translation.language)+"; "+languageName(readingLanguage())+" is not installed for this record.");
        }
        List<String> grades=store.grades(record.id);if(!grades.isEmpty())caption(c,String.join(" · ",grades));
        c.setFocusable(true);c.setContentDescription((info==null?"Hadith":info.nameEn)+" "+record.number);
        c.setOnClickListener(v->hadithRecord(record.id));Glass.motion(c);
    }

    private void hadithCollection(String collectionId){
        HadithStore store=app.hadith;if(store==null)return;
        HadithStore.CollectionInfo info=store.collection(collectionId);if(info==null)return;
        List<HadithStore.BookInfo> books=store.books(collectionId);
        if(books.isEmpty()){hadithRecordsPage(info.nameEn,collectionId,null,null,0);return;}
        LinearLayout page=sheet(info.nameEn);TextView ar=arabic(info.nameAr,28);page.addView(ar);gap(page,8);
        caption(page,info.count+" records · "+info.edition+" · Offline");gap(page,14);
        for(HadithStore.BookInfo book:books){
            LinearLayout row=Glass.row(this);pad(row,14,12);row.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));
            TextView n=text(this,book.number,12,GOLD);row.addView(n,new LinearLayout.LayoutParams(dp(this,42),-2));
            LinearLayout names=column(this);names.addView(text(this,book.nameEn==null?"Book "+book.number:book.nameEn,16,INK));
            if(book.nameAr!=null){TextView nameAr=hadithArabic(book.nameAr,22);names.addView(nameAr);}
            names.addView(text(this,book.count+" records",11,MUTED));row.addView(names,new LinearLayout.LayoutParams(0,-2,1));
            row.setFocusable(true);row.setOnClickListener(v->hadithBook(collectionId,book));Glass.motion(row);
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(this,8);page.addView(row,lp);
        }
    }

    private void hadithBook(String collectionId,HadithStore.BookInfo book){
        HadithStore store=app.hadith;if(store==null)return;
        List<HadithStore.ChapterInfo> chapters=store.chapters(collectionId,book.id);
        String title=book.nameEn==null?"Book "+book.number:book.nameEn;
        if(chapters.isEmpty()){hadithRecordsPage(title,collectionId,book.id,null,0);return;}
        LinearLayout page=sheet(title);
        if(book.nameAr!=null)page.addView(arabic(book.nameAr,26));gap(page,10);
        page.addView(button("Browse all "+book.count+" records",()->hadithRecordsPage(title,collectionId,book.id,null,0)));gap(page,14);
        page.addView(label("CHAPTERS"));gap(page,8);
        for(HadithStore.ChapterInfo chapter:chapters){
            String name=chapter.nameEn==null?"Chapter "+chapter.number:chapter.nameEn;
            TextView b=button(chapter.number+" · "+name+"  ("+chapter.count+")",
                ()->hadithRecordsPage(name,collectionId,book.id,chapter.id,0));
            b.setGravity(Gravity.LEFT|Gravity.CENTER_VERTICAL);page.addView(b);gap(page,8);
        }
    }

    private void hadithRecordsPage(String title,String collectionId,String bookId,String chapterId,int offset){
        HadithStore store=app.hadith;if(store==null)return;
        final int size=50;List<HadithStore.Record> records=store.records(collectionId,bookId,chapterId,size,offset);
        LinearLayout page=sheet(title);caption(page,"Records "+(records.isEmpty()?0:offset+1)+"–"+(offset+records.size())+" · Offline");gap(page,12);
        for(HadithStore.Record record:records){
            TextView b=button("Hadith "+record.number,()->hadithRecord(record.id));
            b.setGravity(Gravity.LEFT|Gravity.CENTER_VERTICAL);page.addView(b);gap(page,8);
        }
        if(records.isEmpty())caption(page,"No records in this section.");
        if(offset>0||records.size()==size){
            gap(page,10);LinearLayout nav=row(this);
            if(offset>0){TextView prev=button("← Previous",()->hadithRecordsPage(title,collectionId,bookId,chapterId,Math.max(0,offset-size)));nav.addView(prev,new LinearLayout.LayoutParams(0,-2,1));}
            if(records.size()==size){TextView next=button("Next →",()->hadithRecordsPage(title,collectionId,bookId,chapterId,offset+size));LinearLayout.LayoutParams np=new LinearLayout.LayoutParams(0,-2,1);np.leftMargin=dp(this,offset>0?8:0);nav.addView(next,np);}
            page.addView(nav);
        }
    }

    private void hadithRecord(String id){
        HadithStore store=app.hadith;if(store==null)return;
        HadithStore.Record record=store.record(id);if(record==null)return;
        HadithStore.CollectionInfo info=store.collection(record.collectionId);
        LinearLayout page=sheet((info==null?"Hadith":info.nameEn)+" · "+record.number);
        ArabicText source=hadithArabic(record.arabic,appearance.arabicSize);source.setTextIsSelectable(true);page.addView(source);gap(page,14);
        HadithStore.DisplayTranslation translation=store.translation(record,readingLanguage());
        if(translation!=null){
            TextView translated=text(this,translation.text,appearance.translationSize,appearance.translationInk());translated.setTextIsSelectable(true);
            if("ur".equals(translation.language)||"ar".equals(translation.language)){
                translated.setTextDirection(View.TEXT_DIRECTION_RTL);translated.setGravity(Gravity.RIGHT);
            }
            page.addView(translated);gap(page,8);caption(page,translation.provenance);gap(page,10);
            if(!readingLanguage().equals(translation.language))caption(page,"Showing "+languageName(translation.language)+"; "+languageName(readingLanguage())+" is not installed for this record.");
        }else{
            caption(page,"Arabic source text only in this offline pack.");gap(page,10);
        }
        if(record.narrator!=null&&!record.narrator.trim().isEmpty())caption(page,"Narrator: "+record.narrator);
        List<String> grades=store.grades(id);if(!grades.isEmpty()){gap(page,12);page.addView(label("GRADING"));for(String grade:grades)caption(page,grade);}
        List<String> refs=store.references(id);if(!refs.isEmpty()){gap(page,12);page.addView(label("REFERENCES"));for(String ref:refs)caption(page,ref);}
        gap(page,12);caption(page,"Source record: "+record.sourceRef+"\nPack: "+store.packId+" · "+store.contentVersion);
    }

    private void openWebsite(Uri uri){hideKeyboard();try{startActivity(new Intent(Intent.ACTION_VIEW,uri));}catch(ActivityNotFoundException e){toast("Install a browser to open this link");}}
    private int ambientItems(){int count=0;for(Recall.State state:learning.states().values())if(state.active&&content.hasRecallTarget(state.target)){ContentStore.Word w=content.word(state.target);if(w==null||w.hasGloss(language))count++;}return count;}
    private void ambientCard(LinearLayout page){
        LinearLayout c=card(page,Surface.Kind.PANEL);
        c.addView(settingsRow("clock",app.ambientRunning?"Recall timer · "+AmbientSettings.minutes(this)+" min":"Recall timer · Off",this::ambientSettings));
    }
    private void ambientSettings(){
        LinearLayout page=sheet("Set timer");Dialog dialog=activeDialog;
        TextView status=text(this,app.ambientRunning?"Running · every "+AmbientSettings.minutes(this)+" min":"",13,MINT);
        status.setGravity(Gravity.CENTER);status.setVisibility(app.ambientRunning?View.VISIBLE:View.GONE);page.addView(status);if(app.ambientRunning)gap(page,10);

        EditText minutes=new EditText(this);minutes.setTextColor(INK);minutes.setHintTextColor(MUTED);minutes.setTextSize(22);
        minutes.setHint("Minutes");minutes.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);minutes.setFilters(new InputFilter[]{new InputFilter.LengthFilter(3)});
        minutes.setSingleLine(true);minutes.setText(""+AmbientSettings.minutes(this));minutes.setSelectAllOnFocus(true);
        minutes.setGravity(Gravity.CENTER);minutes.setBackground(new Surface(this,Surface.Kind.BUTTON,highContrast));pad(minutes,16,8);
        page.addView(minutes,new LinearLayout.LayoutParams(-1,dp(this,56)));gap(page,10);

        LinearLayout presets=row(this);
        for(int value:new int[]{3,5,10,15}){
            TextView choice=button(value+" min",()->minutes.setText(""+value));pad(choice,6,11);
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.rightMargin=dp(this,4);presets.addView(choice,p);
        }
        page.addView(presets);gap(page,14);

        Switch due=new Switch(this);due.setText("Due items only");due.setTextColor(INK);due.setChecked(AmbientSettings.dueOnly(this));due.setMinimumHeight(dp(this,48));page.addView(due);gap(page,12);

        page.addView(settingsRow("cards",ambientItems()+" saved items",this::chooseAmbientItems));gap(page,14);

        java.util.function.Consumer<Boolean> start=preview->{
            int value;try{value=Integer.parseInt(minutes.getText().toString());}catch(NumberFormatException e){value=0;}
            if(value<1||value>120){minutes.setError("Choose 1–120 minutes");return;}
            AmbientSettings.save(this,value,due.isChecked());
            if(ambientItems()==0){openOtherAppsAfterAmbientStart=false;chooseAmbientItems();return;}
            previewAmbient=preview;pendingAmbient=true;beginAmbient();
        };

        page.addView(primary(app.ambientRunning?"Update timer":"Start timer",()->{openOtherAppsAfterAmbientStart=false;start.accept(false);}));gap(page,9);
        page.addView(settingsRow("share","Open in other apps",()->{
            if(app.ambientRunning){dialog.dismiss();openOtherApps();}
            else{openOtherAppsAfterAmbientStart=true;start.accept(false);}
        }));gap(page,9);
        page.addView(settingsRow("clock","Test (10 seconds)",()->{openOtherAppsAfterAmbientStart=true;start.accept(true);}));gap(page,9);

        if(app.ambientRunning){
            page.addView(settingsRow("close","Stop timer",()->{openOtherAppsAfterAmbientStart=false;AmbientSettings.status(this,false,"Stopped");stopService(new Intent(this,AmbientRecallService.class));dialog.dismiss();ui.postDelayed(this::show,250);}));
        }
    }
    private void chooseAmbientItems(){
        LinearLayout page=sheet("Add recall items");
        Ayah a=content.ayah(readingPosition==null?"Q:"+readerSurah+":"+readerStart:readingPosition.anchorId);if(a==null)return;
        page.addView(label(content.surah(a.surah).name+" · "+a.surah+":"+a.number));gap(page,10);
        page.addView(button("Add this ayah",()->{enroll(a.id,a.id);ambientSettings();}));gap(page,12);
        int count=0;for(ContentStore.Word word:content.words(a.id))if(word.hasGloss(language)){
            if(count++==8)break;LinearLayout row=Glass.row(this);pad(row,8,10);TextView ar=arabic(word.arabic,30);row.addView(ar,new LinearLayout.LayoutParams(0,-2,1));
            Recall.State memory=learning.states().get(word.id);TextView meaning=text(this,word.gloss(language)+(memory!=null&&memory.active?" ✓":"  +"),15,INK);row.addView(meaning,new LinearLayout.LayoutParams(0,-2,1));
            row.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));row.setFocusable(true);row.setOnClickListener(v->{enroll(word.id,word.ayahId);meaning.setText(word.gloss(language)+" ✓");});Glass.motion(row);
            page.addView(row);gap(page,8);
        }
        gap(page,10);page.addView(primary("Back to timer",this::ambientSettings));gap(page,8);
        page.addView(button("Open another ayah",()->{activeDialog.dismiss();tab=1;reading=false;show();}));
    }
    private void openOtherApps(){
        try{
            Intent home=new Intent(Intent.ACTION_MAIN);home.addCategory(Intent.CATEGORY_HOME);home.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(home);
        }catch(ActivityNotFoundException e){toast("Open another app from your Home screen");}
    }
    private void beginAmbient(){
        if(!pendingAmbient||isFinishing()||isDestroyed())return;
        if(!resumed){ambientResumePending=true;return;}
        if(!Settings.canDrawOverlays(this)){
            Intent permission=new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:"+getPackageName()));
            try{startActivityForResult(permission,OVERLAY_PERMISSION);}catch(ActivityNotFoundException e){pendingAmbient=false;openOtherAppsAfterAmbientStart=false;toast("Overlay permission settings are not available on this phone");}return;
        }
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED&&!AmbientSettings.askedNotifications(this)){
            AmbientSettings.notificationsAsked(this);requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},NOTIFICATIONS);return;
        }
        if(learning==null){app.ready(this::beginAmbient);return;}
        pendingAmbient=false;
        if(ambientItems()==0){openOtherAppsAfterAmbientStart=false;chooseAmbientItems();return;}
        boolean leave=openOtherAppsAfterAmbientStart;openOtherAppsAfterAmbientStart=false;
        try{
            startForegroundService(new Intent(this,AmbientRecallService.class).putExtra(AmbientRecallService.PREVIEW,previewAmbient));
            if(activeDialog!=null)activeDialog.dismiss();
            if(leave)ui.postDelayed(this::openOtherApps,220);else ui.postDelayed(this::show,250);
        }catch(RuntimeException e){
            openOtherAppsAfterAmbientStart=false;AmbientSettings.status(this,false,"Start failed");toast("Timer could not start. Try again.");
        }
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(request==NOTIFICATIONS)beginAmbient();}
    private void library(){
        heading("114 SURAHS · OFFLINE", "Quran al-Kareem");LinearLayout page=scrollBody();
        EditText filter=new EditText(this);filter.setSingleLine(true);filter.setTextColor(INK);filter.setHintTextColor(MUTED);filter.setHint("Surah name or number");filter.setTextSize(15);pad(filter,14,8);filter.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));page.addView(filter,new LinearLayout.LayoutParams(-1,dp(this,52)));gap(page,16);
        LinearLayout list=column(this);page.addView(list);
        Runnable fill=()->{list.removeAllViews();String q=Arabic.tolerant(filter.getText().toString());for(ContentStore.Surah s:content.surahs){
            String searchable=Arabic.tolerant(s.name+" "+s.arabic+" "+s.meaning+" "+s.id);
            if(!q.isEmpty()&&!searchable.contains(q))continue;
            LinearLayout row=Glass.row(this);pad(row,16,14);row.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));
            TextView number=text(this,String.format(Locale.ROOT,"%02d",s.id),13,GOLD);row.addView(number,new LinearLayout.LayoutParams(dp(this,38),-2));
            LinearLayout names=column(this);names.addView(text(this,s.name,17,INK));names.addView(text(this,s.count+" ayahs · "+s.meaning,11,MUTED));row.addView(names,new LinearLayout.LayoutParams(0,-2,1));
            TextView ar=arabic(s.arabic,24);row.addView(ar,new LinearLayout.LayoutParams(-2,-2));row.setContentDescription(s.name+", "+s.count+" ayahs");row.setFocusable(true);row.setOnClickListener(v->open(s.id,1));Glass.motion(row);
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(this,10);list.addView(row,lp);
        }};
        final Runnable[] pendingFilter={null};
        filter.addTextChangedListener(watcher(()->{
            if(pendingFilter[0]!=null)ui.removeCallbacks(pendingFilter[0]);
            pendingFilter[0]=()->{
                pendingFilter[0]=null;
                if(filter.isAttachedToWindow())fill.run();
            };
            ui.postDelayed(pendingFilter[0],100);
        }));
        fill.run();
    }
    private void open(int surah,int ayah){readerScroll=null;readerVerses.clear();readerSurah=Math.max(1,Math.min(114,surah));readerStart=Math.max(1,Math.min(content.surah(readerSurah).count,ayah));reading=true;tab=1;String id="Q:"+readerSurah+":"+readerStart;readingPosition=new ReadingPosition(id,id,0,0,true);learning.set("position",id);learning.set("reader_anchor",readingPosition.encode());hideKeyboard();show();}
    private void reader(){
        ContentStore.Surah s=content.surah(readerSurah);
        header.addView(iconButton("back","Surah list",()->{reading=false;show();}));
        LinearLayout titles=column(this);pad(titles,12,0);titles.addView(label("AARIS · OFFLINE"));titles.addView(text(this,"Quran",23,INK));header.addView(titles,new LinearLayout.LayoutParams(0,-2,1));
        header.addView(iconButton("search","Search Quran",this::searchScreen));
        LinearLayout page=scrollBody();pad(page,16,8);readerScroll=(ScrollView)page.getParent();renderedPage="Q:"+readerSurah+":"+readerStart;
        readerScroll.setOnScrollChangeListener((View v,int x,int y,int oldX,int oldY)->{if(y!=oldY)hidePeek();});
        LinearLayout tools=row(this);TextView surahs=button("Surahs  ↓",()->{reading=false;show();});tools.addView(surahs,new LinearLayout.LayoutParams(0,-2,1));TextView readingStyle=button("Aa · Reading",this::settings);LinearLayout.LayoutParams styleSize=new LinearLayout.LayoutParams(0,-2,1);styleSize.leftMargin=dp(this,8);tools.addView(readingStyle,styleSize);TextView audioPack=button(app.wordAudio!=null&&app.wordAudio.installedSurah(readerSurah)?"Word audio ✓":"Word audio ↓",()->audioSurahPrompt(readerSurah));LinearLayout.LayoutParams audioSize=new LinearLayout.LayoutParams(0,-2,1);audioSize.leftMargin=dp(this,8);tools.addView(audioPack,audioSize);page.addView(tools);gap(page,8);page.addView(button("Translation · "+(app.translations==null||app.translations.edition(translationId)==null?"Unavailable":app.translations.edition(translationId).language.toUpperCase(Locale.ROOT))+" ↓",this::translationSettings));gap(page,14);
        TextView name=arabic(s.arabic,28);page.addView(name,new LinearLayout.LayoutParams(-1,-2));
        TextView latin=text(this,s.name,24,INK);latin.setGravity(Gravity.CENTER);latin.setTypeface(Typeface.create("serif",Typeface.NORMAL));page.addView(latin);
        TextView sub=text(this,s.meaning+"  ·  "+s.count+" ayahs",12,MUTED);sub.setGravity(Gravity.CENTER);page.addView(sub);gap(page,10);
        TextView interaction=text(this,"Tap a word for meaning · Book icon opens Study",12,MUTED);interaction.setGravity(Gravity.CENTER);page.addView(interaction);gap(page,22);
        String reciter=getSharedPreferences("recitation",0).getString("reciter",RecitationDownloads.IDS[0]);
        boolean recitationOffline=app.recitationDownloads.ready(reciter,readerSurah,s.count);
        List<Ayah> ayahs=content.page(readerSurah,readerStart,8);
        Map<String,Recall.State> learningStates=learning.states();long recallNow=System.currentTimeMillis();
        for(Ayah a:ayahs){
            LinearLayout panel=card(page,Surface.Kind.MUSHAF);
            LinearLayout bar=row(this);TextView reference=text(this,String.format(Locale.ROOT,"%d : %d",a.surah,a.number),12,MUTED);bar.addView(reference,new LinearLayout.LayoutParams(0,-2,1));
            View play=iconButton("play","Play ayah "+a.number+(recitationOffline?" · Surah downloaded":""),()->playAyah(a));
            if(recitationOffline){Glass.Icon tick=new Glass.Icon(this,"check");tick.color=0xff44b57d;FrameLayout.LayoutParams badge=new FrameLayout.LayoutParams(dp(this,14),dp(this,14),Gravity.BOTTOM|Gravity.RIGHT);((FrameLayout)play).addView(tick,badge);}bar.addView(play);
            bar.addView(iconButton("bookmark",learning.bookmarked(a.id)?"Remove bookmark":"Save ayah",()->{learning.toggleBookmark(a.id);toast(learning.bookmarked(a.id)?"Ayah saved":"Bookmark removed");}));
            bar.addView(iconButton("book","Study ayah · translations, compare & notes",()->studyAyah(a)));
            View menu=iconButton("more","Ayah "+a.number+": bookmark, meaning, recall and share",()->ayahActions(a));bar.addView(menu,new LinearLayout.LayoutParams(dp(this,48),dp(this,48)));panel.addView(bar);gap(panel,8);
            List<ContentStore.Word> words=content.words(a.id);
            QuranText verse=new QuranText(this,arabicFont,a,words,arabicSize,this::tapWord);verse.setReliefEnabled(!highContrast);verse.setLineSpacing(dp(this,appearance.spacing),1.08f);readerVerses.put(a.id,verse);panel.addView(verse,new LinearLayout.LayoutParams(-1,-2));
            addTranslation(panel,a);
            for(ContentStore.Word w:words){Recall.State memory=learningStates.get(w.id);if(memory!=null&&memory.active&&memory.reviews>0&&memory.due<=recallNow){
                gap(panel,12);TextView recall=button("Selected word · Review meaning",()->review(w.id));panel.addView(recall);break;
            }}
        }
        LinearLayout pager=row(this);
        TextView previous=button("← Previous",()->{if(readerStart>1)open(readerSurah,Math.max(1,readerStart-8));else if(readerSurah>1)open(readerSurah-1,Math.max(1,content.surah(readerSurah-1).count-7));});
        pager.addView(previous,new LinearLayout.LayoutParams(0,-2,1));
        TextView counter=text(this,readerStart+"–"+Math.min(s.count,readerStart+7)+" / "+s.count,12,MUTED);counter.setGravity(Gravity.CENTER);pager.addView(counter,new LinearLayout.LayoutParams(0,-2,1));
        TextView next=button("Next →",()->{if(readerStart+8<=s.count)open(readerSurah,readerStart+8);else if(readerSurah<114)open(readerSurah+1,1);});pager.addView(next,new LinearLayout.LayoutParams(0,-2,1));page.addView(pager);gap(page,12);
        page.addView(button("Recall Companion · Timer",this::ambientSettings));gap(page,12);
        TextView source=text(this,"Tanzil Project · Uthmani 1.1",11,MUTED);source.setGravity(Gravity.CENTER);source.setOnClickListener(v->sources());page.addView(source);gap(page,12);
        if(quietReader){header.setVisibility(View.GONE);bottom.setVisibility(View.GONE);page.addView(button("Show controls",()->{quietReader=false;show();}));}
        restoreReaderPosition();
    }

    private void refreshRecitation(){if(recitationBanner==null||isDestroyed())return;recitationBanner.setText(app.recitationLabel+" · Controls");recitationBanner.setVisibility(app.recitationActive?View.VISIBLE:View.GONE);}
    private void playAyah(Ayah a){
        if(a==null)return;
        if(translationSpeech!=null)translationSpeech.stop();
        android.content.SharedPreferences preferences=getSharedPreferences("recitation",0);
        String reciter=RecitationDownloads.valid(preferences.getString("reciter",RecitationDownloads.IDS[0]));
        boolean reciterOffline=app.recitationDownloads!=null&&app.recitationDownloads.ready(reciter,a.surah,content.surah(a.surah).count);
        List<ContentStore.Word> words=content.words(a.id);

        // The large "Quran audio" download is the verified isolated-word pack. If it is present,
        // the ayah play button must actually work offline instead of failing on a remote reciter.
        if(!reciterOffline&&app.audio!=null&&app.audio.canPlay(words)){
            stopService(new Intent(this,RecitationService.class));
            if(app.audio.playSequence(words)){toast("Playing downloaded word audio");return;}
        }

        if(!preferences.getBoolean("chosen",false)){audioControls(a);return;}
        if(app.audio!=null)app.audio.stop();
        RecitationService.command(this,RecitationService.PLAY,a.surah,a.number);
    }
    private void audioControls(Ayah a){
        if(a==null)return;LinearLayout page=sheet("Recitation & audio");Dialog dialog=activeDialog;
        android.content.SharedPreferences preferences=getSharedPreferences("recitation",0);String selected=preferences.getString("reciter",RecitationDownloads.IDS[0]);
        caption(page,"Choose a reciter. Play continues from this ayah; your choice is remembered.");gap(page,12);
        for(int i=0;i<RecitationDownloads.IDS.length;i++){String id=RecitationDownloads.IDS[i];page.addView(button((id.equals(selected)?"✓ ":"")+RecitationDownloads.NAMES[i],()->{preferences.edit().putString("reciter",id).putBoolean("chosen",true).apply();audioControls(a);}));gap(page,8);}
        Switch mode=new Switch(this);mode.setText("Continue to the end of this Surah");mode.setTextColor(INK);mode.setMinHeight(dp(this,48));mode.setChecked(preferences.getBoolean("continuous",true));mode.setOnCheckedChangeListener((b,v)->preferences.edit().putBoolean("continuous",v).apply());page.addView(mode);
        LinearLayout repeats=row(this);for(int n:new int[]{1,3,5})repeats.addView(button("Repeat "+n+(preferences.getInt("repeat",1)==n?" ✓":""),()->{preferences.edit().putInt("repeat",n).apply();audioControls(a);}));page.addView(repeats);gap(page,12);
        page.addView(primary("Play from "+a.surah+":"+a.number,()->{preferences.edit().putBoolean("chosen",true).apply();dialog.dismiss();playAyah(a);}));gap(page,8);
        if(app.recitationActive){LinearLayout transport=row(this);transport.addView(iconButton("back","Previous ayah",()->RecitationService.command(this,RecitationService.PREVIOUS,a.surah,a.number)));transport.addView(button("Play / Pause",()->RecitationService.command(this,RecitationService.PAUSE,a.surah,a.number)));transport.addView(iconButton("next","Next ayah",()->RecitationService.command(this,RecitationService.NEXT,a.surah,a.number)));page.addView(transport);page.addView(button("Stop playback",()->stopService(new Intent(this,RecitationService.class))));}
        gap(page,12);recitationDownloadStatus=text(this,app.recitationDownloads.progress,13,MUTED);page.addView(recitationDownloadStatus);
        boolean offline=app.recitationDownloads.ready(selected,a.surah,content.surah(a.surah).count);
        caption(page,offline?"✓ This Surah is downloaded for the selected reciter":"Play needs internet for ayahs not yet downloaded. Saved ayahs play offline.");

        LinearLayout surahDownloads=column(this);
        final TextView[] currentDownload={null};
        currentDownload[0]=button(offline?"Downloaded ✓":"Download this Surah",()->{
            if(app.recitationDownloads.ready(selected,a.surah,content.surah(a.surah).count)){toast(content.surah(a.surah).name+" is already downloaded");return;}
            downloadRecitation(selected,a.surah,a.surah,()->{
                if(currentDownload[0]!=null)currentDownload[0].setText("Downloaded ✓");
                if(surahDownloads.isAttachedToWindow())fillRecitationSurahDownloads(surahDownloads,selected);
            });
        });
        page.addView(currentDownload[0]);gap(page,8);

        page.addView(button("Download all Surahs · "+RecitationDownloads.NAMES[RecitationDownloads.index(selected)],()->{
            new AlertDialog.Builder(this).setTitle("Download this reciter?").setMessage("All 114 Surahs will use significant data and storage. Completed ayahs are kept if you pause or reconnect.").setNegativeButton("Cancel",null).setPositiveButton("Download",(d,w)->downloadRecitation(selected,1,114,()->{
                if(currentDownload[0]!=null&&app.recitationDownloads.ready(selected,a.surah,content.surah(a.surah).count))currentDownload[0].setText("Downloaded ✓");
                if(surahDownloads.isAttachedToWindow())fillRecitationSurahDownloads(surahDownloads,selected);
            })).show();}));gap(page,12);

        page.addView(label("SURAHS"));gap(page,6);
        page.addView(surahDownloads);
        fillRecitationSurahDownloads(surahDownloads,selected);

        if(app.recitationDownloads.busy){gap(page,8);caption(page,app.recitationDownloads.progress);page.addView(button("Pause downloads",()->app.recitationDownloads.cancelled=true));}
        gap(page,12);caption(page,RecitationDownloads.ATTRIBUTION);
        page.addView(button("Word audio · This Surah",()->audioSurahPrompt(a.surah)));gap(page,8);
        page.addView(button("Word audio · Download All",this::downloadAllAudio));
    }
    private void fillRecitationSurahDownloads(LinearLayout list,String reciter){
        list.removeAllViews();
        for(int s=1;s<=114;s++){
            final int surah=s;ContentStore.Surah info=content.surah(surah);
            boolean downloaded=app.recitationDownloads.markedComplete(reciter,surah,info.count);

            LinearLayout item=row(this);pad(item,12,8);item.setMinimumHeight(dp(this,46));
            item.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));

            TextView number=text(this,String.format(Locale.ROOT,"%03d",surah),11,MUTED);
            item.addView(number,new LinearLayout.LayoutParams(dp(this,42),-2));

            TextView name=text(this,info.name,15,INK);
            name.setSingleLine(true);name.setEllipsize(android.text.TextUtils.TruncateAt.END);
            item.addView(name,new LinearLayout.LayoutParams(0,-2,1));

            Glass.Icon status=new Glass.Icon(this,downloaded?"check":"download");
            status.color=appearance.buttonInk();
            item.addView(status,new LinearLayout.LayoutParams(dp(this,22),dp(this,22)));

            item.setFocusable(true);item.setClickable(true);
            item.setContentDescription(info.name+(downloaded?", downloaded":", download"));
            item.setOnClickListener(v->{
                if(app.recitationDownloads.ready(reciter,surah,info.count)){toast(info.name+" is already downloaded");return;}
                downloadRecitation(reciter,surah,surah,()->{
                    if(list.isAttachedToWindow())fillRecitationSurahDownloads(list,reciter);
                });
            });
            Glass.motion(item);

            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(this,5);list.addView(item,lp);
        }
    }
    private void downloadRecitation(String reciter,int first,int last){downloadRecitation(reciter,first,last,null);}
    private void downloadRecitation(String reciter,int first,int last,Runnable finished){
        if(recitationDownloadQueued||app.recitationDownloads.busy){toast("A download is already running");return;}
        recitationDownloadQueued=true;
        toast("Download started. Keep Aaris open for this download.");
        app.audioWorker.execute(()->{
            try{
                app.recitationDownloads.download(content,reciter,first,last,()->ui.post(()->{
                    if(recitationDownloadStatus!=null&&!isDestroyed())recitationDownloadStatus.setText(app.recitationDownloads.progress);
                }));
                ui.post(()->{
                    if(isDestroyed()||isFinishing())return;
                    toast(app.recitationDownloads.progress);
                    if(finished!=null)finished.run();
                });
            }catch(Exception e){
                ui.post(()->{
                    if(isDestroyed()||isFinishing())return;
                    toast("Download paused. Completed ayahs are safe; tap Download to continue.");
                    if(finished!=null)finished.run();
                });
            }finally{
                ui.post(()->recitationDownloadQueued=false);
            }
        });
    }
    private void addTranslation(LinearLayout panel,Ayah ayah){
        if(app.translations==null){gap(panel,10);caption(panel,"Translation pack unavailable on this installation.");return;}
        TranslationStore.Entry entry=app.translations.get(translationId,ayah.id);if(entry==null){caption(panel,"The selected translation is not installed. Choose another in Translation settings.");return;}
        gap(panel,14);TextView translated=text(this,entry.text,appearance.translationSize,appearance.translationInk());
        translated.setTextDirection("ur".equals(entry.edition.language)?View.TEXT_DIRECTION_RTL:View.TEXT_DIRECTION_FIRST_STRONG);
        translated.setGravity("ur".equals(entry.edition.language)?Gravity.RIGHT:Gravity.LEFT);translated.setTextIsSelectable(true);panel.addView(translated);gap(panel,8);
        TextView attribution=text(this,entry.edition.attribution(),11,MUTED);panel.addView(attribution);
        if(!entry.footnotes.isEmpty())panel.addView(button("Translation notes",()->{LinearLayout p=sheet("Translation notes");caption(p,entry.edition.attribution());TextView notes=text(this,entry.footnotes,17,INK);notes.setTextIsSelectable(true);notes.setTextDirection(View.TEXT_DIRECTION_FIRST_STRONG);p.addView(notes);}));
    }
    private void translationSettings(){
        LinearLayout page=sheet("Translation");Dialog dialog=activeDialog;dialog.setOnDismissListener(d->{if(activeDialog==dialog){activeDialog=null;show();}});
        caption(page,"A full translation below every ayah. Tap Arabic words for their separate word meanings.");gap(page,12);
        if(app.translations==null){caption(page,"The translation pack could not be opened. Arabic reading is available.");return;}
        for(TranslationStore.Edition e:app.translations.editions){page.addView(button((translationId.equals(e.id)?"✓ ":"")+e.title,()->{translationId=e.id;learning.set("translation_edition",e.id);dialog.dismiss();}));gap(page,8);caption(page,e.description+" · v"+e.version);}
        gap(page,14);caption(page,"Translation speech uses installed device voices. It is not the translator's recorded voice.");
        page.addView(button("Choose device voice · Hear sample",()->{stopService(new Intent(this,RecitationService.class));translationSpeech.chooseVoice(this,app.translations.get(translationId,"Q:1:1"));}));
        gap(page,14);caption(page,"Reading script: original. Hindi uses देवनागरी, Urdu uses اردو, English uses Roman letters. A reviewed Urdu-to-Devanagari edition is not installed.");
    }
    private void captureReaderPosition(){
        if(readerScroll==null||readerScroll==restoringReader||!readerScroll.isAttachedToWindow()||readerVerses.isEmpty())return;
        if(readerScroll.getScrollY()==0){readingPosition=new ReadingPosition(renderedPage,renderedPage,0,0,true);return;}
        int[] viewport=new int[2];readerScroll.getLocationInWindow(viewport);
        Map.Entry<String,QuranText> anchor=null;int[] location=new int[2];
        for(Map.Entry<String,QuranText> entry:readerVerses.entrySet()){
            anchor=entry;entry.getValue().getLocationInWindow(location);
            if(location[1]+entry.getValue().getHeight()>viewport[1])break;
        }
        if(anchor==null)return;QuranText view=anchor.getValue();android.text.Layout textLayout=view.getLayout();if(textLayout==null)return;
        view.getLocationInWindow(location);int origin=location[1]+view.getTotalPaddingTop();
        int line=textLayout.getLineForVertical(Math.max(0,viewport[1]-origin));
        int cp=Character.codePointCount(view.getText(),0,textLayout.getLineStart(line));
        float offset=(origin+textLayout.getLineTop(line)-viewport[1])/getResources().getDisplayMetrics().density;
        readingPosition=new ReadingPosition(renderedPage,anchor.getKey(),cp,Math.max(-10000,Math.min(10000,offset)),false);
    }
    private void restoreReaderPosition(){
        ReadingPosition position=readingPosition;ScrollView scroll=readerScroll;
        if(position==null||!position.pageId.equals(renderedPage))return;
        restoringReader=scroll;
        // Wait for actual text layout. A posted Runnable can run before the first traversal.
        scroll.getViewTreeObserver().addOnPreDrawListener(new ViewTreeObserver.OnPreDrawListener(){
            @Override public boolean onPreDraw(){
                if(scroll.getViewTreeObserver().isAlive())scroll.getViewTreeObserver().removeOnPreDrawListener(this);
                if(readerScroll!=scroll)return true;
                try{
                    if(position.atTop){scroll.scrollTo(0,0);return true;}
                    QuranText view=readerVerses.get(position.anchorId);if(view==null||view.getLayout()==null)return true;
                    String value=view.getText().toString();int cp=Math.min(position.codePoint,value.codePointCount(0,value.length()));
                    int line=view.getLayout().getLineForOffset(value.offsetByCodePoints(0,cp));int[] v=new int[2],s=new int[2];view.getLocationInWindow(v);scroll.getLocationInWindow(s);
                    int y=scroll.getScrollY()+v[1]-s[1]+view.getTotalPaddingTop()+view.getLayout().getLineTop(line)-Math.round(position.lineOffsetDp*getResources().getDisplayMetrics().density);
                    scroll.scrollTo(0,Math.max(0,y));return true;
                }finally{if(restoringReader==scroll)restoringReader=null;}
            }
        });
    }
    private void hidePeek(){
        if(selectedWordId.isEmpty()&&selectedVerse==null&&(overlay==null||overlay.getChildCount()==0))return;
        selectedWordId="";
        if(selectedVerse!=null){selectedVerse.select(null);selectedVerse=null;}
        if(overlay!=null&&overlay.getChildCount()>0)overlay.removeAllViews();
    }
    private void tapWord(ContentStore.Word word,QuranText owner){
        if(word.id.equals(selectedWordId)){
            playWordAudio(word,false);wordDetails(word);return;
        }
        hidePeek();playWordAudio(word,false);selectedWordId=word.id;selectedVerse=owner;owner.select(word);learning.event(word.id,Recall.Kind.PEEK,word.ayahId);
        LinearLayout peek=column(this);pad(peek,20,16);peek.setBackground(new Surface(this,Surface.Kind.SHEET,true));
        LinearLayout top=row(this);TextView ar=arabic(word.arabic,30);ar.setGravity(Gravity.RIGHT);top.addView(ar,new LinearLayout.LayoutParams(0,-2,1));
        if(app.audio!=null&&app.audio.canPlay(word))top.addView(iconButton("speaker","Replay pronunciation",()->playWordAudio(word,true)));
        else if(app.audioDownloads!=null){TextView getAudio=button("Audio ↓",()->{int[] q=wordCoordinate(word);if(q!=null)audioSurahPrompt(q[0]);});top.addView(getAudio,new LinearLayout.LayoutParams(-2,-2));}
        top.addView(iconButton("close","Close meaning",this::hidePeek));peek.addView(top);
        TextView meaning=text(this,word.gloss(language),18,INK);if(language.equals("ur"))meaning.setTextDirection(View.TEXT_DIRECTION_RTL);peek.addView(meaning);
        if(word.transliteration!=null){gap(peek,4);caption(peek,word.transliteration);}
        gap(peek,10);LinearLayout actions=row(this);actions.addView(button("Understand More",()->wordDetails(word)),new LinearLayout.LayoutParams(0,-2,1));
        if(word.hasGloss(language)){TextView remember=button("Remember This",()->enroll(word.id,word.ayahId));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.leftMargin=dp(this,8);actions.addView(remember,p);}peek.addView(actions);
        TextView source=text(this,"Source word meaning · "+word.ayahId.replace("Q:",""),10,MUTED);peek.addView(source);
        Rect line=owner.wordLines(word);int[] viewport=new int[2],surface=new int[2];
        if(line==null||readerScroll==null){wordDetails(word);return;}
        readerScroll.getLocationInWindow(viewport);overlay.getLocationInWindow(surface);
        int viewportTop=Math.max(0,viewport[1]-surface[1]),viewportBottom=Math.min(overlay.getHeight(),viewportTop+readerScroll.getHeight()),space=dp(this,8);
        int above=Math.max(0,line.top-surface[1]-viewportTop-space),below=Math.max(0,viewportBottom-(line.bottom-surface[1])-space);
        boolean useBottom=below>=above;int available=useBottom?below:above;
        if(available<dp(this,100)){wordDetails(word);return;}
        ScrollView ribbon=new ScrollView(this);ribbon.setFillViewport(false);ribbon.addView(peek);
        int width=Math.max(1,overlay.getWidth()-dp(this,28));ribbon.measure(View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(available,View.MeasureSpec.AT_MOST));
        int height=Math.min(available,ribbon.getMeasuredHeight());
        FrameLayout.LayoutParams params=new FrameLayout.LayoutParams(width,height,Gravity.TOP|Gravity.LEFT);
        params.leftMargin=dp(this,14);params.topMargin=useBottom?viewportBottom-height:viewportTop;overlay.addView(ribbon,params);
        peek.announceForAccessibility(word.gloss(language));
    }
    private void playWordAudio(ContentStore.Word word,boolean explicit){
        if(explicit&&app.recitationActive)stopService(new Intent(this,RecitationService.class));
        if(app.audio!=null&&app.audio.play(word))return;
        if(explicit)toast(app.wordAudioLoadError==null?"Download this Surah's audio first":app.wordAudioLoadError);
    }

    private int[] wordCoordinate(ContentStore.Word word){
        if(word==null||word.ayahId==null)return null;
        try{
            String[] p=word.ayahId.split(":");
            if(p.length!=3||!"Q".equals(p[0]))return null;
            return new int[]{Integer.parseInt(p[1]),Integer.parseInt(p[2])};
        }catch(RuntimeException invalid){return null;}
    }

    private void audioSurahPrompt(int surah){
        if(app.wordAudio==null||app.audioDownloads==null){toast(app.wordAudioLoadError==null?"Audio storage is not ready yet":app.wordAudioLoadError);return;}
        ContentStore.Surah s=content.surah(surah);
        if(app.wordAudio.installedSurah(surah)){
            new AlertDialog.Builder(this)
                .setTitle(s.name+" audio")
                .setMessage("Word-by-word pronunciation for this Surah is installed and ready offline.")
                .setPositiveButton("OK",null).show();
            return;
        }
        QuranAudioStore.PackMeta meta=app.wordAudio.meta(surah);
        String packSize=meta==null?"":String.format(Locale.ROOT," · %.1f MB",meta.bytes/(1024d*1024d));
        new AlertDialog.Builder(this)
            .setTitle(s.name+" audio download?")
            .setMessage("Word-by-word pronunciation for this Surah will be downloaded"+packSize+". Playback stays local after the download.")
            .setNegativeButton("Not now",null)
            .setPositiveButton("Download",(d,w)->startSurahAudioDownload(surah))
            .show();
    }

    private void startSurahAudioDownload(int surah){
        if(app.audioDownloads==null)return;
        toast(content.surah(surah).name+" audio download started…");
        app.audioDownloads.downloadSurah(surah,new QuranAudioDownloadManager.Listener(){
            public void onProgress(int current,int completed,int total){}
            public void onComplete(){
                if(isDestroyed()||isFinishing())return;
                toast(content.surah(surah).name+" audio saved offline ✓");
                if(tab==1&&reading&&readerSurah==surah)show();
            }
            public void onError(int failed,String message){if(!isDestroyed()&&!isFinishing())toast("Audio download failed: "+message);}
        });
    }

    private void downloadAllAudio(){
        if(app.wordAudio==null||app.audioDownloads==null){toast("Audio downloads are not available yet");return;}
        int installed=app.wordAudio.installedCount();
        if(installed>=114){toast("All Quran audio is already installed offline ✓");return;}
        double remainingMb=app.wordAudio.remainingBytes()/(1024d*1024d);
        new AlertDialog.Builder(this)
            .setTitle("Download all Quran audio?")
            .setMessage(String.format(Locale.ROOT,"Downloads word-by-word pronunciation for all 114 Surahs. About %.0f MB remains. Audio stays in private app storage. Wi‑Fi recommended.",remainingMb))
            .setNegativeButton("Not now",null)
            .setPositiveButton("Download All",(d,w)->{
                toast("Download All started… "+installed+"/114 already offline");
                final int[] lastToast={installed};
                app.audioDownloads.downloadAll(new QuranAudioDownloadManager.Listener(){
                    public void onProgress(int surah,int completed,int total){
                        if(completed==total||completed-lastToast[0]>=10){lastToast[0]=completed;toast("Quran audio "+completed+"/"+total+" locally saved");}
                    }
                    public void onComplete(){if(!isDestroyed()&&!isFinishing()){toast("All Quran audio installed offline ✓");if(tab==1&&reading)show();}}
                    public void onError(int surah,String message){if(!isDestroyed()&&!isFinishing())toast("Download paused · Surah "+surah+": "+message);}
                });
            }).show();
    }

    private LinearLayout sheet(String title){
        hidePeek();
        Dialog previous=activeDialog;activeDialog=null;if(previous!=null)previous.dismiss();
        Dialog dialog=new Dialog(this);activeDialog=dialog;dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout outer=column(this);pad(outer,22,18);outer.setBackground(new Surface(this,Surface.Kind.SHEET,true));
        outer.setOnApplyWindowInsetsListener((view,insets)->{
            int left=0,right=0,bottom=0;
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets safe=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());left=safe.left;right=safe.right;bottom=safe.bottom;}
            else{left=insets.getSystemWindowInsetLeft();right=insets.getSystemWindowInsetRight();bottom=insets.getSystemWindowInsetBottom();}
            view.setPadding(dp(this,22)+left,dp(this,18),dp(this,22)+right,dp(this,18)+bottom);return insets;
        });
        LinearLayout bar=row(this);TextView heading=text(this,title,22,INK);bar.addView(heading,new LinearLayout.LayoutParams(0,-2,1));bar.addView(iconButton("close","Close",dialog::dismiss));outer.addView(bar);gap(outer,12);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(false);LinearLayout inside=column(this);scroll.addView(inside);outer.addView(scroll,new LinearLayout.LayoutParams(-1,-2));
        dialog.setContentView(outer);Window w=dialog.getWindow();if(w!=null){w.setBackgroundDrawableResource(android.R.color.transparent);w.setDimAmount(.4f);w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);w.setGravity(Gravity.BOTTOM);w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);}
        dialog.show();if(w!=null){w.setLayout(-1,-2);int max=(int)(getResources().getDisplayMetrics().heightPixels*.82);outer.post(()->{if(outer.getHeight()>max)w.setLayout(-1,max);});}
        return inside;
    }
    private void wordDetails(ContentStore.Word word){
        learning.event(word.id,Recall.Kind.DEEP,word.ayahId);hidePeek();
        LinearLayout page=sheet("Word meaning");page.addView(arabic(word.arabic,40));gap(page,10);
        page.addView(text(this,word.gloss(language),22,INK));if(word.transliteration!=null)caption(page,word.transliteration);
        gap(page,16);caption(page,"Source meaning for this word in this ayah. Other contexts may differ.");
        gap(page,16);caption(page,"Quran "+word.ayahId.replace("Q:","")+" · Word "+word.position+"\nSource: Data Quran / Quran.com");
        if(word.hasGloss(language)) {
            gap(page,16);page.addView(button("Add word to Recall",()->enroll(word.id,word.ayahId)));
            int count=content.occurrences(word.surface);gap(page,16);page.addView(label("OTHER CONTEXTS"));caption(page,"Found in "+count+" places. Recall progress stays separate for each context.");
            for(ContentStore.Word other:content.related(word)) {
                gap(page,8);page.addView(button("Open "+other.ayahId.replace("Q:",""),()->{if(activeDialog!=null)activeDialog.dismiss();Ayah a=content.ayah(other.ayahId);open(a.surah,a.number);}));
            }
        }
        gap(page,16);page.addView(button("My note",()->editNote(word.id)));gap(page,12);
    }
    private void enroll(String target,String context){
        Recall.State existing=learning.states().get(target);
        if(existing==null||!existing.active)learning.event(target,Recall.Kind.ENROLL,context);
        toast("Saved to Recall");
    }
    private void ayahActions(Ayah a){
        LinearLayout page=sheet(content.surah(a.surah).name+" · "+a.number);
        page.addView(primary("Study ayah · Translations & compare",()->studyAyah(a)));gap(page,10);
        page.addView(button("Play · Reciter & audio",()->audioControls(a)));gap(page,10);
        page.addView(button("Copy ayah",()->{((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText(a.id,a.arabic+"\n["+a.id+"]"));toast("Ayah copied");}));gap(page,10);
        if(app.translations!=null)page.addView(button("Listen to translation · Device voice",()->{stopService(new Intent(this,RecitationService.class));if(app.audio!=null)app.audio.stop();translationSpeech.speak(app.translations.get(translationId,a.id));}));gap(page,10);
        page.addView(button(learning.bookmarked(a.id)?"Remove bookmark":"Bookmark",()->{learning.toggleBookmark(a.id);toast(learning.bookmarked(a.id)?"Bookmark saved":"Bookmark removed");activeDialog.dismiss();}));gap(page,10);
        page.addView(button("Add ayah to Recall",()->{enroll(a.id,a.id);activeDialog.dismiss();}));gap(page,10);
        page.addView(button("Add passage to Recall",()->choosePhrase(a)));gap(page,10);
        if(a.number<content.surah(a.surah).count){page.addView(button("Practice next-ayah transition",()->review(RecallTarget.transition(a.id,a.number+1))));gap(page,10);}
        page.addView(button("Word meanings",()->wordList(a)));gap(page,10);
        page.addView(button("My note",()->editNote(a.id)));gap(page,10);
        page.addView(button("Add to evidence",()->{if(selectedEvidence.size()>=50&&!selectedEvidence.contains(a.id)){toast("Select up to 50 ayahs per bundle");return;}selectedEvidence.add(a.id);selectionTrace.put(a.id,selectionOrigin("READER_SELECTION"));toast("Evidence selection: "+selectedEvidence.size());activeDialog.dismiss();}));gap(page,10);
        page.addView(button("Share ayah",()->shareText(a.arabic+"\n["+a.id+"]\nTanzil Project · https://tanzil.net/")));gap(page,10);
        page.addView(button("Continue from this ayah",()->{activeDialog.dismiss();open(a.surah,a.number);}));
    }
    private void voiceSearch(boolean hadith){
        if(pendingVoiceScope>=0){toast("Voice search is already open");return;}
        String[] labels={"Arabic","Hindi","Urdu","English"},languages={"ar","hi-IN","ur","en"};
        new AlertDialog.Builder(this).setTitle("Voice search language").setItems(labels,(dialog,which)->{
            new AlertDialog.Builder(this).setTitle("Use your phone's speech service?")
                .setMessage("Your chosen Android speech provider may use internet. You can edit the recognized text before refining your search. This does not assess recitation or Tajweed.")
                .setNegativeButton("Cancel",null).setPositiveButton("Start",(d,w)->{
                    pendingVoiceScope=hadith?1:0;
                    Intent intent=new Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                        .putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        .putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE,languages[which])
                        .putExtra(android.speech.RecognizerIntent.EXTRA_PREFER_OFFLINE,true)
                        .putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS,1)
                        .putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT,"Speak a search phrase");
                    try{startActivityForResult(intent,VOICE_SEARCH);}catch(ActivityNotFoundException|SecurityException e){pendingVoiceScope=-1;toast("No speech service is available. Typed search still works.");}
                }).show();
        }).show();
    }
    private void rememberSearch(boolean hadith,String query,String id){
        if(TextMatch.normalize(query).length()>256){toast("Use up to 256 characters for a saved shortcut");return;}
        new AlertDialog.Builder(this).setTitle("Remember this search match?")
            .setMessage("Save this exact query as your private shortcut to "+id+"? This does not verify the wording or change source text.")
            .setNegativeButton("Cancel",null).setPositiveButton("Remember",(d,w)->{
                try{learning.confirmSearch(hadith?"hadith":"quran",hadith?app.hadith.packHash:content.packHash,query,id);toast("Shortcut saved locally");}
                catch(IllegalArgumentException|IllegalStateException e){toast("This shortcut could not be saved");}
            }).show();
    }
    private void showSearchShortcut(LinearLayout list,boolean hadith,String query){
        String id=learning.confirmedSearch(hadith?"hadith":"quran",hadith?app.hadith.packHash:content.packHash,query);
        if(id.isEmpty())return;
        if(hadith&&app.hadith.record(id)==null||!hadith&&content.ayah(id)==null)return;
        LinearLayout saved=card(list,Surface.Kind.PANEL);saved.addView(label("YOUR CONFIRMED SHORTCUT"));
        caption(saved,"Previously chosen by you · separate from text-match ranking");
        saved.addView(button("Open "+id,()->{if(hadith)hadithRecord(id);else{Ayah a=content.ayah(id);open(a.surah,a.number);}}));
    }
    private static String languageName(String language){return "hi".equals(language)?"Hindi":"ur".equals(language)?"Urdu":"en".equals(language)?"English":language;}
    private String readingLanguage(){
        TranslationStore.Edition edition=app.translations==null?null:app.translations.edition(translationId);
        return edition==null?language:edition.language;
    }
    private void studyAyah(Ayah a){
        LinearLayout page=sheet("Study · "+a.surah+":"+a.number);
        QuranText original=new QuranText(this,arabicFont,a,content.words(a.id),arabicSize,(word,owner)->wordDetails(word));
        page.addView(original);addTranslation(page,a);gap(page,12);
        page.addView(button("Compare available translations",()->compareTranslations(a)));gap(page,8);
        page.addView(button(learning.pinnedAyahs().contains(a.id)?"Unpin from compare":"Pin for compare",()->{
            if(!learning.togglePin(a.id))toast("Compare up to 10 pinned ayahs");else studyAyah(a);
        }));gap(page,8);
        page.addView(button("Add to collection",()->collectionPicker(a)));gap(page,8);
        page.addView(button("Word-by-word meanings",()->wordList(a)));gap(page,8);
        page.addView(button("My note",()->editNote(a.id)));gap(page,8);
        page.addView(button("Hide · Recall · Reveal",()->review(a.id)));gap(page,8);
        page.addView(button("Copy Arabic + translation",()->{
            TranslationStore.Entry entry=app.translations==null?null:app.translations.get(translationId,a.id);
            String evidence=a.arabic+"\n["+a.id+"]\nTanzil Project · https://tanzil.net/";
            if(entry!=null)evidence+="\n\n"+entry.text+(entry.footnotes.isEmpty()?"":"\n"+entry.footnotes)+"\n"+entry.edition.attribution();
            ((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText(a.id,evidence));toast("Attributed text copied");
        }));gap(page,8);
        page.addView(button("Add to research PDF",()->{
            if(selectedEvidence.size()>=50&&!selectedEvidence.contains(a.id)){toast("Select up to 50 ayahs");return;}
            selectedEvidence.add(a.id);selectionTrace.put(a.id,selectionOrigin("STUDY_SELECTION"));shareResearch(false);
        }));gap(page,8);
        if(app.translations!=null)page.addView(button("Report translation issue · Local draft",()->translationIssue(a)));
    }
    private void compareTranslations(Ayah a){
        LinearLayout page=sheet("Compare translations · "+a.surah+":"+a.number);page.addView(arabic(a.arabic,28));
        if(app.translations==null){caption(page,"No translation pack is installed.");return;}
        for(TranslationStore.Edition edition:app.translations.editions){
            TranslationStore.Entry entry=app.translations.get(edition.id,a.id);if(entry==null)continue;
            LinearLayout c=card(page,Surface.Kind.PANEL);c.addView(label(languageName(edition.language)));
            TextView text=text(this,entry.text,appearance.translationSize,appearance.translationInk());text.setTextIsSelectable(true);text.setTextDirection(View.TEXT_DIRECTION_FIRST_STRONG);c.addView(text);
            caption(c,edition.attribution());if(!entry.footnotes.isEmpty())caption(c,entry.footnotes);
        }
    }
    private void studyLibrary(){
        LinearLayout page=sheet("Study library");page.addView(button("Compare pinned ayahs · "+learning.pinnedAyahs().size(),this::comparePinned));gap(page,12);
        page.addView(label("MY COLLECTIONS"));Map<String,List<String>> collections=learning.collections();
        if(collections.isEmpty())caption(page,"Open an ayah → Study → Add to collection.");
        for(Map.Entry<String,List<String>> collection:collections.entrySet()){
            page.addView(button(collection.getKey()+" · "+collection.getValue().size()+" ayahs",()->{
                LinearLayout list=sheet(collection.getKey());
                for(String id:collection.getValue()){Ayah a=content.ayah(id);if(a==null)continue;
                    list.addView(button(content.surah(a.surah).name+" · "+a.number,()->studyAyah(a)));
                    list.addView(button("Remove "+a.surah+":"+a.number,()->{learning.collect(collection.getKey(),id,false);studyLibrary();}));gap(list,10);
                }
            }));gap(page,8);
        }
    }
    private void collectionPicker(Ayah a){
        LinearLayout page=sheet("Add to collection");
        for(String name:learning.collections().keySet()){page.addView(button(name,()->{try{learning.collect(name,a.id,true);toast("Added to "+name);studyAyah(a);}catch(IllegalArgumentException e){toast(e.getMessage());}}));gap(page,8);}
        EditText name=new EditText(this);name.setTextColor(INK);name.setHintTextColor(MUTED);name.setHint("New collection name");name.setSingleLine(true);name.setFilters(new InputFilter[]{new InputFilter.LengthFilter(64)});page.addView(name);
        page.addView(primary("Create & add ayah",()->{try{learning.collect(name.getText().toString(),a.id,true);hideKeyboard();studyAyah(a);}catch(IllegalArgumentException e){toast(e.getMessage());}}));
    }
    private void comparePinned(){
        LinearLayout page=sheet("Compare pinned ayahs");List<String> pins=learning.pinnedAyahs();
        if(pins.isEmpty()){caption(page,"Pin an ayah from Study to keep it here across app restarts.");return;}
        for(String id:pins){Ayah a=content.ayah(id);if(a==null)continue;LinearLayout c=card(page,Surface.Kind.PANEL);c.addView(label(content.surah(a.surah).name+" · "+a.surah+":"+a.number));c.addView(arabic(a.arabic,28));addTranslation(c,a);c.addView(button("Open study",()->studyAyah(a)));}
        page.addView(button("Clear pins",()->{learning.set("study_pins_v1","[]");comparePinned();}));
    }
    private void translationIssue(Ayah a){
        TranslationStore.Entry entry=app.translations.get(translationId,a.id);if(entry==null)return;
        LinearLayout page=sheet("Translation issue · "+a.surah+":"+a.number);caption(page,entry.edition.attribution());
        caption(page,"Private feedback draft. Saving does not edit the translation or send a message.");
        EditText note=new EditText(this);note.setTextColor(INK);note.setMinLines(3);note.setMaxLines(6);note.setFilters(new InputFilter[]{new InputFilter.LengthFilter(2000)});page.addView(note);
        page.addView(primary("Save local draft",()->{
            try{learning.translationIssue(a.id,entry.edition.id,entry.edition.version,app.translations.packHash,note.getText().toString());hideKeyboard();translationDrafts();}
            catch(IllegalArgumentException e){toast(e.getMessage());}
        }));
    }
    private void translationDrafts(){
        LinearLayout page=sheet("Translation issue drafts");
        try{JSONArray drafts=new JSONArray(learning.get("translation_issues_v1","[]"));if(drafts.length()==0)caption(page,"No local drafts.");
            for(int i=drafts.length()-1;i>=0;i--){JSONObject item=drafts.getJSONObject(i);String text="Translation feedback draft\n"+item.getString("ayah")+" · "+item.getString("edition")+" · v"+item.getString("version")+"\nPack: "+item.getString("pack")+"\n\n"+item.getString("text");
                LinearLayout c=card(page,Surface.Kind.PANEL);caption(c,text);c.addView(button("Share this draft",()->shareText(text)));
            }
        }catch(JSONException e){caption(page,"Drafts could not be read.");}
    }
    private void wordList(Ayah a){
        LinearLayout page=sheet("Word by word · "+a.surah+":"+a.number);
        caption(page,"Source word meanings only; this is not a full translation or tafsir.");gap(page,12);
        for(ContentStore.Word word:content.words(a.id)) {
            LinearLayout row=Glass.row(this);pad(row,4,10);TextView ar=arabic(word.arabic,28);row.addView(ar,new LinearLayout.LayoutParams(0,-2,1));TextView gloss=text(this,word.gloss(language),16,INK);row.addView(gloss,new LinearLayout.LayoutParams(0,-2,1));row.setFocusable(true);row.setOnClickListener(v->wordDetails(word));Glass.motion(row);page.addView(row);
        }
    }
    private void editNote(String target){
        LinearLayout page=sheet("My note");caption(page,"Private note. It does not change the Quran source text.");
        EditText edit=new EditText(this);edit.setTextColor(INK);edit.setHintTextColor(MUTED);edit.setHint("Write a note or question…");edit.setText(learning.note(target));edit.setMinLines(4);edit.setMaxLines(8);edit.setFilters(new InputFilter[]{new InputFilter.LengthFilter(8000)});page.addView(edit);gap(page,12);
        page.addView(button("Save note",()->{learning.note(target,edit.getText().toString());hideKeyboard();activeDialog.dismiss();toast("Note saved");}));
    }
    private void bookmarks(){
        LinearLayout page=sheet("Bookmarks");List<String> ids=learning.bookmarks();
        if(ids.isEmpty())caption(page,"Use an ayah menu to add bookmarks.");
        for(String id:ids){Ayah a=content.ayah(id);if(a==null)continue;page.addView(button(content.surah(a.surah).name+" · "+a.number,()->{activeDialog.dismiss();open(a.surah,a.number);}));gap(page,10);}
    }
    private void map(){
        heading("LEARN · REVIEW · REMEMBER","Recall");LinearLayout page=scrollBody();Map<String,Recall.State> states=learning.states();
        int active=0;for(Recall.State state:states.values())if(state.active)active++;
        final int savedCount=active;List<Recall.State> due=dueQueue();final int dueCount=due.size();

        LinearLayout actions=row(this);
        LinearLayout.LayoutParams actionLp=new LinearLayout.LayoutParams(0,-2,1);actionLp.rightMargin=dp(this,7);
        actions.addView(quickAction("clock","Timer",app.ambientRunning?AmbientSettings.minutes(this)+" min":"Off",this::ambientSettings),actionLp);
        LinearLayout.LayoutParams addLp=new LinearLayout.LayoutParams(0,-2,1);addLp.rightMargin=dp(this,7);
        actions.addView(quickAction("plus","Add","Word / ayah",this::chooseAmbientItems),addLp);
        actions.addView(quickAction("repeat","Review",dueCount+" due",()->{
            List<Recall.State> queue=dueQueue();
            if(!queue.isEmpty())review(queue.get(0).target);
            else toast(savedCount==0?"Add something first":"Nothing due right now");
        }),new LinearLayout.LayoutParams(0,-2,1));
        page.addView(actions);gap(page,14);

        LinearLayout summary=card(page,Surface.Kind.HERO);LinearLayout metrics=row(this);
        LinearLayout left=column(this);TextView saved=text(this,""+savedCount,28,INK);saved.setGravity(Gravity.CENTER);left.addView(saved);TextView savedLabel=text(this,"Saved",12,MUTED);savedLabel.setGravity(Gravity.CENTER);left.addView(savedLabel);metrics.addView(left,new LinearLayout.LayoutParams(0,-2,1));
        LinearLayout right=column(this);TextView dueText=text(this,""+dueCount,28,INK);dueText.setGravity(Gravity.CENTER);right.addView(dueText);TextView dueLabel=text(this,"Due",12,MUTED);dueLabel.setGravity(Gravity.CENTER);right.addView(dueLabel);metrics.addView(right,new LinearLayout.LayoutParams(0,-2,1));
        summary.addView(metrics);

        if(savedCount==0){
            LinearLayout empty=card(page,Surface.Kind.PANEL);empty.setGravity(Gravity.CENTER);
            Glass.Icon addIcon=new Glass.Icon(this,"plus");addIcon.color=MINT;LinearLayout.LayoutParams ip=new LinearLayout.LayoutParams(dp(this,34),dp(this,34));ip.gravity=Gravity.CENTER;empty.addView(addIcon,ip);gap(empty,8);
            TextView title=text(this,"Add your first item",18,INK);title.setGravity(Gravity.CENTER);empty.addView(title);gap(empty,10);
            empty.addView(primary("Add",this::chooseAmbientItems));
        }

        for(Recall.State state:states.values())if(state.active){
            ContentStore.Word w=content.word(state.target);Ayah a=content.contextFor(state.target);if(a==null||!content.hasRecallTarget(state.target))continue;
            LinearLayout c=card(page,Surface.Kind.PANEL);AyahTransition transition=content.transition(state.target);
            c.addView(text(this,content.surah(a.surah).name+" · "+a.number+(transition==null?"":" → "+transition.to.number+" · Transition"),13,GOLD));
            c.addView(arabic(transition!=null?transition.ending.text:w==null?firstWords(content.recallText(state.target),5):w.arabic,28));
            caption(c,state.label()+" · "+dueLabel(state.due));gap(c,10);
            LinearLayout buttons=row(this);
            buttons.addView(actionChip("repeat","Review",()->review(state.target)),new LinearLayout.LayoutParams(0,-2,1));
            LinearLayout.LayoutParams pauseLp=new LinearLayout.LayoutParams(0,-2,1);pauseLp.leftMargin=dp(this,8);
            buttons.addView(actionChip("pause","Pause",()->{learning.event(state.target,Recall.Kind.PAUSE,a.id);show();}),pauseLp);c.addView(buttons);
        }
    }
    private String dueLabel(long due){long delta=due-System.currentTimeMillis(),days=delta/Recall.DAY;return due<=System.currentTimeMillis()?"Due now":delta<Recall.DAY?"Later today":days+" day"+(days==1?"":"s");}
    private String firstWords(String text,int n){String[] a=text.split("\\s+");return String.join(" ",Arrays.copyOfRange(a,0,Math.min(n,a.length)));}
    private List<Recall.State> dueQueue(){
        captureReaderPosition();
        Map<String,Recall.State> states=learning.states();
        String from=readingPosition==null?"Q:"+readerSurah+":"+readerStart:readingPosition.anchorId;
        return Recall.queue(states.values(),content.upcoming(states.values(),from),System.currentTimeMillis(),5);
    }
    private void choosePhrase(Ayah a){
        List<ContentStore.Word> words=new ArrayList<>();for(ContentStore.Word w:content.words(a.id))if(w.position>0)words.add(w);
        if(words.size()<2){toast("Add the full ayah instead");return;}
        LinearLayout page=sheet("Select a passage");caption(page,"Choose the first and last word of the passage you want to practice.");gap(page,16);
        List<String> names=new ArrayList<>();for(ContentStore.Word w:words)names.add(w.position+" · "+w.arabic);
        ArrayAdapter<String> adapter=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,names);
        page.addView(label("FIRST WORD"));Spinner first=new Spinner(this);first.setAdapter(adapter);page.addView(first);gap(page,12);
        page.addView(label("LAST WORD"));Spinner last=new Spinner(this);last.setAdapter(adapter);last.setSelection(Math.min(2,words.size()-1));page.addView(last);gap(page,18);
        TextView preview=arabic("",32);page.addView(preview);gap(page,16);
        Runnable update=()->{int from=first.getSelectedItemPosition(),to=last.getSelectedItemPosition();
            preview.setText(to>from?content.recallText(RecallTarget.phrase(a.id,words.get(from).position,words.get(to).position)):"Choose at least two consecutive words");};
        AdapterView.OnItemSelectedListener listener=new AdapterView.OnItemSelectedListener(){public void onItemSelected(AdapterView<?> p,View v,int pos,long id){update.run();}public void onNothingSelected(AdapterView<?> p){}};
        first.setOnItemSelectedListener(listener);last.setOnItemSelectedListener(listener);update.run();
        page.addView(button("Add passage to Recall",()->{
            int from=first.getSelectedItemPosition(),to=last.getSelectedItemPosition();if(to<=from){toast("Choose an end word after the first word");return;}
            String target=RecallTarget.phrase(a.id,words.get(from).position,words.get(to).position);enroll(target,a.id);review(target);
        }));caption(page,"This is a selected passage from the source ayah.");
    }
    private void review(String target){
        RecallTarget identity=RecallTarget.parse(target);if(identity==null)return;
        if(identity.kind==RecallTarget.Kind.TRANSITION){reviewTransition(content.transition(target));return;}
        ContentStore.Word word=content.word(target);Ayah a=content.contextFor(target);String source=content.recallText(target);
        if(a==null||source==null)return;if(word!=null&&!word.hasGloss(language)){toast("No source meaning is available yet");return;}
        Recall.State state=learning.states().get(target);if(state==null||!state.active){enroll(target,a.id);state=learning.states().get(target);}
        boolean phrase=identity.kind==RecallTarget.Kind.PHRASE;
        LinearLayout page=sheet(phrase?"Practice passage":"Recall");caption(page,content.surah(a.surah).name+" · Ayah "+a.number+(phrase?" · Selected passage":""));gap(page,12);
        boolean encoding=word==null&&state.reviews==0;
        String cue=word!=null?source:state.successes>=3?"Recall from memory":firstWords(source,state.successes>=2?1:2)+" …";
        TextView prompt=arabic(encoding?source:cue,word==null?28:40);page.addView(prompt);gap(page,12);
        caption(page,word!=null?"Recall this word meaning in the ayah context.":encoding?"Read once, then hide the text and recall it.":"Use the cue, then reveal the source text.");
        LinearLayout answer=column(this);answer.setVisibility(View.GONE);page.addView(answer);gap(page,14);
        TextView reveal=button(word==null?"Reveal text":"Reveal meaning",()->{});page.addView(reveal);
        if(encoding){reveal.setVisibility(View.GONE);TextView hide=button("Hide & recall",()->{});page.addView(hide);hide.setOnClickListener(v->{prompt.setText(cue);hide.setVisibility(View.GONE);reveal.setVisibility(View.VISIBLE);});}
        reveal.setOnClickListener(v->{
            if(answer.getVisibility()==View.VISIBLE)return;
            learning.event(target,Recall.Kind.REVEAL,a.id);answer.setVisibility(View.VISIBLE);reveal.setVisibility(View.GONE);
            if(word==null)answer.addView(arabic(source,arabicSize));else{answer.addView(text(this,word.gloss(language),24,INK));gap(answer,12);answer.addView(arabic(a.arabic,23));}
            recallRatings(answer,target,a.id);
        });
    }
    private void reviewTransition(AyahTransition edge){
        if(edge==null){toast("This ayah transition is unavailable");return;}
        Recall.State state=learning.states().get(edge.id);
        if(state==null||!state.active){enroll(edge.id,edge.from.id);state=learning.states().get(edge.id);}
        boolean first=state.reviews==0;
        LinearLayout page=sheet("Ayah transition");
        caption(page,"Recall how the next ayah begins after this ending.");gap(page,16);
        page.addView(label(edge.from.surah+":"+edge.from.number+" · ENDING"));
        page.addView(arabic(edge.ending.text,arabicSize));gap(page,18);
        page.addView(label(edge.to.surah+":"+edge.to.number+" · NEXT AYAH"));
        TextView opening=arabic(edge.opening.text,arabicSize);page.addView(opening);
        opening.setVisibility(first?View.VISIBLE:View.GONE);
        TextView instruction=text(this,first?"Read both once, then hide the next ayah.":"How does the next ayah begin?",15,MUTED);page.addView(instruction);gap(page,14);
        LinearLayout answer=column(this);page.addView(answer);
        TextView reveal=button("Reveal next ayah",()->{});page.addView(reveal);
        if(first){reveal.setVisibility(View.GONE);TextView hide=button("Hide & recall",()->{});page.addView(hide);
            hide.setOnClickListener(v->{opening.setVisibility(View.GONE);hide.setVisibility(View.GONE);reveal.setVisibility(View.VISIBLE);instruction.setText("How does the next ayah begin?");});}
        reveal.setOnClickListener(v->{
            if(reveal.getVisibility()!=View.VISIBLE)return;
            learning.event(edge.id,Recall.Kind.REVEAL,edge.from.id);opening.setVisibility(View.VISIBLE);reveal.setVisibility(View.GONE);instruction.setVisibility(View.GONE);
            recallRatings(answer,edge.id,edge.from.id);gap(answer,12);
            answer.addView(button("Show both ayahs",()->{
                LinearLayout context=sheet("Both ayahs");
                for(Ayah ayah:new Ayah[]{edge.from,edge.to}){context.addView(label(ayah.surah+":"+ayah.number));context.addView(arabic(ayah.arabic,arabicSize));gap(context,20);}
                context.addView(button("Back to transition",()->review(edge.id)));
            }));
        });
    }
    private void recallRatings(LinearLayout answer,String target,String context){
        gap(answer,16);caption(answer,"How well did you remember before revealing the answer?");gap(answer,14);
        String ratingId=UUID.randomUUID().toString();boolean[] rated={false};Dialog reviewDialog=activeDialog;
        String[] labels={"Again","Hard","Good","Easy"};Recall.Kind[] ratings={Recall.Kind.AGAIN,Recall.Kind.HARD,Recall.Kind.GOOD,Recall.Kind.EASY};
        for(int i=0;i<labels.length;i++){Recall.Kind rating=ratings[i];answer.addView(button(labels[i],()->{
            if(rated[0])return;rated[0]=true;learning.event(ratingId,target,rating,context);reviewDialog.dismiss();
            List<Recall.State> q=dueQueue();
            if(q.isEmpty()){toast("All caught up");show();}else review(q.get(0).target);
        }));gap(answer,8);}
    }

    private TextWatcher watcher(Runnable action){return new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){action.run();}public void afterTextChanged(Editable e){}};}
    private void searchScreen(){
        captureReaderPosition();readerScroll=null;restoringReader=null;readerVerses.clear();evidenceControls.clear();hidePeek();searching=true;layout.removeAllViews();
        header=row(this);pad(header,16,10);layout.addView(header);header.addView(iconButton("back","Back to reading",this::show));
        TextView title=text(this,"Search Quran & Hadith",20,INK);header.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        header.addView(iconButton("share","Share search results as PDF",()->{
            if(quranHits.isEmpty())shareResearch(true);else if(hadithHits.isEmpty())shareResearch(false);
            else new AlertDialog.Builder(this).setTitle("Share results").setItems(new String[]{"Quran results","Hadith results"},(dialog,index)->shareResearch(index==1)).show();
        }));
        LinearLayout fieldContainer=column(this);pad(fieldContainer,20,0);layout.addView(fieldContainer);
        EditText query=new EditText(this);query.setTextColor(INK);query.setHintTextColor(MUTED);query.setTextSize(17);
        query.setHint("Arabic text, 2:255, Bukhari 556 or 556");query.setMinLines(1);query.setMaxLines(4);
        query.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_MULTI_LINE);query.setTextDirection(View.TEXT_DIRECTION_FIRST_STRONG);
        query.setFilters(new InputFilter[]{new InputFilter.LengthFilter(16384)});pad(query,16,8);query.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));fieldContainer.addView(query,new LinearLayout.LayoutParams(-1,-2));
        gap(fieldContainer,8);LinearLayout chips=row(this);String[] scopes={"All","Quran","Hadith"};
        for(int i=0;i<scopes.length;i++){final int scope=i;TextView chip=button((searchScope==i?"✓ ":"")+scopes[i],()->{searchScope=scope;searchScreen();});chips.addView(chip,new LinearLayout.LayoutParams(0,-2,1));}
        fieldContainer.addView(chips);gap(fieldContainer,8);fieldContainer.addView(button("Voice search",()->voiceSearch(false)));
        body=column(this);layout.addView(body,new LinearLayout.LayoutParams(-1,0,1));LinearLayout results=scrollBody();
        TextView status=text(this,"Search offline, with or without Arabic vowel marks.",14,MUTED);results.addView(status);gap(results,12);
        LinearLayout list=column(this);results.addView(list);
        Runnable run=()->{
            searchQuery=query.getText().toString();hadithQuery=searchQuery;quranHits.clear();hadithHits.clear();hadithTotal=0;selectedHadith.clear();
            evidenceControls.clear();list.removeAllViews();
            int generation=searchGeneration.incrementAndGet();cancelSearchWork();if(debounce!=null)ui.removeCallbacks(debounce);
            String q=searchQuery.trim();if(q.isEmpty()){status.setText("Search offline, with or without Arabic vowel marks.");return;}
            UnifiedQuery intent=UnifiedQuery.parse(q,searchScope);
            String scope=intent.hadithQuery.collectionId!=null||intent.hadithQuery.sahihCollections?" · "+intent.hadithQuery.scopeLabel():"";
            String correction=intent.hadithQuery.corrected?" · Book-name spelling adjusted":"";
            status.setText("Searching offline"+scope+"…");
            LinearLayout quranList=column(this),hadithList=column(this);list.addView(quranList);list.addView(hadithList);
            final CancellationSignal signal=beginSearch(generation,status);
            pendingCorpora=(intent.quran?1:0)+(intent.hadith?1:0);pendingSearchJobs=pendingCorpora;
            Runnable finished=()->{
                if(searchGeneration.get()!=generation||signal.isCanceled())return;
                if(--pendingSearchJobs==0)finishSearch(signal);
                if(--pendingCorpora==0){status.setText("Offline results"+scope+correction);}
                else status.setText("Results arriving · Searching remaining collection…");
            };
            debounce=()->{
                if(signal.isCanceled())return;
                if(intent.hadith)searchTask=app.searchWorker.submit(()->{
                    try {
                        HadithStore.SearchPage result=app.hadith==null?null:app.hadith.searchPage(q,50,0,signal);
                        ui.post(()->{if(isDestroyed()||!searching||signal.isCanceled()||searchGeneration.get()!=generation)return;
                            hadithList.addView(label("HADITH"));
                            if(result==null)caption(hadithList,"A local Hadith pack is not installed.");
                            else {TextView hs=text(this,"",13,MUTED);hadithList.addView(hs);gap(hadithList,8);
                                LinearLayout matches=column(this);hadithList.addView(matches);appendHadithResults(q,result,generation,matches,hs);}
                            finished.run();
                        });
                    }catch(CancellationException|OperationCanceledException ignored){}catch(Exception error){
                        android.util.Log.w("AarisSearch","Hadith search failed",error);
                        ui.post(()->{if(!isDestroyed()&&searching&&!signal.isCanceled()&&searchGeneration.get()==generation){caption(hadithList,"Hadith search could not finish. Please try again.");finished.run();}});
                    }
                });
                if(intent.quran)quranSearchTask=app.quranSearchWorker.submit(()->{
                    try {
                        if(app.search==null)app.search=content.buildSearch(app.translations);
                        final SearchEngine.Response result=app.search.search(intent.quranText,6236);
                        ui.post(()->{if(isDestroyed()||!searching||signal.isCanceled()||searchGeneration.get()!=generation)return;
                            quranList.addView(label("QURAN"));TextView qs=text(this,result.results.isEmpty()?"No Quran text match. Try a shorter phrase.":"",13,MUTED);quranList.addView(qs);gap(quranList,8);
                            showSearchShortcut(quranList,false,q);
                            if(result.fragments!=null)showFragments(quranList,result,query);
                            appendQuranResults(quranList,result,0,qs);finished.run();
                        });
                    }catch(CancellationException ignored){}catch(Exception error){
                        android.util.Log.w("AarisSearch","Quran search failed",error);
                        ui.post(()->{if(!isDestroyed()&&searching&&!signal.isCanceled()&&searchGeneration.get()==generation){caption(quranList,"Quran search could not finish. Please try again.");finished.run();}});
                    }
                });
            };ui.postDelayed(debounce,220);
        };
        query.addTextChangedListener(watcher(run));query.setText(searchQuery);query.setSelection(query.length());
    }
    private void appendQuranResults(LinearLayout list,SearchEngine.Response response,int offset,TextView status){
        int generation=searchGeneration.get(),end=Math.min(offset+50,response.results.size());
        if(offset<end)quranHits.addAll(response.results.subList(offset,end));
        appendQuranBatch(list,response,offset,end,status,generation);
    }
    private void appendQuranBatch(LinearLayout list,SearchEngine.Response response,int cursor,int end,TextView status,int generation){
        if(isDestroyed()||!searching||searchGeneration.get()!=generation)return;
        int batchEnd=Math.min(cursor+SEARCH_RENDER_BATCH,end);
        for(SearchEngine.Result result:response.results.subList(cursor,batchEnd)){
            LinearLayout c=card(list,Surface.Kind.PANEL);c.addView(label(result.match.band+" TEXT MATCH · "+result.match.matched+" / "+result.match.total+" words"));gap(c,8);
            Ayah a=result.ayah;c.addView(text(this,content.surah(a.surah).name+" · "+a.surah+":"+a.number,18,INK));gap(c,10);c.addView(arabic(a.arabic,25));gap(c,12);
            addTranslation(c,a);caption(c,String.join(" · ",result.reasons));gap(c,14);c.addView(evidenceActions(a,retrievalTrace(response,result)));
            c.addView(button("Remember this match",()->rememberSearch(false,response.query,a.id)));
        }
        if(batchEnd<end){status.setText("Showing "+batchEnd+" of "+response.results.size()+"…");list.postOnAnimation(()->appendQuranBatch(list,response,batchEnd,end,status,generation));return;}
        if(!response.results.isEmpty())status.setText(end+" of "+response.results.size()+" matches · High → Medium → Low");
        if(end<response.results.size()){TextView more=button("Load next 50 matches",()->{});list.addView(more);more.setOnClickListener(v->{list.removeView(more);appendQuranResults(list,response,end,status);});}
    }
    private LinearLayout evidenceActions(Ayah ayah,JSONObject trace){
        LinearLayout actions=row(this);actions.addView(button("Open Ayah",()->open(ayah.surah,ayah.number)),new LinearLayout.LayoutParams(0,-2,1));
        TextView select=button(selectedEvidence.contains(ayah.id)?"Selected ✓":"Evidence +",()->{});
        evidenceControls.computeIfAbsent(ayah.id,k->new ArrayList<>()).add(select);
        select.setOnClickListener(v->{
            if(selectedEvidence.contains(ayah.id)){selectedEvidence.remove(ayah.id);selectionTrace.remove(ayah.id);select.setText("Evidence +");}
            else if(selectedEvidence.size()<50){selectedEvidence.add(ayah.id);selectionTrace.put(ayah.id,trace);select.setText("Selected ✓");}
            else toast("Select up to 50 ayahs per bundle");
            refreshEvidenceControls();
        });
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.leftMargin=dp(this,8);actions.addView(select,p);return actions;
    }
    private void refreshEvidenceControls(){for(Map.Entry<String,List<TextView>> entry:evidenceControls.entrySet())for(TextView view:entry.getValue())view.setText(selectedEvidence.contains(entry.getKey())?"Selected ✓":"Evidence +");}
    private void showFragments(LinearLayout list,SearchEngine.Response response,EditText query){
        FragmentSearch.Report report=response.fragments;LinearLayout summary=card(list,Surface.Kind.HERO);
        summary.addView(label("SOURCES FOR SEPARATE FRAGMENTS"));gap(summary,10);
        caption(summary,report.matchedTokens+" / "+report.totalTokens+" words were found in consecutive source fragments. Do not combine them into one ayah or treat them as one verified quote.");
        if(!report.unmatched.isEmpty()){
            gap(summary,14);summary.addView(label("THIS FRAGMENT WAS NOT FOUND"));
            for(SourceText.Range gap:report.unmatched)summary.addView(arabic(gap.text,24));
            caption(summary,"These words were not removed or silently corrected during matching.");
        }
        int number=0;
        for(FragmentSearch.Fragment fragment:report.fragments){
            LinearLayout c=card(list,Surface.Kind.PANEL);c.addView(label("FRAGMENT "+(++number)+" · YOU ENTERED"));c.addView(arabic(fragment.query.text,24));gap(c,10);
            caption(c,"Found at "+fragment.totalOccurrences+" source locations · Text match ignores reading marks");gap(c,12);
            for(FragmentSearch.Hit hit:fragment.alternatives){
                c.addView(label(content.surah(hit.ayah.surah).name+" · "+hit.ayah.surah+":"+hit.ayah.number));
                c.addView(arabic(hit.source.text,27));caption(c,"Exact source fragment; open the full ayah for context.");gap(c,10);
                c.addView(evidenceActions(hit.ayah,fragmentTrace(response,fragment,hit)));gap(c,18);
            }
            if(fragment.totalOccurrences>fragment.alternatives.size())caption(c,"Showing the first "+fragment.alternatives.size()+" source locations; none is assumed to be the intended original source.");
            c.addView(button("Search only this fragment",()->{query.setText(fragment.query.text);query.setSelection(query.length());}));
        }
        if(!response.results.isEmpty()){list.addView(label("RELATED RESULTS FOR THE FULL QUERY"));gap(list,12);}
    }
    private void settings(){
        LinearLayout page=sheet("Reading settings");Dialog settingsDialog=activeDialog;
        settingsDialog.setOnDismissListener(d->{if(activeDialog==settingsDialog){activeDialog=null;show();}});

        page.addView(settingsRow("settings","Appearance",this::appearanceStudio));gap(page,9);
        page.addView(settingsRow("copy","Translation",this::translationSettings));gap(page,12);

        page.addView(label("ARABIC SIZE"));gap(page,6);
        ArabicText sample=arabic(content.ayah("Q:1:1").arabic,arabicSize);page.addView(sample);
        SeekBar slider=new SeekBar(this);slider.setMax(22);slider.setProgress((int)arabicSize-24);page.addView(slider);
        slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar s,int p,boolean user){arabicSize=24+p;sample.setTextSize(arabicSize);}
            public void onStartTrackingTouch(SeekBar s){}
            public void onStopTrackingTouch(SeekBar s){learning.set("arabic_size",""+arabicSize);appearance.arabicSize=(int)arabicSize;appearance.save(MainActivity.this);}
        });
        gap(page,12);page.addView(label("WORD MEANING LANGUAGE"));gap(page,8);
        LinearLayout langs=row(this);
        for(String lang:new String[]{"hi","ur","en"}){
            String name=lang.equals("hi")?"हिन्दी":lang.equals("ur")?"اردو":"English";
            TextView b=button(name+(language.equals(lang)?" ✓":""),()->{language=lang;learning.set("language",lang);settings();});
            langs.addView(b,new LinearLayout.LayoutParams(0,-2,1));
        }
        page.addView(langs);gap(page,14);

        Switch contrast=new Switch(this);contrast.setText("High contrast");contrast.setTextColor(INK);contrast.setChecked(highContrast);contrast.setMinHeight(dp(this,48));page.addView(contrast);
        contrast.setOnCheckedChangeListener((b,v)->{highContrast=v;learning.set("contrast",""+v);sample.setReliefEnabled(!v);backdrop.highContrast=v;backdrop.invalidate();});
        gap(page,12);

        page.addView(settingsRow("moon","Focus mode",()->{quietReader=true;tab=1;reading=true;settingsDialog.dismiss();}));gap(page,9);
        page.addView(settingsRow("speaker","Quran audio",()->{
            Ayah current=content.ayah(readingPosition==null?"Q:"+readerSurah+":"+readerStart:readingPosition.anchorId);
            if(current==null)current=content.ayah("Q:"+readerSurah+":"+readerStart);
            audioControls(current);
        }));gap(page,9);
        page.addView(settingsRow("clock","Set timer",this::ambientSettings));gap(page,9);
        page.addView(settingsRow("share","Open in other apps",()->{if(app.ambientRunning){settingsDialog.dismiss();openOtherApps();}else ambientSettings();}));gap(page,12);

        page.addView(settingsRow("book","Sources & licenses",this::sources));gap(page,9);
        page.addView(settingsRow("download","Export learning",this::backup));gap(page,9);
        page.addView(settingsRow("cards","Backup & restore",this::restorePicker));gap(page,9);
        page.addView(settingsRow("bookmark","Study & collections",this::studyLibrary));gap(page,9);
        page.addView(settingsRow("copy","Translation drafts",this::translationDrafts));gap(page,9);
        page.addView(settingsRow("close","Clear search history",()->new AlertDialog.Builder(this).setTitle("Clear search history?")
            .setMessage("Only your confirmed search shortcuts will be removed.").setNegativeButton("Cancel",null)
            .setPositiveButton("Clear",(d,w)->{learning.clearSearchShortcuts();toast("Search history cleared");}).show()));gap(page,12);

        page.addView(primary("Done",settingsDialog::dismiss));
    }
    private void sources(){
        LinearLayout page=sheet("Sources aur bharosa");caption(page,content.sources());gap(page,16);
        caption(page,"Quran: 114 surahs / 6,236 ayahs. Original text checksum verified. Meanings: imported source word glosses; independent scholarly review is still pending. Word-level meanings are withheld for 9 ayahs where alignment could not be verified.");gap(page,12);
        if(app.wordAudio!=null)caption(page,"Word pronunciation: "+app.wordAudio.installedCount()+"/114 Surahs locally installed · "+app.wordAudio.attribution()+". Audio is fetched only after your Download action; installed Surahs replay without network access.");
        else caption(page,"Word pronunciation storage is not available yet.");
        gap(page,12);
        caption(page,"This is a non-commercial preview. Imported gloss data is not cleared for a paid app, subscription, or advertising.");gap(page,14);
        for(String[] item:new String[][]{{"Tanzil notice","licenses/TANZIL.txt"},{"Word meanings license","licenses/DATA-QURAN.txt"},{"Amiri Quran font license","licenses/AMIRI-OFL.txt"},{"Amiri Naskh font license","licenses/AMIRI-TEXT-OFL.txt"},{"Extra Arabic fonts license","licenses/EXTRA-ARABIC-FONTS-OFL.txt"},{"Extra Arabic fonts sources","licenses/EXTRA-ARABIC-FONTS-SOURCES.txt"}}){page.addView(button(item[0],()->{LinearLayout p=sheet(item[0]);try{TextView v=text(this,ContentStore.asset(this,item[1]),12,MUTED);v.setTextIsSelectable(true);p.addView(v);}catch(IOException e){caption(p,"License file unavailable");}}));gap(page,8);}
        page.addView(button("Tanzil source website",()->openWebsite(Uri.parse("https://tanzil.net/"))));gap(page,10);
        if(app.translations!=null){for(TranslationStore.Edition edition:app.translations.editions)caption(page,edition.attribution()+"\n"+edition.description);caption(page,app.translations.notice);}
        caption(page,RecitationDownloads.ATTRIBUTION);
        caption(page,"Pack SHA-256\n"+content.packHash+"\nScheduler: "+Recall.VERSION+"\nSearch: "+SearchEngine.VERSION);
    }
    private void hideKeyboard(){View view=getCurrentFocus();if(view!=null)((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(view.getWindowToken(),0);}
    private void shareText(String text){Intent share=new Intent(Intent.ACTION_SEND);share.setType("text/plain");share.putExtra(Intent.EXTRA_TEXT,text);startActivity(Intent.createChooser(share,"Share"));}
    private void saveFile(String name,String type,byte[] bytes){
        app.io.execute(()->{
            try{String token=app.exports.stage(bytes);ui.post(()->{
                preparingExport=false;
                if(isDestroyed()||isFinishing()){app.io.execute(()->discardExport(token));return;}
                pendingExport=token;Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT);intent.addCategory(Intent.CATEGORY_OPENABLE);intent.setType(type);intent.putExtra(Intent.EXTRA_TITLE,name);
                try{startActivityForResult(intent,EXPORT);}catch(ActivityNotFoundException e){pendingExport=null;app.io.execute(()->discardExport(token));toast("No document picker is available to save this file");}
            });}catch(Exception e){ui.post(()->{preparingExport=false;toast("Export could not be prepared: "+e.getMessage());});}
        });
    }
    private void discardExport(String token){if(token!=null)try{app.exports.discard(token);}catch(IOException ignored){}}
    private boolean beginExport(){if(preparingExport||pendingExport!=null){toast("Finish the current export first");return false;}preparingExport=true;return true;}
    private void backup(){
        if(!beginExport())return;
        app.io.execute(()->{try{byte[] data=learning.backup().toString(2).getBytes(StandardCharsets.UTF_8);ui.post(()->{if(!isDestroyed())saveFile("Aaris-Quran-learning.json","application/json",data);});}catch(Exception e){ui.post(()->{preparingExport=false;toast("Backup could not be created");});}});
    }
    private void restorePicker(){Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);intent.addCategory(Intent.CATEGORY_OPENABLE);intent.setType("application/json");try{startActivityForResult(intent,IMPORT);}catch(ActivityNotFoundException e){toast("No document picker is available to open the backup");}}
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(request==VOICE_SEARCH){
            int scope=pendingVoiceScope;pendingVoiceScope=-1;
            if(result!=RESULT_OK||data==null||scope<0)return;
            ArrayList<String> candidates=data.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS);
            if(candidates==null||candidates.isEmpty())return;
            String heard=candidates.get(0);if(heard==null||heard.trim().isEmpty())return;
            app.ready(()->{if(isDestroyed()||isFinishing()||content==null)return;
                searchQuery=heard;searchScreen();
            });
            return;
        }
        if(request==OVERLAY_PERMISSION){if(pendingAmbient&&Settings.canDrawOverlays(this))beginAmbient();else {pendingAmbient=false;openOtherAppsAfterAmbientStart=false;toast("Overlay permission is needed for cards over other apps");}return;}
        if(result!=RESULT_OK||data==null||data.getData()==null){if(request==EXPORT){String token=pendingExport;pendingExport=null;app.io.execute(()->discardExport(token));}return;}Uri uri=data.getData();
        if(request==EXPORT){String token=pendingExport;pendingExport=null;if(token==null){toast("Start the export again");return;}app.io.execute(()->{
            try{try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException();app.exports.copyTo(token,out);}discardExport(token);ui.post(()->toast("File saved"));}
            catch(Exception e){ui.post(()->toast("File was not saved; start the export again"));}
        });}
        if(request==IMPORT)app.io.execute(()->{try{
            ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=getContentResolver().openInputStream(uri)){if(in==null)throw new IOException();byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1){if(out.size()+n>ExportStaging.MAX_BYTES)throw new IOException("Backup is larger than 64 MiB");out.write(b,0,n);}}
            JSONObject backup=new JSONObject(out.toString("UTF-8"));int count=learning.validateBackup(backup,content);
            ui.post(()->{if(isDestroyed())return;pendingRestore=backup;new AlertDialog.Builder(this).setTitle("Restore learning history?").setMessage(count+" history events will be merged. Existing history and notes will not be deleted.").setNegativeButton("Not now",(d,w)->pendingRestore=null).setPositiveButton("Merge",(d,w)->{JSONObject restore=pendingRestore;pendingRestore=null;app.io.execute(()->{try{learning.restore(restore,content);ui.post(()->{toast("Learning history restored");show();});}catch(Exception e){ui.post(()->toast("Restore failed; existing data is safe"));}});}).show();});
        }catch(Exception e){ui.post(()->toast("Backup is not valid: "+e.getMessage()));}});
    }
    @Override public void onBackPressed(){if(overlay.getChildCount()>0){hidePeek();return;}if(searching){searchGeneration.incrementAndGet();cancelSearchWork();show();return;}if(quietReader){quietReader=false;show();return;}if(tab==1&&reading){reading=false;show();return;}if(tab!=1){tab=1;reading=true;show();return;}super.onBackPressed();}

    private JSONObject selectionOrigin(String origin){
        try{return new JSONObject().put("selection_origin",origin);}catch(JSONException e){throw new IllegalStateException(e);}
    }
    private JSONObject retrievalTrace(SearchEngine.Response response,SearchEngine.Result result){
        try{
            JSONArray variants=new JSONArray();for(SearchEngine.Variant v:response.variants)variants.put(new JSONObject()
                .put("original",v.original).put("safe",v.safe).put("tolerant",v.tolerant).put("origin",v.origin.name()).put("normalization_cost",v.normalizationCost));
            return new JSONObject().put("selection_origin","SEARCH").put("engine",SearchEngine.VERSION)
                .put("query",response.query).put("intent",response.intent).put("query_variants",variants)
                .put("matched_variants",new JSONArray(result.matchedVariants)).put("strength",result.strength.name())
                .put("reasons",new JSONArray(result.reasons)).put("transformation_cost",result.transformationCost).put("match_band",result.match.band.name()).put("matched_words",result.match.matched).put("query_words",result.match.total)
                .put("counts",new JSONObject(response.trace));
        }catch(JSONException e){throw new IllegalStateException(e);}
    }
    private JSONObject sourceRange(SourceText.Range range)throws JSONException{
        return new JSONObject().put("start_cp",range.start).put("end_cp",range.end).put("text",range.text);
    }
    private JSONObject fragmentTrace(SearchEngine.Response response,FragmentSearch.Fragment fragment,FragmentSearch.Hit hit){
        try{
            JSONArray unmatched=new JSONArray();for(SourceText.Range range:response.fragments.unmatched)unmatched.put(sourceRange(range));
            return new JSONObject().put("selection_origin","SEARCH_FRAGMENT").put("engine",SearchEngine.VERSION)
                .put("query",response.query).put("fragment_query",response.fragments.query).put("query_origin","USER")
                .put("strength","EXACT_FRAGMENT_ONLY").put("whole_query_matched",false)
                .put("query_range",sourceRange(fragment.query)).put("source_range",sourceRange(hit.source))
                .put("source_id",hit.ayah.id).put("source_sha256",hit.ayah.sha256)
                .put("total_occurrences",fragment.totalOccurrences).put("unmatched",unmatched)
                .put("normalization","safe; reading marks ignored; original spans preserved").put("counts",new JSONObject(response.trace));
        }catch(JSONException e){throw new IllegalStateException(e);}
    }

    private void shareResearch(boolean hadith){
        if(sharingPdf){toast("PDF is being prepared…");return;}
        List<HadithStore.Hit> hits=new ArrayList<>();List<Ayah> ayahs=new ArrayList<>();Map<String,String> matches=new LinkedHashMap<>();
        if(hadith){for(HadithStore.Hit h:hadithHits)if(selectedHadith.isEmpty()||selectedHadith.contains(h.record.id))hits.add(h);}
        else{for(SearchEngine.Result r:quranHits){matches.put(r.ayah.id,r.match.band+" TEXT MATCH · "+r.match.explanation());if(selectedEvidence.isEmpty())ayahs.add(r.ayah);}if(!selectedEvidence.isEmpty())for(String id:selectedEvidence){Ayah a=content.ayah(id);if(a!=null)ayahs.add(a);}}
        int count=hadith?hits.size():ayahs.size();if(count==0){toast("Search or select records first");return;}
        LinearLayout page=sheet("Share research PDF");Dialog dialog=activeDialog;
        caption(page,count+" complete source records will be exported. "+(hadith&&count<hadithTotal?"There are "+hadithTotal+" matches in total; this PDF includes selected or loaded results.":"Selected records, or the currently displayed results, are included."));gap(page,14);
        caption(page,"Research question");Spinner template=new Spinner(this);
        template.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,ResearchExport.TEMPLATES));
        template.setContentDescription("Research prompt template");template.setMinimumHeight(dp(this,48));page.addView(template);
        EditText custom=new EditText(this);custom.setTextColor(INK);custom.setHintTextColor(MUTED);custom.setHint("Your research question");
        custom.setMinLines(2);custom.setMaxLines(5);custom.setFilters(new InputFilter[]{new InputFilter.LengthFilter(2000)});custom.setVisibility(View.GONE);page.addView(custom);
        template.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> parent){}public void onItemSelected(AdapterView<?> parent,View v,int position,long id){custom.setVisibility(position==ResearchExport.TEMPLATES.length-1?View.VISIBLE:View.GONE);}});
        LinearLayout comparison=column(this);comparison.setVisibility(View.GONE);
        page.addView(button("Preview & compare selected records",()->{
            if(count<2||count>10){toast("Select 2–10 search results to compare here. PDF export can include more.");return;}
            if(comparison.getChildCount()==0){
                caption(comparison,"Search matches for comparison. Similar wording alone does not establish a shared narration or religious relationship.");
                if(hadith)for(HadithStore.Hit hit:hits){HadithStore.Record r=hit.record;HadithStore.CollectionInfo info=app.hadith.collection(r.collectionId);
                    LinearLayout c=card(comparison,Surface.Kind.PANEL);c.addView(label((info==null?r.collectionId:info.nameEn)+" · "+r.number+" ["+r.id+"]"));
                    caption(c,hit.match.band+" TEXT MATCH · "+hit.match.explanation());c.addView(hadithArabic(r.arabic,25));
                    HadithStore.DisplayTranslation t=app.hadith.translation(r,readingLanguage());if(t!=null){TextView translated=text(this,t.text,appearance.translationSize,appearance.translationInk());translated.setTextDirection(View.TEXT_DIRECTION_FIRST_STRONG);c.addView(translated);caption(c,languageName(t.language)+" · "+t.provenance);}
                    List<String> grades=app.hadith.grades(r.id);caption(c,grades.isEmpty()?"No individual grading is recorded in this pack.":String.join("\n",grades));
                }else for(Ayah a:ayahs){LinearLayout c=card(comparison,Surface.Kind.PANEL);c.addView(label(a.id+" · "+content.surah(a.surah).name));c.addView(arabic(a.arabic,28));addTranslation(c,a);}
            }
            comparison.setVisibility(comparison.getVisibility()==View.VISIBLE?View.GONE:View.VISIBLE);
        }));page.addView(comparison);gap(page,12);
        page.addView(primary("Share PDF · "+count+" records",()->{
            if(template.getSelectedItemPosition()==ResearchExport.TEMPLATES.length-1&&custom.getText().toString().trim().isEmpty()){toast("Write a research question first");return;}
            final String researchPrompt=ResearchExport.prompt(template.getSelectedItemPosition(),custom.getText().toString());
            sharingPdf=true;dialog.dismiss();toast("Preparing PDF on your phone…");String query=hadith?hadithQuery:searchQuery,edition=translationId,lang=readingLanguage();
            app.io.execute(()->{try{
                byte[] bytes=hadith?ResearchExport.hadith(this,app.hadith,hits,lang,query,researchPrompt):ResearchExport.quran(this,content,app.translations,edition,ayahs,matches,query,researchPrompt);
                Uri uri=ResearchFiles.write(this,bytes);ui.post(()->{sharingPdf=false;if(isDestroyed()||isFinishing())return;
                    Intent intent=new Intent(Intent.ACTION_SEND).setType("application/pdf").putExtra(Intent.EXTRA_STREAM,uri).putExtra(Intent.EXTRA_TEXT,researchPrompt);
                    intent.setClipData(ClipData.newRawUri("Aaris research PDF",uri));
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    try{startActivity(Intent.createChooser(intent,"Share research PDF"));}catch(ActivityNotFoundException e){toast("No PDF receiving app is installed");}
                });
            }catch(Exception e){ui.post(()->{sharingPdf=false;toast("PDF could not be created. Try fewer records.");});}});
        }));gap(page,10);
        page.addView(button("Copy AI research prompt",()->{((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Research prompt",ResearchExport.prompt(template.getSelectedItemPosition(),custom.getText().toString())));toast("Prompt copied");}));
        if(!hadith){gap(page,10);page.addView(button("Evidence tools · ZIP & reference check",this::research));}
    }
    private void research(){
        LinearLayout page=sheet("Evidence & research");caption(page,"Select ayahs from search results. The export includes original Quran text, references, and the source checksum.");gap(page,12);
        page.addView(text(this,selectedEvidence.size()+" ayahs selected",21,INK));gap(page,14);
        TextView export=button("PDF + TXT + JSON export",()->{
            if(selectedEvidence.isEmpty()){toast("Select ayahs from search results first");return;}
            if(!beginExport())return;
            List<String> selection=new ArrayList<>(selectedEvidence);Map<String,JSONObject> traces=new LinkedHashMap<>(selectionTrace);String query=searchQuery;
            toast("Preparing evidence bundle…");app.io.execute(()->{try{
                EvidenceExporter.Bundle b=EvidenceExporter.build(this,content,selection,query,traces);learning.saveBundle(b.id,b.json);
                ui.post(()->{if(!isDestroyed())saveFile("Aaris-Quran-evidence.zip","application/zip",b.zip);});
            }catch(Exception e){ui.post(()->{preparingExport=false;toast("Export failed: "+e.getMessage());});}});
        });page.addView(export);gap(page,10);
        page.addView(button("Clear selection",()->{selectedEvidence.clear();selectionTrace.clear();refreshEvidenceControls();research();}));gap(page,20);
        page.addView(label("WITH ANOTHER AI"));gap(page,8);caption(page,"After you tap Share, you choose the destination. The app does not send your query or learning history by itself.");gap(page,12);
        page.addView(button("Share search-query prompt",()->shareText(References.queryPrompt(searchQuery))));gap(page,10);
        page.addView(button("Share evidence-reading prompt",()->shareText(References.reasoningPrompt())));gap(page,10);
        page.addView(button("Check references in an AI answer",this::verifyAnswer));gap(page,10);
    }
    private void verifyAnswer(){
        String saved=learning.lastBundle();if(saved==null){toast("Export an evidence bundle first");return;}
        LinearLayout page=sheet("Check references");caption(page,"Checks against the last exported snapshot. Format: \"exact Arabic quote\" [Q:2:255]. This verifies citations, not the AI's reasoning or a religious conclusion.");
        EditText answer=new EditText(this);answer.setTextColor(INK);answer.setHintTextColor(MUTED);answer.setHint("Paste the AI answer here…");answer.setMinLines(5);answer.setMaxLines(10);answer.setFilters(new InputFilter[]{new InputFilter.LengthFilter(100000)});page.addView(answer);gap(page,14);
        TextView report=text(this,"",15,INK);page.addView(report);
        page.addView(button("View references",()->{
            try{Map<String,String> snapshot=BackupValidator.validateBundle(new JSONObject(saved),content);
                References.Check c=References.verify(answer.getText().toString(),snapshot);
                report.setText((c.passed()?"Reference IDs match.":"Reference check is incomplete or mismatched.")+"\nFound: "+c.found.size()+" · Missing: "+c.missing.size()+"\nExact quotes checked: "+c.checkedQuotes+" · Mismatch: "+c.badQuotes.size()+" · Quotes without citations: "+c.uncheckedQuotes+"\n"+(c.missing.isEmpty()?"":String.join(", ",c.missing))+"\nOnly double-quoted text immediately followed by a citation is checked. The conclusion itself is not verified.");hideKeyboard();
            }catch(Exception e){report.setText("Evidence snapshot could not be checked.");}
        }));
    }
}
