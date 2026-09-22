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
    private Future<?> searchTask;
    private Runnable debounce;
    private String pendingExport;
    private boolean preparingExport;
    private boolean pendingAmbient,previewAmbient,ambientSheetRequested,resumed,ambientResumePending;
    private JSONObject pendingRestore;
    private String searchQuery="";
    private final LinkedHashSet<String> selectedEvidence=new LinkedHashSet<>();
    private final Map<String,JSONObject> selectionTrace=new LinkedHashMap<>();
    private final Map<String,List<TextView>> evidenceControls=new HashMap<>();
    private static final int EXPORT=700,IMPORT=701,OVERLAY_PERMISSION=702,NOTIFICATIONS=703;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);app=(QuranApp)getApplication();
        if(state!=null){pendingAmbient=state.getBoolean("pending_ambient");previewAmbient=state.getBoolean("preview_ambient");ambientResumePending=state.getBoolean("ambient_resume_pending");}
        if(state!=null&&ExportStaging.validToken(state.getString("pending_export")))pendingExport=state.getString("pending_export");
        arabicFont=Typeface.createFromAsset(getAssets(),"fonts/AmiriQuran.ttf");
        if(Build.VERSION.SDK_INT>=30)getWindow().setDecorFitsSystemWindows(false);
        root=new FrameLayout(this);backdrop=new Glass.Backdrop(this);root.addView(backdrop,new FrameLayout.LayoutParams(-1,-1));
        layout=column(this);root.addView(layout,new FrameLayout.LayoutParams(-1,-1));
        overlay=new FrameLayout(this);root.addView(overlay,new FrameLayout.LayoutParams(-1,-1));
        root.setOnApplyWindowInsetsListener((view,insets)->{
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets edges=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout()|WindowInsets.Type.ime());view.setPadding(edges.left,edges.top,edges.right,edges.bottom);}
            else view.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());return insets;
        });setContentView(root);
        TextView loading=text(this,"Aaris Quran\nAapka offline Mushaf khul raha hai…",20,INK);loading.setGravity(Gravity.CENTER);layout.addView(loading,new LinearLayout.LayoutParams(-1,-1));
        app.ready(()->{
            if(isFinishing()||isDestroyed())return;
            if(app.loadError!=null){loading.setText(app.loadError+"\nApp ko dobara kholein. Aapki learning alag surakshit hai.");return;}
            content=app.content;learning=app.learning;
            language=learning.get("language","hi");
            highContrast=Boolean.parseBoolean(learning.get("contrast","false"));
            arabicSize=clamp(parseFloat(learning.get("arabic_size","32"),32),24,46);
            String last=learning.get("position","Q:1:1");Ayah a=content.ayah(last);
            if(a!=null){readerSurah=a.surah;readerStart=a.number;}
            if(state!=null){tab=state.getInt("tab",1);reading=state.getBoolean("reading",true);quietReader=state.getBoolean("quiet_reader",false);readerSurah=state.getInt("surah",readerSurah);readerStart=state.getInt("start",readerStart);
                searchQuery=state.getString("query","");ArrayList<String> ids=state.getStringArrayList("evidence");if(ids!=null)for(String id:ids)if(selectedEvidence.size()<50&&content.ayah(id)!=null)selectedEvidence.add(id);
                try{JSONObject traces=new JSONObject(state.getString("selection_trace","{}"));for(String id:selectedEvidence)selectionTrace.put(id,traces.has(id)?traces.getJSONObject(id):selectionOrigin("RESTORED_SELECTION_WITHOUT_TRACE"));}catch(JSONException ignored){}
            }
            readingPosition=content.readingPosition(state==null?learning.get("reader_anchor",""):state.getString("reader_anchor",""));
            if(readingPosition!=null){Ayah page=content.ayah(readingPosition.pageId);readerSurah=page.surah;readerStart=page.number;}
            if(getIntent().getBooleanExtra("open_ambient",false)){tab=3;ambientSheetRequested=true;getIntent().removeExtra("open_ambient");}
            tab=Math.max(0,Math.min(3,tab));show();
            if(ambientSheetRequested){ambientSheetRequested=false;ambientSettings();}
        });
    }
    private static float clamp(float x,float min,float max){return Math.max(min,Math.min(max,x));}
    private static float parseFloat(String value,float fallback){try{return Float.parseFloat(value);}catch(Exception e){return fallback;}}
    @Override protected void onSaveInstanceState(Bundle state){captureReaderPosition();super.onSaveInstanceState(state);state.putBoolean("pending_ambient",pendingAmbient);state.putBoolean("ambient_resume_pending",ambientResumePending);state.putBoolean("preview_ambient",previewAmbient);state.putString("pending_export",pendingExport);state.putInt("tab",tab);state.putBoolean("reading",reading);state.putBoolean("quiet_reader",quietReader);state.putInt("surah",readerSurah);state.putInt("start",readerStart);if(readingPosition!=null)state.putString("reader_anchor",readingPosition.encode());state.putString("query",searchQuery);state.putStringArrayList("evidence",new ArrayList<>(selectedEvidence));String trace=new JSONObject(selectionTrace).toString();if(trace.length()<=64000)state.putString("selection_trace",trace);}
    @Override protected void onPostResume(){super.onPostResume();resumed=true;if(ambientResumePending){ambientResumePending=false;beginAmbient();}}
    @Override protected void onPause(){resumed=false;captureReaderPosition();if(learning!=null&&readingPosition!=null){learning.set("reader_anchor",readingPosition.encode());learning.set("position",readingPosition.anchorId);}super.onPause();}
    @Override protected void onDestroy(){ui.removeCallbacksAndMessages(null);searchGeneration.incrementAndGet();if(searchTask!=null)searchTask.cancel(true);Dialog dialog=activeDialog;activeDialog=null;if(dialog!=null)dialog.dismiss();super.onDestroy();}
    @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);if(intent.getBooleanExtra("open_ambient",false)){intent.removeExtra("open_ambient");if(content==null){ambientSheetRequested=true;return;}tab=3;show();ambientSettings();}}
    private void show(){
        if(content==null||isDestroyed()||isFinishing())return;captureReaderPosition();hideKeyboard();readerScroll=null;restoringReader=null;readerVerses.clear();evidenceControls.clear();searchGeneration.incrementAndGet();if(searchTask!=null)searchTask.cancel(true);if(debounce!=null)ui.removeCallbacks(debounce);hidePeek();layout.removeAllViews();searching=false;backdrop.highContrast=highContrast;backdrop.invalidate();
        header=row(this);pad(header,20,10);layout.addView(header,new LinearLayout.LayoutParams(-1,-2));
        body=column(this);layout.addView(body,new LinearLayout.LayoutParams(-1,0,1));
        bottom=row(this);pad(bottom,6,5);bottom.setBackground(new Surface(this,Surface.Kind.NAV,highContrast));LinearLayout.LayoutParams navSize=new LinearLayout.LayoutParams(-1,-2);navSize.setMargins(dp(this,16),dp(this,6),dp(this,16),dp(this,10));layout.addView(bottom,navSize);
        if(tab==0)today();else if(tab==1){if(reading)reader();else library();}else if(tab==2)hadithLibrary();else map();
        nav("sun","Aaj",0);nav("book","Quran",1);nav("hadith","Hadith",2);nav("cards","Yaad",3);
    }
    private void nav(String icon,String title,int index){
        LinearLayout v=column(this);v.setGravity(Gravity.CENTER);pad(v,4,7);
        if(tab==index)v.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));
        Glass.Icon i=new Glass.Icon(this,icon);i.color=tab==index?MINT:MUTED;v.addView(i,new LinearLayout.LayoutParams(dp(this,22),dp(this,22)));
        TextView t=text(this,title,11,tab==index?INK:MUTED);t.setGravity(Gravity.CENTER);v.addView(t);
        v.setContentDescription(title);v.setSelected(tab==index);v.setFocusable(true);v.setMinimumHeight(dp(this,56));v.setOnClickListener(x->{tab=index;quietReader=false;if(index==1)reading=true;show();});
        LinearLayout.LayoutParams item=new LinearLayout.LayoutParams(0,-2,1);item.setMargins(dp(this,3),0,dp(this,3),0);bottom.addView(v,item);
    }
    private View iconButton(String icon,String description,Runnable action){
        FrameLayout f=new FrameLayout(this);f.setMinimumHeight(dp(this,48));f.setMinimumWidth(dp(this,48));f.setContentDescription(description);f.setFocusable(true);f.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));
        Glass.Icon view=new Glass.Icon(this,icon);FrameLayout.LayoutParams p=new FrameLayout.LayoutParams(dp(this,23),dp(this,23),Gravity.CENTER);f.addView(view,p);f.setOnClickListener(v->action.run());return f;
    }
    private void heading(String eyebrow,String title){
        LinearLayout label=column(this);TextView e=text(this,eyebrow,10,GOLD);e.setLetterSpacing(.18f);label.addView(e);
        TextView h=text(this,title,23,INK);h.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));label.addView(h);
        header.addView(label,new LinearLayout.LayoutParams(0,-2,1));header.addView(iconButton("settings","Reading settings",this::settings));
    }
    private LinearLayout scrollBody(){ScrollView sc=new ScrollView(this);sc.setFillViewport(false);sc.setClipToPadding(false);sc.setOverScrollMode(View.OVER_SCROLL_NEVER);body.addView(sc,new LinearLayout.LayoutParams(-1,-1));LinearLayout page=column(this);pad(page,20,12);sc.addView(page);return page;}
    private LinearLayout card(LinearLayout parent,Surface.Kind kind){LinearLayout v=column(this);pad(v,22,20);v.setBackground(new Surface(this,kind,highContrast));LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(this,16);parent.addView(v,lp);return v;}
    private TextView button(String title,Runnable click){return action(title,click,false);}
    private TextView primary(String title,Runnable click){return action(title,click,true);}
    private TextView action(String title,Runnable click,boolean primary){TextView b=text(this,title,14,primary?HIGH_INK:INK);b.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));b.setGravity(Gravity.CENTER);pad(b,16,13);b.setMinimumHeight(dp(this,48));b.setBackground(Glass.touch(this,primary?Surface.Kind.PRIMARY:Surface.Kind.BUTTON,highContrast));b.setFocusable(true);b.setOnClickListener(v->click.run());return b;}
    private TextView label(String text){TextView v=Glass.text(this,text,11,GOLD);v.setLetterSpacing(.12f);return v;}
    private void gap(LinearLayout v,int dp){View gap=new View(this);v.addView(gap,new LinearLayout.LayoutParams(1,Glass.dp(this,dp)));}
    private ArabicText arabic(String value,float size){ArabicText v=new ArabicText(this);v.setText(value);v.setTextSize(size);v.setReliefEnabled(!highContrast);v.setTypeface(arabicFont);v.setTextDirection(View.TEXT_DIRECTION_RTL);v.setGravity(Gravity.CENTER);v.setLineSpacing(dp(this,10),1.08f);return v;}
    private void caption(LinearLayout v,String value){TextView t=text(this,value,13,MUTED);t.setLineSpacing(dp(this,3),1.12f);v.addView(t);}
    private void toast(String value){if(!isDestroyed()&&!isFinishing())Toast.makeText(this,value,Toast.LENGTH_SHORT).show();}

    private void today(){
        heading("QURAN, AAPKE SAATH", "Aaris");LinearLayout page=scrollBody();
        TextView intro=text(this,"Thoda sa waqt.\nDil ke liye sukoon.",29,INK);intro.setTypeface(Typeface.create("serif",Typeface.NORMAL));page.addView(intro);gap(page,20);
        LinearLayout hero=card(page,Surface.Kind.HERO);hero.addView(label("JAHAN SE CHHODA THA"));gap(hero,18);hero.addView(arabic(content.ayah("Q:1:1").arabic,32));gap(hero,20);
        ContentStore.Surah s=content.surah(readerSurah);int resumeAyah=readingPosition==null?readerStart:RecallTarget.parse(readingPosition.anchorId).ayah;
        hero.addView(text(this,s.name,22,INK));caption(hero,"Ayah "+resumeAyah+" · Aapki pichhli jagah");gap(hero,18);hero.addView(primary("Quran kholein  →",()->{tab=1;reading=true;show();}));
        ambientCard(page);
        List<Recall.State> queue=dueQueue();
        LinearLayout practice=card(page,Surface.Kind.PANEL);practice.addView(label("AAJ KE ALFAAZ"));gap(practice,10);
        practice.addView(text(this,queue.isEmpty()?"Aaj koi jaldi nahi.":queue.size()+" chhoti yaad-dihaniyan",21,INK));gap(practice,6);
        caption(practice,queue.isEmpty()?"Padhte hue kisi lafz ya ayah ko yaad karne ke liye chun sakte hain.":"Sirf wahi alfaaz aur ayat jo aapne chune hain.");
        if(!queue.isEmpty()){gap(practice,16);practice.addView(button("Narmi se dohraayein",()->review(queue.get(0).target)));}
        LinearLayout saved=card(page,Surface.Kind.PANEL);saved.addView(text(this,"Nishaan lagayi hui ayat",18,INK));gap(saved,8);caption(saved,learning.bookmarks().size()+" bookmarks · Hamesha offline");gap(saved,12);saved.addView(button("Bookmarks kholein",this::bookmarks));
        TextView footer=text(this,"Aapki raftaar. Aapka safar.",12,MUTED);footer.setGravity(Gravity.CENTER);page.addView(footer);gap(page,18);
    }
    private void hadithLibrary(){
        heading("KUTUB AL-SITTAH", "Hadith");LinearLayout page=scrollBody();
        LinearLayout intro=card(page,Surface.Kind.HERO);intro.addView(label("CHHE KITAABEIN · EK JAGAH"));gap(intro,12);
        intro.addView(text(this,"Hadith padhein,\nsource ke saath.",27,INK));gap(intro,12);
        caption(intro,"Neeche ki kitaab browser mein Sunnah.com par khulegi. Internet chahiye; is APK mein offline Hadith pack abhi nahi hai.");
        EditText query=new EditText(this);query.setTextColor(INK);query.setHintTextColor(MUTED);query.setTextSize(16);query.setSingleLine(true);query.setHint("Arabic ya English phrase");query.setFilters(new InputFilter[]{new InputFilter.LengthFilter(512)});pad(query,14,10);query.setBackground(new Surface(this,Surface.Kind.BUTTON,highContrast));page.addView(query,new LinearLayout.LayoutParams(-1,dp(this,54)));gap(page,8);
        page.addView(primary("Sunnah.com par khojein  ↗",()->{String q=query.getText().toString().trim();if(q.isEmpty()){query.setError("Kuch alfaaz likhein");return;}openWebsite(new Uri.Builder().scheme("https").authority("sunnah.com").path("search").appendQueryParameter("q",q).build());}));gap(page,24);
        page.addView(label("APNI KITAAB CHUNEIN"));gap(page,12);
        String[][] books={{"Sahih al-Bukhari","صحيح البخاري","bukhari"},{"Sahih Muslim","صحيح مسلم","muslim"},{"Sunan Abi Dawud","سنن أبي داود","abudawud"},{"Jami at-Tirmidhi","جامع الترمذي","tirmidhi"},{"Sunan an-Nasa’i","سنن النسائي","nasai"},{"Sunan Ibn Majah","سنن ابن ماجه","ibnmajah"}};
        for(int index=0;index<books.length;index++){
            String[] book=books[index];LinearLayout c=card(page,Surface.Kind.PANEL);LinearLayout line=row(this);
            TextView number=text(this,String.format(Locale.ROOT,"%02d",index+1),13,GOLD);line.addView(number,new LinearLayout.LayoutParams(dp(this,36),-2));
            LinearLayout titles=column(this);titles.addView(text(this,book[0],18,INK));TextView ar=arabic(book[1],25);ar.setGravity(Gravity.LEFT);titles.addView(ar);line.addView(titles,new LinearLayout.LayoutParams(0,-2,1));TextView arrow=text(this,"↗",24,MINT);line.addView(arrow);c.addView(line);gap(c,10);caption(c,"Source par padhein · Online");
            c.setFocusable(true);c.setContentDescription(book[0]+", Sunnah.com par padhein, internet chahiye");c.setOnClickListener(v->openWebsite(Uri.parse("https://sunnah.com/"+book[2])));
        }
        caption(page,"Online search Sunnah.com ka hai. App ka offline evidence search aur verified-reference export filhaal Quran ke liye hai.");gap(page,16);
    }
    private void openWebsite(Uri uri){hideKeyboard();try{startActivity(new Intent(Intent.ACTION_VIEW,uri));}catch(ActivityNotFoundException e){toast("Is link ko kholne ke liye browser install karein");}}
    private int ambientItems(){int count=0;for(Recall.State state:learning.states().values())if(state.active&&content.hasRecallTarget(state.target)){ContentStore.Word w=content.word(state.target);if(w==null||w.hasGloss())count++;}return count;}
    private void ambientCard(LinearLayout page){
        LinearLayout c=card(page,Surface.Kind.PANEL);LinearLayout line=row(this);Glass.Icon icon=new Glass.Icon(this,"cards");icon.color=MINT;line.addView(icon,new LinearLayout.LayoutParams(dp(this,30),dp(this,30)));LinearLayout names=column(this);pad(names,12,0);names.addView(text(this,"Yaad, saath saath",20,INK));names.addView(text(this,app.ambientRunning?"Chalu · Har "+AmbientSettings.minutes(this)+" minute":"Doosri apps par chhota recall card",12,MUTED));line.addView(names,new LinearLayout.LayoutParams(0,-2,1));c.addView(line);gap(c,16);
        caption(c,"WhatsApp ho ya YouTube, aapke chune hue alfaaz aur ayat aap tak aa jaayein.");gap(c,16);c.addView(button(app.ambientRunning?"Timer aur session dekhein":"Apna timer set karein  →",this::ambientSettings));
    }
    private void ambientSettings(){
        LinearLayout page=sheet("Yaad, saath saath");Dialog dialog=activeDialog;
        caption(page,"Doosri apps ke upar ek chhota card. Band karenge to agla interval shuru hoga. Aaris khulne ya phone lock hone par timer rukega.");gap(page,18);
        TextView status=text(this,"",14,MINT);page.addView(status);
        Runnable refresh=new Runnable(){public void run(){if(isDestroyed()||activeDialog!=dialog||!dialog.isShowing())return;status.setText(app.ambientRunning?"● Chalu · "+AmbientSettings.minutes(MainActivity.this)+" minute ka timer":AmbientSettings.status(MainActivity.this));ui.postDelayed(this,1000);}};refresh.run();gap(page,18);
        page.addView(label("KITNE MINUTE BAAD?"));gap(page,8);
        EditText minutes=new EditText(this);minutes.setTextColor(INK);minutes.setTextSize(24);minutes.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);minutes.setFilters(new InputFilter[]{new InputFilter.LengthFilter(3)});minutes.setSingleLine(true);minutes.setText(""+AmbientSettings.minutes(this));minutes.setSelectAllOnFocus(true);minutes.setBackground(new Surface(this,Surface.Kind.BUTTON,highContrast));pad(minutes,16,8);page.addView(minutes,new LinearLayout.LayoutParams(-1,dp(this,58)));gap(page,10);
        LinearLayout presets=row(this);for(int value:new int[]{3,5,10,15}){TextView choice=button(value+" min",()->minutes.setText(""+value));pad(choice,6,13);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.rightMargin=dp(this,4);presets.addView(choice,p);}page.addView(presets);gap(page,12);
        caption(page,"1–120 minute. App badalne se timer reset nahi hoga.");gap(page,12);
        Switch due=new Switch(this);due.setText("Sirf jab revision baaki ho");due.setTextColor(INK);due.setChecked(AmbientSettings.dueOnly(this));due.setMinimumHeight(dp(this,52));page.addView(due);caption(page,"Band rakhein to har interval par chune hue items ki practice hogi.");gap(page,18);
        page.addView(button(ambientItems()+" chune hue items · Alfaaz / ayat chunein",this::chooseAmbientItems));gap(page,18);
        caption(page,Settings.canDrawOverlays(this)?"✓ Doosri apps par dikhane ki permission hai":"Shuru karne par Android ki “Display over other apps” setting khulegi. Aaris Quran ko allow karein.");gap(page,14);
        java.util.function.Consumer<Boolean> start=preview->{
            int value;try{value=Integer.parseInt(minutes.getText().toString());}catch(NumberFormatException e){value=0;}
            if(value<1||value>120){minutes.setError("1 se 120 minute chunein");return;}
            AmbientSettings.save(this,value,due.isChecked());
            if(ambientItems()==0){chooseAmbientItems();return;}
            previewAmbient=preview;pendingAmbient=true;beginAmbient();
        };
        page.addView(primary(app.ambientRunning?"Timer apply karein":"Shuru karein",()->start.accept(false)));gap(page,10);
        page.addView(button("10 second mein test card",()->start.accept(true)));gap(page,8);caption(page,"Test shuru karke WhatsApp ya YouTube kholein.");gap(page,14);
        if(app.ambientRunning){page.addView(button("Session band karein",()->{AmbientSettings.status(this,false,"Session band hai");stopService(new Intent(this,AmbientRecallService.class));dialog.dismiss();ui.postDelayed(this::show,250);}));gap(page,12);}
        caption(page,"Session notification se bhi band ho sakta hai. Phone session rok de to yahin se dobara shuru karein. Chats, videos aur app usage padha nahi jaata.");
    }
    private void chooseAmbientItems(){
        LinearLayout page=sheet("Card mein kya aaye?");caption(page,"Sirf aapke chune hue alfaaz, ayat aur hisse dikhte hain. Neeche apni maujooda ayah se chunein.");gap(page,16);
        Ayah a=content.ayah(readingPosition==null?"Q:"+readerSurah+":"+readerStart:readingPosition.anchorId);if(a==null)return;
        page.addView(label(content.surah(a.surah).name+" · "+a.surah+":"+a.number));gap(page,10);
        page.addView(button("Yeh poori ayah yaad karaayein",()->{enroll(a.id,a.id);ambientSettings();}));gap(page,16);
        int count=0;for(ContentStore.Word word:content.words(a.id))if(word.hasGloss()){
            if(count++==8)break;LinearLayout row=Glass.row(this);pad(row,8,10);TextView ar=arabic(word.arabic,30);row.addView(ar,new LinearLayout.LayoutParams(0,-2,1));
            Recall.State memory=learning.states().get(word.id);TextView meaning=text(this,word.gloss(language)+(memory!=null&&memory.active?" ✓":"  +"),15,INK);row.addView(meaning,new LinearLayout.LayoutParams(0,-2,1));row.setBackground(Glass.touch(this,Surface.Kind.BUTTON,highContrast));row.setFocusable(true);row.setOnClickListener(v->{enroll(word.id,word.ayahId);meaning.setText(word.gloss(language)+" ✓");});page.addView(row);gap(page,8);
        }
        gap(page,12);page.addView(primary("Timer par waapas",this::ambientSettings));gap(page,10);page.addView(button("Doosri ayah se chunein",()->{activeDialog.dismiss();tab=1;reading=false;show();}));
    }
    private void beginAmbient(){
        if(!pendingAmbient||isFinishing()||isDestroyed())return;
        // Permission callbacks may precede onResume; API 31+ requires a visible user launch.
        if(!resumed){ambientResumePending=true;return;}
        if(!Settings.canDrawOverlays(this)){
            Intent permission=new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:"+getPackageName()));
            try{startActivityForResult(permission,OVERLAY_PERMISSION);}catch(ActivityNotFoundException e){pendingAmbient=false;toast("Is phone par overlay permission ki setting nahi mili");}return;
        }
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED&&!AmbientSettings.askedNotifications(this)){
            AmbientSettings.notificationsAsked(this);requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},NOTIFICATIONS);return;
        }
        if(learning==null){app.ready(this::beginAmbient);return;}
        pendingAmbient=false;if(ambientItems()==0){chooseAmbientItems();return;}
        try{startForegroundService(new Intent(this,AmbientRecallService.class).putExtra(AmbientRecallService.PREVIEW,previewAmbient));if(activeDialog!=null)activeDialog.dismiss();toast(previewAmbient?"Ab doosri app kholein · 10 second mein test card":"Session shuru ho raha hai · Ab doosri app khol sakte hain");ui.postDelayed(this::show,300);}
        catch(RuntimeException e){AmbientSettings.status(this,false,"Session shuru nahi hua. Dobara try karein.");toast("Session shuru nahi hua. App khol kar dobara try karein.");}
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(request==NOTIFICATIONS)beginAmbient();}
    private void library(){
        heading("114 SURAHS · OFFLINE", "Quran al-Kareem");LinearLayout page=scrollBody();
        EditText filter=new EditText(this);filter.setSingleLine(true);filter.setTextColor(INK);filter.setHintTextColor(MUTED);filter.setHint("Surah ka naam ya number");filter.setTextSize(15);pad(filter,14,8);filter.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));page.addView(filter,new LinearLayout.LayoutParams(-1,dp(this,52)));gap(page,16);
        LinearLayout list=column(this);page.addView(list);
        Runnable fill=()->{list.removeAllViews();String q=Arabic.tolerant(filter.getText().toString());for(ContentStore.Surah s:content.surahs){
            String searchable=Arabic.tolerant(s.name+" "+s.arabic+" "+s.meaning+" "+s.id);
            if(!q.isEmpty()&&!searchable.contains(q))continue;
            LinearLayout row=Glass.row(this);pad(row,16,14);row.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));
            TextView number=text(this,String.format(Locale.ROOT,"%02d",s.id),13,GOLD);row.addView(number,new LinearLayout.LayoutParams(dp(this,38),-2));
            LinearLayout names=column(this);names.addView(text(this,s.name,17,INK));names.addView(text(this,s.count+" ayat · "+s.meaning,11,MUTED));row.addView(names,new LinearLayout.LayoutParams(0,-2,1));
            TextView ar=arabic(s.arabic,24);row.addView(ar,new LinearLayout.LayoutParams(-2,-2));row.setContentDescription(s.name+", "+s.count+" ayat");row.setFocusable(true);row.setOnClickListener(v->open(s.id,1));
            LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(this,10);list.addView(row,lp);
        }};filter.addTextChangedListener(watcher(fill));fill.run();
    }
    private void open(int surah,int ayah){readerScroll=null;readerVerses.clear();readerSurah=Math.max(1,Math.min(114,surah));readerStart=Math.max(1,Math.min(content.surah(readerSurah).count,ayah));reading=true;tab=1;String id="Q:"+readerSurah+":"+readerStart;readingPosition=new ReadingPosition(id,id,0,0,true);learning.set("position",id);learning.set("reader_anchor",readingPosition.encode());hideKeyboard();show();}
    private void reader(){
        ContentStore.Surah s=content.surah(readerSurah);
        header.addView(iconButton("back","Surah ki list",()->{reading=false;show();}));
        LinearLayout titles=column(this);pad(titles,12,0);titles.addView(label("AARIS · OFFLINE"));titles.addView(text(this,"Quran",23,INK));header.addView(titles,new LinearLayout.LayoutParams(0,-2,1));
        header.addView(iconButton("search","Quran mein khojein",this::searchScreen));
        LinearLayout page=scrollBody();pad(page,16,8);readerScroll=(ScrollView)page.getParent();renderedPage="Q:"+readerSurah+":"+readerStart;
        readerScroll.setOnScrollChangeListener((View v,int x,int y,int oldX,int oldY)->{if(y!=oldY)hidePeek();});
        LinearLayout tools=row(this);TextView surahs=button("Surahs  ↓",()->{reading=false;show();});tools.addView(surahs,new LinearLayout.LayoutParams(0,-2,1));TextView readingStyle=button("Aa · Reading",this::settings);LinearLayout.LayoutParams styleSize=new LinearLayout.LayoutParams(0,-2,1);styleSize.leftMargin=dp(this,8);tools.addView(readingStyle,styleSize);page.addView(tools);gap(page,14);
        TextView name=arabic(s.arabic,28);page.addView(name,new LinearLayout.LayoutParams(-1,-2));
        TextView latin=text(this,s.name,24,INK);latin.setGravity(Gravity.CENTER);latin.setTypeface(Typeface.create("serif",Typeface.NORMAL));page.addView(latin);
        TextView sub=text(this,s.meaning+"  ·  "+s.count+" ayat",12,MUTED);sub.setGravity(Gravity.CENTER);page.addView(sub);gap(page,10);
        TextView interaction=text(this,"Lafz par tap karein · Meaning dekhein",12,MUTED);interaction.setGravity(Gravity.CENTER);page.addView(interaction);gap(page,22);
        List<Ayah> ayahs=content.page(readerSurah,readerStart,8);
        for(Ayah a:ayahs){
            LinearLayout panel=card(page,Surface.Kind.MUSHAF);
            LinearLayout bar=row(this);TextView reference=text(this,String.format(Locale.ROOT,"%d : %d",a.surah,a.number),12,MUTED);bar.addView(reference,new LinearLayout.LayoutParams(0,-2,1));
            View menu=iconButton("more","Ayah "+a.number+": bookmark, meaning, yaad aur share",()->ayahActions(a));bar.addView(menu,new LinearLayout.LayoutParams(dp(this,48),dp(this,48)));panel.addView(bar);gap(panel,8);
            List<ContentStore.Word> words=content.words(a.id);
            QuranText verse=new QuranText(this,arabicFont,a,words,arabicSize,this::tapWord);verse.setReliefEnabled(!highContrast);readerVerses.put(a.id,verse);panel.addView(verse,new LinearLayout.LayoutParams(-1,-2));
            for(ContentStore.Word w:words){Recall.State memory=learning.states().get(w.id);if(memory!=null&&memory.active&&memory.reviews>0&&memory.due<=System.currentTimeMillis()){
                gap(panel,12);TextView recall=button("Chuna hua lafz · Meaning yaad karein",()->review(w.id));panel.addView(recall);break;
            }}
        }
        LinearLayout pager=row(this);
        TextView previous=button("← Pichhli",()->{if(readerStart>1)open(readerSurah,Math.max(1,readerStart-8));else if(readerSurah>1)open(readerSurah-1,Math.max(1,content.surah(readerSurah-1).count-7));});
        pager.addView(previous,new LinearLayout.LayoutParams(0,-2,1));
        TextView counter=text(this,readerStart+"–"+Math.min(s.count,readerStart+7)+" / "+s.count,12,MUTED);counter.setGravity(Gravity.CENTER);pager.addView(counter,new LinearLayout.LayoutParams(0,-2,1));
        TextView next=button("Agli →",()->{if(readerStart+8<=s.count)open(readerSurah,readerStart+8);else if(readerSurah<114)open(readerSurah+1,1);});pager.addView(next,new LinearLayout.LayoutParams(0,-2,1));page.addView(pager);gap(page,12);
        page.addView(button("Yaad saath rahe · Overlay timer",this::ambientSettings));gap(page,12);
        TextView source=text(this,"Tanzil Project · Uthmani 1.1",11,MUTED);source.setGravity(Gravity.CENTER);source.setOnClickListener(v->sources());page.addView(source);gap(page,12);
        if(quietReader){header.setVisibility(View.GONE);bottom.setVisibility(View.GONE);page.addView(button("Controls dikhaayein",()->{quietReader=false;show();}));}
        restoreReaderPosition();
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
    private void hidePeek(){selectedWordId="";if(selectedVerse!=null){selectedVerse.select(null);selectedVerse=null;}if(overlay!=null)overlay.removeAllViews();}
    private void tapWord(ContentStore.Word word,QuranText owner){
        if(word.id.equals(selectedWordId)){wordDetails(word);return;}
        hidePeek();selectedWordId=word.id;selectedVerse=owner;owner.select(word);learning.event(word.id,Recall.Kind.PEEK,word.ayahId);
        LinearLayout peek=column(this);pad(peek,20,16);peek.setBackground(new Surface(this,Surface.Kind.SHEET,true));
        LinearLayout top=row(this);TextView ar=arabic(word.arabic,30);ar.setGravity(Gravity.RIGHT);top.addView(ar,new LinearLayout.LayoutParams(0,-2,1));top.addView(iconButton("close","Meaning band karein",this::hidePeek));peek.addView(top);
        TextView meaning=text(this,word.gloss(language),18,INK);if(language.equals("ur"))meaning.setTextDirection(View.TEXT_DIRECTION_RTL);peek.addView(meaning);
        if(word.transliteration!=null){gap(peek,4);caption(peek,word.transliteration);}
        gap(peek,10);LinearLayout actions=row(this);actions.addView(button("Aur samjhein",()->wordDetails(word)),new LinearLayout.LayoutParams(0,-2,1));
        if(word.hasGloss()){TextView remember=button("Yaad karaayein",()->enroll(word.id,word.ayahId));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.leftMargin=dp(this,8);actions.addView(remember,p);}peek.addView(actions);
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
    private LinearLayout sheet(String title){
        hidePeek();
        if(activeDialog!=null)activeDialog.dismiss();
        Dialog dialog=new Dialog(this);activeDialog=dialog;dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout outer=column(this);pad(outer,22,18);outer.setBackground(new Surface(this,Surface.Kind.SHEET,true));
        outer.setOnApplyWindowInsetsListener((view,insets)->{
            int left=0,right=0,bottom=0;
            if(Build.VERSION.SDK_INT>=30){android.graphics.Insets safe=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());left=safe.left;right=safe.right;bottom=safe.bottom;}
            else{left=insets.getSystemWindowInsetLeft();right=insets.getSystemWindowInsetRight();bottom=insets.getSystemWindowInsetBottom();}
            view.setPadding(dp(this,22)+left,dp(this,18),dp(this,22)+right,dp(this,18)+bottom);return insets;
        });
        LinearLayout bar=row(this);TextView heading=text(this,title,22,INK);bar.addView(heading,new LinearLayout.LayoutParams(0,-2,1));bar.addView(iconButton("close","Band karein",dialog::dismiss));outer.addView(bar);gap(outer,12);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(false);LinearLayout inside=column(this);scroll.addView(inside);outer.addView(scroll,new LinearLayout.LayoutParams(-1,-2));
        dialog.setContentView(outer);Window w=dialog.getWindow();if(w!=null){w.setBackgroundDrawableResource(android.R.color.transparent);w.setDimAmount(.4f);w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);w.setGravity(Gravity.BOTTOM);w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);}
        dialog.show();if(w!=null){w.setLayout(-1,-2);int max=(int)(getResources().getDisplayMetrics().heightPixels*.82);outer.post(()->{if(outer.getHeight()>max)w.setLayout(-1,max);});}
        return inside;
    }
    private void wordDetails(ContentStore.Word word){
        learning.event(word.id,Recall.Kind.DEEP,word.ayahId);hidePeek();
        LinearLayout page=sheet("Lafz ki samajh");page.addView(arabic(word.arabic,40));gap(page,10);
        page.addView(text(this,word.gloss(language),22,INK));if(word.transliteration!=null)caption(page,word.transliteration);
        gap(page,16);caption(page,"Is ayah ka source word meaning. Root ya doosre context ka matlab apne-aap is se ek nahi maana jaata.");
        gap(page,16);caption(page,"Quran "+word.ayahId.replace("Q:","")+" · Word "+word.position+"\nSource: Data Quran / Quran.com");
        if(word.hasGloss()) {
            gap(page,16);page.addView(button("Yeh lafz yaad karaayein",()->enroll(word.id,word.ayahId)));
            int count=content.occurrences(word.surface);gap(page,16);page.addView(label("DOOSRE CONTEXTS"));caption(page,"Isi search form ke "+count+" occurrences. Memory scores alag rakhe jaate hain.");
            for(ContentStore.Word other:content.related(word)) {
                gap(page,8);page.addView(button(other.ayahId.replace("Q:","")+" mein dekhein",()->{if(activeDialog!=null)activeDialog.dismiss();Ayah a=content.ayah(other.ayahId);open(a.surah,a.number);}));
            }
        }
        gap(page,16);page.addView(button("Apna note",()->editNote(word.id)));gap(page,12);
    }
    private void enroll(String target,String context){
        Recall.State existing=learning.states().get(target);
        if(existing==null||!existing.active)learning.event(target,Recall.Kind.ENROLL,context);
        toast("Yaad karne ke liye save ho gaya");
    }
    private void ayahActions(Ayah a){
        LinearLayout page=sheet(content.surah(a.surah).name+" · "+a.number);
        page.addView(button(learning.bookmarked(a.id)?"Bookmark hataayein":"Bookmark karein",()->{learning.toggleBookmark(a.id);toast(learning.bookmarked(a.id)?"Bookmark save hua":"Bookmark hata diya");activeDialog.dismiss();}));gap(page,10);
        page.addView(button("Yeh ayah yaad karaayein",()->{enroll(a.id,a.id);activeDialog.dismiss();}));gap(page,10);
        page.addView(button("Chhota hissa yaad karaayein",()->choosePhrase(a)));gap(page,10);
        if(a.number<content.surah(a.surah).count){page.addView(button("Agli ayah se jod yaad karein",()->review(RecallTarget.transition(a.id,a.number+1))));gap(page,10);}
        page.addView(button("Word meanings ki list",()->wordList(a)));gap(page,10);
        page.addView(button("Apna note",()->editNote(a.id)));gap(page,10);
        page.addView(button("Evidence mein chunein",()->{if(selectedEvidence.size()>=50&&!selectedEvidence.contains(a.id)){toast("Ek bundle mein 50 ayat tak");return;}selectedEvidence.add(a.id);selectionTrace.put(a.id,selectionOrigin("READER_SELECTION"));toast("Evidence selection: "+selectedEvidence.size());activeDialog.dismiss();}));gap(page,10);
        page.addView(button("Ayah share karein",()->shareText(a.arabic+"\n["+a.id+"]\nTanzil Project · https://tanzil.net/")));gap(page,10);
        page.addView(button("Is ayah se jaari rakhein",()->{activeDialog.dismiss();open(a.surah,a.number);}));
    }
    private void wordList(Ayah a){
        LinearLayout page=sheet("Lafz ba lafz · "+a.surah+":"+a.number);
        caption(page,"Source word meanings; yeh poori ayah ka tarjuma ya tafsir nahi hai.");gap(page,12);
        for(ContentStore.Word word:content.words(a.id)) {
            LinearLayout row=Glass.row(this);pad(row,4,10);TextView ar=arabic(word.arabic,28);row.addView(ar,new LinearLayout.LayoutParams(0,-2,1));TextView gloss=text(this,word.gloss(language),16,INK);row.addView(gloss,new LinearLayout.LayoutParams(0,-2,1));row.setFocusable(true);row.setOnClickListener(v->wordDetails(word));page.addView(row);
        }
    }
    private void editNote(String target){
        LinearLayout page=sheet("Apna note");caption(page,"Yeh aapka private note hai; Quran ke source ka hissa nahi.");
        EditText edit=new EditText(this);edit.setTextColor(INK);edit.setHintTextColor(MUTED);edit.setHint("Apni samajh ya sawaal likhein…");edit.setText(learning.note(target));edit.setMinLines(4);edit.setMaxLines(8);edit.setFilters(new InputFilter[]{new InputFilter.LengthFilter(8000)});page.addView(edit);gap(page,12);
        page.addView(button("Note save karein",()->{learning.note(target,edit.getText().toString());hideKeyboard();activeDialog.dismiss();toast("Note save hua");}));
    }
    private void bookmarks(){
        LinearLayout page=sheet("Aapke bookmarks");List<String> ids=learning.bookmarks();
        if(ids.isEmpty())caption(page,"Ayah ke ⋯ menu se bookmark laga sakte hain.");
        for(String id:ids){Ayah a=content.ayah(id);if(a==null)continue;page.addView(button(content.surah(a.surah).name+" · "+a.number,()->{activeDialog.dismiss();open(a.surah,a.number);}));gap(page,10);}
    }
    private void map(){
        heading("THODA, LEKIN KAAM KA", "Aapki yaad");LinearLayout page=scrollBody();ambientCard(page);Map<String,Recall.State> states=learning.states();
        int active=0,reviews=0;for(Recall.State state:states.values()){if(state.active)active++;reviews+=state.reviews;}
        LinearLayout hero=card(page,Surface.Kind.HERO);hero.addView(text(this,"Jo seekha, saath rahe.",25,INK));gap(hero,8);caption(hero,"Aapke chune hue alfaaz, hisse aur ayat.");gap(hero,20);
        LinearLayout metrics=row(this);LinearLayout left=column(this);left.addView(text(this,""+active,32,GOLD));caption(left,"Chune hue items");metrics.addView(left,new LinearLayout.LayoutParams(0,-2,1));LinearLayout right=column(this);right.addView(text(this,""+reviews,32,MINT));caption(right,"Khud kiye recalls");metrics.addView(right,new LinearLayout.LayoutParams(0,-2,1));hero.addView(metrics);
        List<Recall.State> due=dueQueue();
        if(!due.isEmpty()){page.addView(button("Aaj ki yaad-dihani kholein",()->review(due.get(0).target)));gap(page,16);}
        if(active==0){LinearLayout empty=card(page,Surface.Kind.PANEL);empty.addView(text(this,"Pehla lafz chunein",20,INK));gap(empty,8);caption(empty,"Reader mein lafz par tap karke “Yaad karaayein” chunein, ya yahin se shuru karein.");gap(empty,14);empty.addView(primary("Alfaaz chunein",this::chooseAmbientItems));}
        for(Recall.State state:states.values())if(state.active){
            ContentStore.Word w=content.word(state.target);Ayah a=content.contextFor(state.target);if(a==null||!content.hasRecallTarget(state.target))continue;
            LinearLayout c=card(page,Surface.Kind.PANEL);AyahTransition transition=content.transition(state.target);
            c.addView(text(this,content.surah(a.surah).name+" · "+a.number+(transition==null?"":" → "+transition.to.number+" · Ayaton ka jod"),13,GOLD));
            c.addView(arabic(transition!=null?transition.ending.text:w==null?firstWords(content.recallText(state.target),5):w.arabic,28));caption(c,state.label()+" · "+dueLabel(state.due));gap(c,10);
            LinearLayout buttons=row(this);buttons.addView(button("Dohraayein",()->review(state.target)),new LinearLayout.LayoutParams(0,-2,1));TextView pause=button("Rok dein",()->{learning.event(state.target,Recall.Kind.PAUSE,a.id);show();});LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.leftMargin=dp(this,8);buttons.addView(pause,p);c.addView(buttons);
        }
        page.addView(button("Learning ka backup",this::backup));gap(page,16);
    }
    private String dueLabel(long due){long days=(due-System.currentTimeMillis())/Recall.DAY;return due<=System.currentTimeMillis()?"Aaj dekh sakte hain":days<1?"Jald dobara":days+" din baad";}
    private String firstWords(String text,int n){String[] a=text.split("\\s+");return String.join(" ",Arrays.copyOfRange(a,0,Math.min(n,a.length)));}
    private List<Recall.State> dueQueue(){
        captureReaderPosition();
        Map<String,Recall.State> states=learning.states();
        String from=readingPosition==null?"Q:"+readerSurah+":"+readerStart:readingPosition.anchorId;
        return Recall.queue(states.values(),content.upcoming(states.values(),from),System.currentTimeMillis(),5);
    }
    private void choosePhrase(Ayah a){
        List<ContentStore.Word> words=new ArrayList<>();for(ContentStore.Word w:content.words(a.id))if(w.position>0)words.add(w);
        if(words.size()<2){toast("Is ayah ko poora yaad karne ke liye chunein");return;}
        LinearLayout page=sheet("Sirf zaroori hissa");caption(page,"Jahan atakte hain, us hisse ka pehla aur aakhri lafz chunein. Baaki ayah dobara chunna zaroori nahi.");gap(page,16);
        List<String> names=new ArrayList<>();for(ContentStore.Word w:words)names.add(w.position+" · "+w.arabic);
        ArrayAdapter<String> adapter=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,names);
        page.addView(label("PEHLA LAFZ"));Spinner first=new Spinner(this);first.setAdapter(adapter);page.addView(first);gap(page,12);
        page.addView(label("AAKHRI LAFZ"));Spinner last=new Spinner(this);last.setAdapter(adapter);last.setSelection(Math.min(2,words.size()-1));page.addView(last);gap(page,18);
        TextView preview=arabic("",32);page.addView(preview);gap(page,16);
        Runnable update=()->{int from=first.getSelectedItemPosition(),to=last.getSelectedItemPosition();
            preview.setText(to>from?content.recallText(RecallTarget.phrase(a.id,words.get(from).position,words.get(to).position)):"Kam se kam do lagataar alfaaz chunein");};
        AdapterView.OnItemSelectedListener listener=new AdapterView.OnItemSelectedListener(){public void onItemSelected(AdapterView<?> p,View v,int pos,long id){update.run();}public void onNothingSelected(AdapterView<?> p){}};
        first.setOnItemSelectedListener(listener);last.setOnItemSelectedListener(listener);update.run();
        page.addView(button("Yeh hissa yaad karaayein",()->{
            int from=first.getSelectedItemPosition(),to=last.getSelectedItemPosition();if(to<=from){toast("Aakhri lafz pehle lafz ke baad chunein");return;}
            String target=RecallTarget.phrase(a.id,words.get(from).position,words.get(to).position);enroll(target,a.id);review(target);
        }));caption(page,"Yeh source ayah ka chuna hua hissa hai; nayi ayah ya tarjuma nahi.");
    }
    private void review(String target){
        RecallTarget identity=RecallTarget.parse(target);if(identity==null)return;
        if(identity.kind==RecallTarget.Kind.TRANSITION){reviewTransition(content.transition(target));return;}
        ContentStore.Word word=content.word(target);Ayah a=content.contextFor(target);String source=content.recallText(target);
        if(a==null||source==null)return;if(word!=null&&!word.hasGloss()){toast("Source meaning abhi nahi hai");return;}
        Recall.State state=learning.states().get(target);if(state==null||!state.active){enroll(target,a.id);state=learning.states().get(target);}
        boolean phrase=identity.kind==RecallTarget.Kind.PHRASE;
        LinearLayout page=sheet(phrase?"Sirf yeh hissa yaad karein":"Narmi se yaad karein");caption(page,content.surah(a.surah).name+" · Ayah "+a.number+(phrase?" · Chuna hua hissa":""));gap(page,12);
        boolean encoding=word==null&&state.reviews==0;
        String cue=word!=null?source:state.successes>=3?"Apne zehan se yaad karein":firstWords(source,state.successes>=2?1:2)+" …";
        TextView prompt=arabic(encoding?source:cue,word==null?28:40);page.addView(prompt);gap(page,12);
        caption(page,word!=null?"Is ayah ke context mein iska meaning yaad karein.":encoding?"Pehle aaram se padhein. Phir text chhupa kar yaad karein.":"Yeh sirf yaad karne ka ishara hai. Reveal par asal source dekhein.");
        LinearLayout answer=column(this);answer.setVisibility(View.GONE);page.addView(answer);gap(page,14);
        TextView reveal=button(word==null?"Asal text dekhein":"Meaning dekhein",()->{});page.addView(reveal);
        if(encoding){reveal.setVisibility(View.GONE);TextView hide=button("Chhupa kar yaad karein",()->{});page.addView(hide);hide.setOnClickListener(v->{prompt.setText(cue);hide.setVisibility(View.GONE);reveal.setVisibility(View.VISIBLE);});}
        reveal.setOnClickListener(v->{
            if(answer.getVisibility()==View.VISIBLE)return;
            learning.event(target,Recall.Kind.REVEAL,a.id);answer.setVisibility(View.VISIBLE);reveal.setVisibility(View.GONE);
            if(word==null)answer.addView(arabic(source,arabicSize));else{answer.addView(text(this,word.gloss(language),24,INK));gap(answer,12);answer.addView(arabic(a.arabic,23));}
            recallRatings(answer,target,a.id);
        });
    }
    private void reviewTransition(AyahTransition edge){
        if(edge==null){toast("Yeh ayaton ka jod source mein nahi mila");return;}
        Recall.State state=learning.states().get(edge.id);
        if(state==null||!state.active){enroll(edge.id,edge.from.id);state=learning.states().get(edge.id);}
        boolean first=state.reviews==0;
        LinearLayout page=sheet("Ayaton ka jod");
        caption(page,"Is aakhri hisse ke baad agli ayah ka aaghaz yaad karein. Is jod ki yaad-dihani alag rahegi.");gap(page,16);
        page.addView(label(edge.from.surah+":"+edge.from.number+" · AAKHRI HISSA"));
        page.addView(arabic(edge.ending.text,arabicSize));gap(page,18);
        page.addView(label(edge.to.surah+":"+edge.to.number+" · AGLI AYAH KA AAGHAZ"));
        TextView opening=arabic(edge.opening.text,arabicSize);page.addView(opening);
        opening.setVisibility(first?View.VISIBLE:View.GONE);
        TextView instruction=text(this,first?"Pehle dono hisse padhein. Phir agli ayah ka aaghaz chhupa dein.":"Aage kaise shuru hota hai? Zehan se yaad karein.",15,MUTED);page.addView(instruction);gap(page,14);
        LinearLayout answer=column(this);page.addView(answer);
        TextView reveal=button("Agli ayah ka aaghaz dekhein",()->{});page.addView(reveal);
        if(first){reveal.setVisibility(View.GONE);TextView hide=button("Aaghaz chhupa kar yaad karein",()->{});page.addView(hide);
            hide.setOnClickListener(v->{opening.setVisibility(View.GONE);hide.setVisibility(View.GONE);reveal.setVisibility(View.VISIBLE);instruction.setText("Aage kaise shuru hota hai? Zehan se yaad karein.");});}
        reveal.setOnClickListener(v->{
            if(reveal.getVisibility()!=View.VISIBLE)return;
            learning.event(edge.id,Recall.Kind.REVEAL,edge.from.id);opening.setVisibility(View.VISIBLE);reveal.setVisibility(View.GONE);instruction.setVisibility(View.GONE);
            recallRatings(answer,edge.id,edge.from.id);gap(answer,12);
            answer.addView(button("Dono poori ayat dekhein",()->{
                LinearLayout context=sheet("Dono ayat ka context");
                for(Ayah ayah:new Ayah[]{edge.from,edge.to}){context.addView(label(ayah.surah+":"+ayah.number));context.addView(arabic(ayah.arabic,arabicSize));gap(context,20);}
                context.addView(button("Jod ki practice par waapas",()->review(edge.id)));
            }));
        });
    }
    private void recallRatings(LinearLayout answer,String target,String context){
        gap(answer,16);caption(answer,"Sirf dekh lena successful recall nahi hai. Reveal se pehle kitna yaad tha?");gap(answer,14);
        String ratingId=UUID.randomUUID().toString();boolean[] rated={false};Dialog reviewDialog=activeDialog;
        String[] labels={"Bhool gaya","Mushkil tha","Yaad tha","Aasaan tha"};Recall.Kind[] ratings={Recall.Kind.AGAIN,Recall.Kind.HARD,Recall.Kind.GOOD,Recall.Kind.EASY};
        for(int i=0;i<labels.length;i++){Recall.Kind rating=ratings[i];answer.addView(button(labels[i],()->{
            if(rated[0])return;rated[0]=true;learning.event(ratingId,target,rating,context);reviewDialog.dismiss();
            List<Recall.State> q=dueQueue();
            if(q.isEmpty()){toast("Aaj ke liye itna kaafi hai");show();}else review(q.get(0).target);
        }));gap(answer,8);}
    }

    private TextWatcher watcher(Runnable action){return new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){action.run();}public void afterTextChanged(Editable e){}};}
    private void searchScreen(){
        captureReaderPosition();readerScroll=null;restoringReader=null;readerVerses.clear();evidenceControls.clear();hidePeek();searching=true;layout.removeAllViews();
        header=row(this);pad(header,16,10);layout.addView(header);header.addView(iconButton("back","Reader par waapas",this::show));
        TextView title=text(this,"Quran mein khojein",22,INK);header.addView(title,new LinearLayout.LayoutParams(0,-2,1));header.addView(iconButton("share","Research aur evidence",this::research));
        LinearLayout fieldContainer=column(this);pad(fieldContainer,20,0);layout.addView(fieldContainer);
        EditText query=new EditText(this);query.setTextColor(INK);query.setHintTextColor(MUTED);query.setTextSize(17);query.setHint("Arabic, Hindi, Urdu… ya 2:255");query.setMinLines(1);query.setMaxLines(4);query.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE);query.setFilters(new InputFilter[]{new InputFilter.LengthFilter(4096)});pad(query,16,8);query.setBackground(new Surface(this,Surface.Kind.PANEL,highContrast));fieldContainer.addView(query,new LinearLayout.LayoutParams(-1,-2));
        gap(fieldContainer,12);LinearLayout chips=row(this);chips.addView(button("Quran · Offline",()->{}));TextView hadith=button("Hadith ↗",()->{tab=2;quietReader=false;show();});LinearLayout.LayoutParams hp=new LinearLayout.LayoutParams(-2,-2);hp.leftMargin=dp(this,8);chips.addView(hadith,hp);fieldContainer.addView(chips);gap(fieldContainer,12);
        body=column(this);layout.addView(body,new LinearLayout.LayoutParams(-1,0,1));LinearLayout results=scrollBody();
        TextView status=text(this,"Ayah reference, Arabic phrase ya source word meaning se khojein.",14,MUTED);results.addView(status);gap(results,16);
        LinearLayout list=column(this);results.addView(list);
        Runnable run=()->{
            searchQuery=query.getText().toString();int generation=searchGeneration.incrementAndGet();if(searchTask!=null)searchTask.cancel(true);
            if(debounce!=null)ui.removeCallbacks(debounce);
            String q=searchQuery.trim();if(q.isEmpty()){list.removeAllViews();evidenceControls.clear();status.setText("Ayah reference, Arabic phrase ya source word meaning se khojein.");return;}
            status.setText("Offline search…");
            debounce=()->{searchTask=app.searchWorker.submit(()->{
                try {
                    if(app.search==null)app.search=content.buildSearch();SearchEngine.Response response=app.search.search(q,30);
                    ui.post(()->{if(isDestroyed()||!searching||searchGeneration.get()!=generation)return;
                        list.removeAllViews();evidenceControls.clear();status.setText(response.intent.equals("QUERY_LIMIT")?"Ek baar mein 8 chhoti search lines tak likhein; lambi query ko chhota karein.":response.fragments!=null?"Poora Arabic phrase nahi mila. Alag source hisse neeche dekhein.":response.results.isEmpty()?"Bharosemand match nahi mila. Chhota phrase ya doosri spelling try karein.":response.results.size()+" results · Sirf local Quran source");
                        if(response.fragments!=null)showFragments(list,response,query);
                        for(SearchEngine.Result result:response.results){
                            LinearLayout c=card(list,Surface.Kind.PANEL);c.addView(label(result.strength==SearchEngine.Strength.STRONG_TEXT?"STRONG TEXT MATCH":"RELATED WORD MEANING / TEXT"));gap(c,8);
                            Ayah a=result.ayah;c.addView(text(MainActivity.this,content.surah(a.surah).name+" · "+a.surah+":"+a.number,18,INK));gap(c,10);TextView text=arabic(a.arabic,25);c.addView(text);gap(c,12);
                            caption(c,String.join(" · ",result.reasons));gap(c,14);c.addView(evidenceActions(a,retrievalTrace(response,result)));
                        }
                    });
                }catch(CancellationException ignored){}catch(Exception e){ui.post(()->{if(!isDestroyed()&&searchGeneration.get()==generation)status.setText("Search abhi khul nahi saka. Dobara try karein.");});}
            });};ui.postDelayed(debounce,220);
        };
        query.addTextChangedListener(watcher(run));query.setText(searchQuery);query.setSelection(query.length());
    }
    private LinearLayout evidenceActions(Ayah ayah,JSONObject trace){
        LinearLayout actions=row(this);actions.addView(button("Ayah kholein",()->open(ayah.surah,ayah.number)),new LinearLayout.LayoutParams(0,-2,1));
        TextView select=button(selectedEvidence.contains(ayah.id)?"Chuna hua ✓":"Evidence +",()->{});
        evidenceControls.computeIfAbsent(ayah.id,k->new ArrayList<>()).add(select);
        select.setOnClickListener(v->{
            if(selectedEvidence.contains(ayah.id)){selectedEvidence.remove(ayah.id);selectionTrace.remove(ayah.id);select.setText("Evidence +");}
            else if(selectedEvidence.size()<50){selectedEvidence.add(ayah.id);selectionTrace.put(ayah.id,trace);select.setText("Chuna hua ✓");}
            else toast("Ek bundle mein 50 ayat tak");
            refreshEvidenceControls();
        });
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.leftMargin=dp(this,8);actions.addView(select,p);return actions;
    }
    private void refreshEvidenceControls(){for(Map.Entry<String,List<TextView>> entry:evidenceControls.entrySet())for(TextView view:entry.getValue())view.setText(selectedEvidence.contains(entry.getKey())?"Chuna hua ✓":"Evidence +");}
    private void showFragments(LinearLayout list,SearchEngine.Response response,EditText query){
        FragmentSearch.Report report=response.fragments;LinearLayout summary=card(list,Surface.Kind.HERO);
        summary.addView(label("ALAG HISSON KE SOURCES"));gap(summary,10);
        caption(summary,report.matchedTokens+" / "+report.totalTokens+" alfaaz lagataar source hisson mein mile. Inhein jod kar ek ayah ya ek verified quote na samjhein.");
        if(!report.unmatched.isEmpty()){
            gap(summary,14);summary.addView(label("YEH HISSA NAHI MILA"));
            for(SourceText.Range gap:report.unmatched)summary.addView(arabic(gap.text,24));
            caption(summary,"In alfaaz ko matching ke dauraan hataaya ya sahi maan kar badla nahi gaya.");
        }
        int number=0;
        for(FragmentSearch.Fragment fragment:report.fragments){
            LinearLayout c=card(list,Surface.Kind.PANEL);c.addView(label("HISSA "+(++number)+" · AAPNE LIKHA"));c.addView(arabic(fragment.query.text,24));gap(c,10);
            caption(c,"Source mein "+fragment.totalOccurrences+" jagah mila · Reading marks ko chhod kar text match");gap(c,12);
            for(FragmentSearch.Hit hit:fragment.alternatives){
                c.addView(label(content.surah(hit.ayah.surah).name+" · "+hit.ayah.surah+":"+hit.ayah.number));
                c.addView(arabic(hit.source.text,27));caption(c,"Asal ayah ka hissa; poori ayah context ke saath khol sakte hain.");gap(c,10);
                c.addView(evidenceActions(hit.ayah,fragmentTrace(response,fragment,hit)));gap(c,18);
            }
            if(fragment.totalOccurrences>fragment.alternatives.size())caption(c,"Pehli "+fragment.alternatives.size()+" source jagah dikhayi gayi hain; kisi ek ko asal origin nahi maana gaya.");
            c.addView(button("Sirf is hisse ko khojein",()->{query.setText(fragment.query.text);query.setSelection(query.length());}));
        }
        if(!response.results.isEmpty()){list.addView(label("POORI QUERY SE RELATED RESULTS"));gap(list,12);}
    }
    private void settings(){
        LinearLayout page=sheet("Apni reading");Dialog settingsDialog=activeDialog;
        settingsDialog.setOnDismissListener(d->{if(activeDialog==settingsDialog){activeDialog=null;show();}});
        page.addView(label("ARABIC KA SIZE"));gap(page,8);ArabicText sample=arabic(content.ayah("Q:1:1").arabic,arabicSize);page.addView(sample);
        SeekBar slider=new SeekBar(this);slider.setMax(22);slider.setProgress((int)arabicSize-24);page.addView(slider);slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){
            public void onProgressChanged(SeekBar s,int p,boolean user){arabicSize=24+p;sample.setTextSize(arabicSize);}public void onStartTrackingTouch(SeekBar s){}public void onStopTrackingTouch(SeekBar s){learning.set("arabic_size",""+arabicSize);}
        });gap(page,16);page.addView(label("WORD MEANING KI ZABAAN"));gap(page,10);
        LinearLayout langs=row(this);for(String lang:new String[]{"hi","ur","en"}){String name=lang.equals("hi")?"हिन्दी":lang.equals("ur")?"اردو":"English";TextView b=button(name+(language.equals(lang)?" ✓":""),()->{language=lang;learning.set("language",lang);settings();});langs.addView(b,new LinearLayout.LayoutParams(0,-2,1));}page.addView(langs);gap(page,18);
        Switch contrast=new Switch(this);contrast.setText("Zyada contrast");contrast.setTextColor(INK);contrast.setChecked(highContrast);contrast.setMinHeight(dp(this,48));page.addView(contrast);contrast.setOnCheckedChangeListener((b,v)->{highContrast=v;learning.set("contrast",""+v);sample.setReliefEnabled(!v);backdrop.highContrast=v;backdrop.invalidate();});
        gap(page,14);page.addView(button("Shaant reading · Controls chhupaayein",()->{quietReader=true;tab=1;reading=true;settingsDialog.dismiss();}));gap(page,10);
        page.addView(button("Doosri apps par recall · Timer",this::ambientSettings));gap(page,10);page.addView(button("Sources aur licenses",this::sources));gap(page,10);page.addView(button("Learning export",this::backup));gap(page,10);page.addView(button("Backup restore",this::restorePicker));gap(page,14);
        page.addView(button("Done",settingsDialog::dismiss));caption(page,"No account · No ads · Aapki learning aapke phone par");
    }
    private void sources(){
        LinearLayout page=sheet("Sources aur bharosa");caption(page,content.sources());gap(page,16);
        caption(page,"Quran: 114 surahs / 6,236 ayat. Original text checksum checked. Meaning: imported source glosses; independent scholarly review abhi pending hai. 9 ayat mein word alignment mismatch ki wajah se body meanings withheld hain.");gap(page,12);
        caption(page,"Yeh non-commercial preview hai. Imported gloss data paid app, subscription ya advertisements ke liye cleared nahi hai.");gap(page,14);
        for(String[] item:new String[][]{{"Tanzil notice","licenses/TANZIL.txt"},{"Word meanings license","licenses/DATA-QURAN.txt"},{"Amiri font license","licenses/AMIRI-OFL.txt"}}){page.addView(button(item[0],()->{LinearLayout p=sheet(item[0]);try{TextView v=text(this,ContentStore.asset(this,item[1]),12,MUTED);v.setTextIsSelectable(true);p.addView(v);}catch(IOException e){caption(p,"License file unavailable");}}));gap(page,8);}
        page.addView(button("Tanzil source website",()->openWebsite(Uri.parse("https://tanzil.net/"))));gap(page,10);
        caption(page,"Pack SHA-256\n"+content.packHash+"\nScheduler: "+Recall.VERSION+"\nSearch: "+SearchEngine.VERSION);
    }
    private void hideKeyboard(){View view=getCurrentFocus();if(view!=null)((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(view.getWindowToken(),0);}
    private void shareText(String text){Intent share=new Intent(Intent.ACTION_SEND);share.setType("text/plain");share.putExtra(Intent.EXTRA_TEXT,text);startActivity(Intent.createChooser(share,"Share karein"));}
    private void saveFile(String name,String type,byte[] bytes){
        app.io.execute(()->{
            try{String token=app.exports.stage(bytes);ui.post(()->{
                preparingExport=false;
                if(isDestroyed()||isFinishing()){app.io.execute(()->discardExport(token));return;}
                pendingExport=token;Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT);intent.addCategory(Intent.CATEGORY_OPENABLE);intent.setType(type);intent.putExtra(Intent.EXTRA_TITLE,name);
                try{startActivityForResult(intent,EXPORT);}catch(ActivityNotFoundException e){pendingExport=null;app.io.execute(()->discardExport(token));toast("File save karne wala document picker nahi mila");}
            });}catch(Exception e){ui.post(()->{preparingExport=false;toast("Export taiyaar nahi hua: "+e.getMessage());});}
        });
    }
    private void discardExport(String token){if(token!=null)try{app.exports.discard(token);}catch(IOException ignored){}}
    private boolean beginExport(){if(preparingExport||pendingExport!=null){toast("Pehla export poora hone dein");return false;}preparingExport=true;return true;}
    private void backup(){
        if(!beginExport())return;
        app.io.execute(()->{try{byte[] data=learning.backup().toString(2).getBytes(StandardCharsets.UTF_8);ui.post(()->{if(!isDestroyed())saveFile("Aaris-Quran-learning.json","application/json",data);});}catch(Exception e){ui.post(()->{preparingExport=false;toast("Backup nahi ban saka");});}});
    }
    private void restorePicker(){Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT);intent.addCategory(Intent.CATEGORY_OPENABLE);intent.setType("application/json");try{startActivityForResult(intent,IMPORT);}catch(ActivityNotFoundException e){toast("Backup kholne wala document picker nahi mila");}}
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);
        if(request==OVERLAY_PERMISSION){if(pendingAmbient&&Settings.canDrawOverlays(this))beginAmbient();else {pendingAmbient=false;toast("Permission ke bina doosri apps par card nahi aa sakta");}return;}
        if(result!=RESULT_OK||data==null||data.getData()==null){if(request==EXPORT){String token=pendingExport;pendingExport=null;app.io.execute(()->discardExport(token));}return;}Uri uri=data.getData();
        if(request==EXPORT){String token=pendingExport;pendingExport=null;if(token==null){toast("Export dobara shuru karein");return;}app.io.execute(()->{
            try{try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException();app.exports.copyTo(token,out);}discardExport(token);ui.post(()->toast("File save ho gayi"));}
            catch(Exception e){ui.post(()->toast("File save nahi hui; export dobara karein"));}
        });}
        if(request==IMPORT)app.io.execute(()->{try{
            ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=getContentResolver().openInputStream(uri)){if(in==null)throw new IOException();byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1){if(out.size()+n>ExportStaging.MAX_BYTES)throw new IOException("Backup 64 MiB se bada hai");out.write(b,0,n);}}
            JSONObject backup=new JSONObject(out.toString("UTF-8"));int count=learning.validateBackup(backup,content);
            ui.post(()->{if(isDestroyed())return;pendingRestore=backup;new AlertDialog.Builder(this).setTitle("Learning restore karein?").setMessage(count+" history events merge honge. Maujooda history aur notes delete nahi honge.").setNegativeButton("Abhi nahi",(d,w)->pendingRestore=null).setPositiveButton("Merge karein",(d,w)->{JSONObject restore=pendingRestore;pendingRestore=null;app.io.execute(()->{try{learning.restore(restore,content);ui.post(()->{toast("Learning restore ho gayi");show();});}catch(Exception e){ui.post(()->toast("Restore nahi hua; purana data surakshit hai"));}});}).show();});
        }catch(Exception e){ui.post(()->toast("Backup valid nahi hai: "+e.getMessage()));}});
    }
    @Override public void onBackPressed(){if(overlay.getChildCount()>0){hidePeek();return;}if(searching){searchGeneration.incrementAndGet();if(searchTask!=null)searchTask.cancel(true);show();return;}if(quietReader){quietReader=false;show();return;}if(tab==1&&reading){reading=false;show();return;}if(tab!=1){tab=1;reading=true;show();return;}super.onBackPressed();}

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
                .put("reasons",new JSONArray(result.reasons)).put("transformation_cost",result.transformationCost)
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

    private void research(){
        LinearLayout page=sheet("Evidence aur research");caption(page,"Search result se ayat chunein. Export mein original Quran, reference aur source checksum jaayega.");gap(page,12);
        page.addView(text(this,selectedEvidence.size()+" ayat chuni hui hain",21,INK));gap(page,14);
        TextView export=button("PDF + TXT + JSON export",()->{
            if(selectedEvidence.isEmpty()){toast("Pehle search results se ayat chunein");return;}
            if(!beginExport())return;
            List<String> selection=new ArrayList<>(selectedEvidence);Map<String,JSONObject> traces=new LinkedHashMap<>(selectionTrace);String query=searchQuery;
            toast("Evidence bundle ban raha hai…");app.io.execute(()->{try{
                EvidenceExporter.Bundle b=EvidenceExporter.build(this,content,selection,query,traces);learning.saveBundle(b.id,b.json);
                ui.post(()->{if(!isDestroyed())saveFile("Aaris-Quran-evidence.zip","application/zip",b.zip);});
            }catch(Exception e){ui.post(()->{preparingExport=false;toast("Export nahi hua: "+e.getMessage());});}});
        });page.addView(export);gap(page,10);
        page.addView(button("Selection saaf karein",()->{selectedEvidence.clear();selectionTrace.clear();refreshEvidenceControls();research();}));gap(page,20);
        page.addView(label("DOOSRE AI KE SAATH"));gap(page,8);caption(page,"Share par tap karne ke baad aap destination chunte hain. App khud query ya learning history bahar nahi bhejta.");gap(page,12);
        page.addView(button("Search-query prompt share karein",()->shareText(References.queryPrompt(searchQuery))));gap(page,10);
        page.addView(button("Evidence-reading prompt share karein",()->shareText(References.reasoningPrompt())));gap(page,10);
        page.addView(button("AI answer ke references check karein",this::verifyAnswer));gap(page,10);
    }
    private void verifyAnswer(){
        String saved=learning.lastBundle();if(saved==null){toast("Pehle evidence bundle export karein");return;}
        LinearLayout page=sheet("References check karein");caption(page,"Aakhri exported snapshot se check hoga. Format: \"exact Arabic quote\" [Q:2:255]. Is se AI ki reasoning ya religious conclusion verify nahi hoti.");
        EditText answer=new EditText(this);answer.setTextColor(INK);answer.setHintTextColor(MUTED);answer.setHint("AI ka jawab yahan paste karein…");answer.setMinLines(5);answer.setMaxLines(10);answer.setFilters(new InputFilter[]{new InputFilter.LengthFilter(100000)});page.addView(answer);gap(page,14);
        TextView report=text(this,"",15,INK);page.addView(report);
        page.addView(button("References dekhein",()->{
            try{Map<String,String> snapshot=BackupValidator.validateBundle(new JSONObject(saved),content);
                References.Check c=References.verify(answer.getText().toString(),snapshot);
                report.setText((c.passed()?"Reference IDs match karte hain.":"Reference check adhura ya mismatch hai.")+"\nMile: "+c.found.size()+" · Nahi mile: "+c.missing.size()+"\nExact quotes checked: "+c.checkedQuotes+" · Mismatch: "+c.badQuotes.size()+" · Bina citation quotes: "+c.uncheckedQuotes+"\n"+(c.missing.isEmpty()?"":String.join(", ",c.missing))+"\nSirf double-quoted text ke turant baad citation wala quote format check hota hai. Conclusion verify nahi hua.");hideKeyboard();
            }catch(Exception e){report.setText("Evidence snapshot check nahi ho saka.");}
        }));
    }
}
