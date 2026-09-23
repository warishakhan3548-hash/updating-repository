package com.aaris.quran;

import android.app.Application;
import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import com.aaris.quran.core.SearchEngine;
import com.aaris.quran.core.ExportStaging;
import java.io.File;
import java.util.concurrent.*;

public final class QuranApp extends Application {
    final ExecutorService io=Executors.newSingleThreadExecutor();
    final ExecutorService searchWorker=Executors.newSingleThreadExecutor();
    final Handler main=new Handler(Looper.getMainLooper());
    volatile ContentStore content;
    volatile LearningStore learning;
    volatile HadithStore hadith;
    volatile SearchEngine search;
    volatile String loadError;
    ExportStaging exports;
    boolean activityVisible,ambientRunning;
    Runnable visibilityChanged;
    private int startedActivities;
    private final CountDownLatch ready=new CountDownLatch(1);
    @Override public void onCreate(){
        super.onCreate();
        AmbientSettings.processStarted(this);
        registerActivityLifecycleCallbacks(new ActivityLifecycleCallbacks(){
            public void onActivityStarted(Activity a){startedActivities++;visibility();}
            public void onActivityStopped(Activity a){startedActivities=Math.max(0,startedActivities-1);visibility();}
            private void visibility(){activityVisible=startedActivities>0;if(visibilityChanged!=null)visibilityChanged.run();}
            public void onActivityCreated(Activity a,Bundle b){}
            public void onActivityResumed(Activity a){}
            public void onActivityPaused(Activity a){}
            public void onActivitySaveInstanceState(Activity a,Bundle b){}
            public void onActivityDestroyed(Activity a){}
        });
        exports=new ExportStaging(new File(getFilesDir(),"export-staging"));io.execute(()->{
            try{content=new ContentStore(this);learning=new LearningStore(this);learning.getWritableDatabase();hadith=HadithStore.openIfBundled(this);}
            catch(Exception e){loadError="Offline content khul nahi saka: "+e.getMessage();}
            finally{ready.countDown();}
        });
    }
    void ready(Runnable callback){io.execute(()->{try{ready.await();main.post(callback);}catch(InterruptedException e){Thread.currentThread().interrupt();}});}
}
