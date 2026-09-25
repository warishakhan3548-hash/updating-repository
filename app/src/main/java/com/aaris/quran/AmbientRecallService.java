package com.aaris.quran;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.content.res.Configuration;
import android.graphics.*;
import android.hardware.display.DisplayManager;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import com.aaris.quran.core.*;
import com.aaris.quran.Glass.Surface;
import java.util.*;
import static com.aaris.quran.Glass.*;

/** The only owner of system-overlay windows. Started explicitly from a visible Activity. */
public final class AmbientRecallService extends Service {
    static final String STOP="com.aaris.quran.STOP_RECALL",PREVIEW="preview";
    private static final String CHANNEL="ambient_recall";
    private static final int NOTIFICATION=31;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final AmbientSession session=new AmbientSession();
    private QuranApp app;
    private WindowManager windows;
    private Context windowContext;
    private PowerManager power;
    private KeyguardManager keyguard;
    private View card;
    private Typeface font;
    private boolean destroyed,ready,receiverRegistered,preview,candidateLoading;
    private int candidateGeneration;
    private long cardShownAt;
    private final Runnable tick=this::update;
    private final BroadcastReceiver screen=new BroadcastReceiver(){
        @Override public void onReceive(Context c,Intent i){update();}
    };

    @Override public void onCreate(){
        super.onCreate();app=(QuranApp)getApplication();windowContext=this;
        if(Build.VERSION.SDK_INT>=30){Display display=getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY);windowContext=createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,null);}
        windows=windowContext.getSystemService(WindowManager.class);
        power=getSystemService(PowerManager.class);keyguard=getSystemService(KeyguardManager.class);
        font=Appearance.load(this).typeface(this);
        IntentFilter filter=new IntentFilter();filter.addAction(Intent.ACTION_SCREEN_OFF);filter.addAction(Intent.ACTION_SCREEN_ON);filter.addAction(Intent.ACTION_USER_PRESENT);
        if(Build.VERSION.SDK_INT>=33)registerReceiver(screen,filter,Context.RECEIVER_NOT_EXPORTED);else registerReceiver(screen,filter);
        receiverRegistered=true;app.visibilityChanged=tick;
        app.ready(()->{if(destroyed)return;if(app.loadError!=null){finish("Offline content could not be opened. Reopen the app.");return;}ready=true;update();});
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        if(intent==null||STOP.equals(intent.getAction())){finish("Session stopped");return START_NOT_STICKY;}
        if(!Settings.canDrawOverlays(this)){finish("Permission to display over other apps is required");return START_NOT_STICKY;}
        preview=intent.getBooleanExtra(PREVIEW,false);
        try {
            NotificationManager manager=getSystemService(NotificationManager.class);
            NotificationChannel channel=new NotificationChannel(CHANNEL,"Quran recall session",NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Running session status and stop control");channel.setShowBadge(false);manager.createNotificationChannel(channel);
            if(Build.VERSION.SDK_INT>=34)startForeground(NOTIFICATION,notification(),ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            else startForeground(NOTIFICATION,notification());
        }catch(RuntimeException e){finish("Session could not start. Open Aaris and try again.");return START_NOT_STICKY;}
        candidateGeneration++;candidateLoading=false;removeCard();long interval=AmbientSettings.minutes(this)*Recall.MINUTE;
        session.start(SystemClock.elapsedRealtime(),interval,preview?10_000:interval);
        app.ambientRunning=true;AmbientSettings.status(this,true,preview?"Test ready · Open another app":"Session is running");
        update();return START_NOT_STICKY;
    }
    private Notification notification(){
        Intent home=new Intent(this,MainActivity.class).putExtra("open_ambient",true).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent open=PendingIntent.getActivity(this,31,home,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop=PendingIntent.getService(this,32,new Intent(this,AmbientRecallService.class).setAction(STOP),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_recall_notification)
            .setContentTitle("Keep Quran in mind")
            .setContentText("Every "+AmbientSettings.minutes(this)+" minutes · Tap to manage")
            .setSubText("Timer pauses on the lock screen and while Aaris is open")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(new Notification.Action.Builder(null,"Stop session",stop).build()).build();
    }
    private boolean eligible(){return ready&&!app.activityVisible&&power.isInteractive()&&!keyguard.isKeyguardLocked();}
    private void update(){
        handler.removeCallbacks(tick);if(destroyed||!session.running())return;
        if(!Settings.canDrawOverlays(this)){finish("Overlay permission was removed. Session stopped.");return;}
        long now=SystemClock.elapsedRealtime();boolean allowed=eligible();
        AmbientSession.Action action=session.advance(now,allowed);
        if(action==AmbientSession.Action.HIDE)removeCard();
        if(action==AmbientSession.Action.SHOW)prepareCard();
        // A dismissed/ignored card is not a failed review. Never leave a stale card indefinitely.
        if(card!=null&&now-cardShownAt>=2*Recall.MINUTE)dismissCard();
        if(!destroyed&&session.running())handler.postDelayed(tick,allowed&&!session.showing()?Math.max(100,Math.min(1000,session.remaining())):1000);
    }
    private void prepareCard(){
        if(candidateLoading||destroyed||!session.running()||!session.showing())return;
        candidateLoading=true;final int token=++candidateGeneration;
        try{
            app.readerWorker.execute(()->{
                List<Recall.State> candidates=new ArrayList<>();RuntimeException failure=null;
                try{
                    String language=app.learning.get("language","hi");
                    for(Recall.State state:app.learning.states().values()){
                        if(!state.active)continue;
                        RecallTarget target=RecallTarget.parse(state.target);if(target==null)continue;
                        ContentStore.Word word=null;boolean valid;
                        if(target.kind==RecallTarget.Kind.WORD||target.kind==RecallTarget.Kind.PREFATORY_WORD){
                            word=app.content.word(state.target);valid=word!=null;
                        }else valid=app.content.hasRecallTarget(state.target);
                        if(valid&&(word==null||word.hasGloss(language)))candidates.add(state);
                    }
                }catch(RuntimeException error){failure=error;}
                final RuntimeException problem=failure;
                handler.post(()->{
                    if(token!=candidateGeneration)return;
                    candidateLoading=false;
                    if(destroyed||!session.running()||!session.showing())return;
                    if(problem!=null){finish("Card could not open. Open Aaris and restart the session.");return;}
                    long now=SystemClock.elapsedRealtime();
                    if(!eligible()){session.dismiss(now);handler.post(tick);return;}
                    if(candidates.isEmpty()){finish("Choose a word or ayah from Quran to remember first.");return;}
                    try{
                        String target=session.choose(candidates,System.currentTimeMillis(),!preview&&AmbientSettings.dueOnly(this));
                        if(target==null){session.dismiss(now);handler.post(tick);}
                        else{showCard(target);session.presented(target);cardShownAt=now;preview=false;}
                    }catch(RuntimeException error){finish("Card could not open. Open Aaris and restart the session.");}
                });
            });
        }catch(java.util.concurrent.RejectedExecutionException rejected){
            candidateLoading=false;finish("Card could not open. Open Aaris and restart the session.");
        }
    }
    private void showCard(String shownTarget){
        removeCard();
        final Ayah ayah=app.content.contextFor(shownTarget);
        final ContentStore.Word word=app.content.word(shownTarget);
        final AyahTransition edge=app.content.transition(shownTarget);
        final String original=edge==null?app.content.recallText(shownTarget):edge.opening.text;
        if(ayah==null||original==null)throw new IllegalStateException("Missing source target");
        LinearLayout shell=column(windowContext);shell.setBackground(new Surface(windowContext,Surface.Kind.SHEET,true));pad(shell,18,14);
        LinearLayout bar=row(windowContext);LinearLayout title=column(windowContext);
        TextView brand=text(windowContext,"AARIS · RECALL MOMENT",10,GOLD);brand.setLetterSpacing(.1f);title.addView(brand);
        title.addView(text(windowContext,app.content.surah(ayah.surah).name+" · "+ayah.surah+":"+ayah.number,13,MUTED));bar.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        TextView close=control("×",this::dismissCard);close.setContentDescription("Close card; remind me again later");close.setTextSize(27);bar.addView(close,new LinearLayout.LayoutParams(dp(windowContext,48),dp(windowContext,48)));shell.addView(bar);
        int height=displayHeight();int maxBody=Math.max(dp(windowContext,80),Math.min(dp(windowContext,410),height-dp(windowContext,220)));
        ScrollView scroll=new ScrollView(windowContext){@Override protected void onMeasure(int w,int h){super.onMeasure(w,View.MeasureSpec.makeMeasureSpec(maxBody,View.MeasureSpec.AT_MOST));}};
        scroll.setFillViewport(false);scroll.setOverScrollMode(View.OVER_SCROLL_NEVER);LinearLayout body=column(windowContext);pad(body,0,12);scroll.addView(body);shell.addView(scroll,new LinearLayout.LayoutParams(-1,-2));
        String cue=word!=null?original:edge!=null?edge.ending.text:cue(original);
        TextView prompt=arabic(cue,word==null?29:40);body.addView(prompt,new LinearLayout.LayoutParams(-1,-2));
        if(word!=null&&app.audio!=null&&app.audio.canPlay(word)){
            app.audio.play(word);
            TextView replay=control("🔊  Replay",()->app.audio.play(word));
            body.addView(replay,new LinearLayout.LayoutParams(-1,-2));
        }
        String instruction=word!=null?"Do you remember this word's meaning?":edge!=null?"Recall how the next ayah begins":"Ayah cue · Continue from memory";
        TextView hint=text(windowContext,instruction,14,MUTED);hint.setGravity(Gravity.CENTER);pad(hint,0,12);body.addView(hint);
        LinearLayout answer=column(windowContext);answer.setVisibility(View.GONE);body.addView(answer);
        TextView reveal=control(word==null?"Show source text":"Show meaning",()->{});body.addView(reveal,new LinearLayout.LayoutParams(-1,-2));
        reveal.setOnClickListener(v->{
            if(answer.getVisibility()==View.VISIBLE)return;
            app.learning.event(shownTarget,Recall.Kind.REVEAL,ayah.id);answer.setVisibility(View.VISIBLE);reveal.setVisibility(View.GONE);hint.setVisibility(View.GONE);
            if(word!=null){TextView meaning=text(windowContext,word.gloss(app.learning.get("language","hi")),24,INK);meaning.setGravity(Gravity.CENTER);pad(meaning,0,12);answer.addView(meaning);}
            else {if(edge!=null){TextView ref=text(windowContext,edge.to.surah+":"+edge.to.number+" · Next ayah opening",12,GOLD);answer.addView(ref);}answer.addView(arabic(original,28));}
            TextView question=text(windowContext,"How much did you remember before revealing?",12,MUTED);question.setGravity(Gravity.CENTER);pad(question,0,14);answer.addView(question);
            String eventId=UUID.randomUUID().toString();boolean[] rated={false};
            String[] labels={"Again","Hard","Good","Easy"};Recall.Kind[] kinds={Recall.Kind.AGAIN,Recall.Kind.HARD,Recall.Kind.GOOD,Recall.Kind.EASY};
            for(int row=0;row<2;row++){LinearLayout ratings=Glass.row(windowContext);
                for(int col=0;col<2;col++){int index=row*2+col;TextView rating=control(labels[index],()->{
                    if(rated[0])return;rated[0]=true;app.learning.event(eventId,shownTarget,kinds[index],ayah.id);dismissCard();
                });LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1);p.setMargins(col==0?0:dp(windowContext,6),0,0,dp(windowContext,6));ratings.addView(rating,p);}answer.addView(ratings);
            }
        });
        TextView stop=text(windowContext,"Stop session",12,MUTED);stop.setGravity(Gravity.CENTER);pad(stop,12,8);stop.setMinimumHeight(dp(windowContext,48));stop.setBackground(Glass.touch(windowContext,Surface.Kind.BUTTON,true));stop.setFocusable(true);stop.setOnClickListener(v->finish("Session stopped"));Glass.motion(stop);shell.addView(stop,new LinearLayout.LayoutParams(-1,-2));
        int width=Math.min(dp(windowContext,410),displayWidth()-dp(windowContext,32));
        WindowManager.LayoutParams params=new WindowManager.LayoutParams(width,WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,PixelFormat.TRANSLUCENT);
        params.gravity=Gravity.TOP|Gravity.CENTER_HORIZONTAL;params.y=dp(windowContext,44);params.setTitle("Aaris Quran recall");
        // The window covers only its card. Touches outside it belong to the underlying app.
        windows.addView(shell,params);card=shell;
    }
    private int displayWidth(){return Build.VERSION.SDK_INT>=30?windows.getCurrentWindowMetrics().getBounds().width():windowContext.getResources().getDisplayMetrics().widthPixels;}
    private int displayHeight(){return Build.VERSION.SDK_INT>=30?windows.getCurrentWindowMetrics().getBounds().height():windowContext.getResources().getDisplayMetrics().heightPixels;}
    private String cue(String source){String[] words=source.split("\\s+");return String.join(" ",Arrays.copyOf(words,Math.min(2,words.length)))+" …";}
    private TextView arabic(String value,int size){ArabicText t=new ArabicText(windowContext);t.setText(value);t.setTextSize(size);t.setReliefEnabled(!Boolean.parseBoolean(app.learning.get("contrast","false")));t.setTypeface(Appearance.load(this).typeface(this));t.setTextDirection(View.TEXT_DIRECTION_RTL);t.setGravity(Gravity.CENTER);t.setLineSpacing(dp(windowContext,8),1.05f);return t;}
    private TextView control(String value,Runnable action){TextView t=text(windowContext,value,14,INK);t.setGravity(Gravity.CENTER);pad(t,12,10);t.setMinimumHeight(dp(windowContext,48));t.setBackground(Glass.touch(windowContext,Surface.Kind.BUTTON,true));t.setFocusable(true);t.setOnClickListener(v->action.run());Glass.motion(t);return t;}
    private void dismissCard(){removeCard();session.dismiss(SystemClock.elapsedRealtime());handler.removeCallbacks(tick);handler.post(tick);}
    private void removeCard(){if(app!=null&&app.audio!=null)app.audio.stop();if(card!=null){try{windows.removeViewImmediate(card);}catch(IllegalArgumentException ignored){}card=null;}}
    private void finish(String message){candidateGeneration++;candidateLoading=false;session.stop();handler.removeCallbacksAndMessages(null);removeCard();app.ambientRunning=false;AmbientSettings.status(this,false,message);stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
    @Override public void onConfigurationChanged(Configuration config){super.onConfigurationChanged(config);if(card!=null)dismissCard();}
    @Override public void onDestroy(){destroyed=true;candidateGeneration++;candidateLoading=false;handler.removeCallbacksAndMessages(null);removeCard();session.stop();if(receiverRegistered)unregisterReceiver(screen);if(app.visibilityChanged==tick)app.visibilityChanged=null;if(app.ambientRunning)AmbientSettings.status(this,false,"Session stopped. Restart it from the app.");app.ambientRunning=false;super.onDestroy();}
    @Override public IBinder onBind(Intent intent){return null;}
}
