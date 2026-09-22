package com.aaris.quran;

import android.app.Application;
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
    volatile SearchEngine search;
    volatile String loadError;
    ExportStaging exports;
    private final CountDownLatch ready=new CountDownLatch(1);
    @Override public void onCreate(){
        super.onCreate();exports=new ExportStaging(new File(getFilesDir(),"export-staging"));io.execute(()->{
            try{content=new ContentStore(this);learning=new LearningStore(this);learning.getWritableDatabase();}
            catch(Exception e){loadError="Offline content khul nahi saka: "+e.getMessage();}
            finally{ready.countDown();}
        });
    }
    void ready(Runnable callback){io.execute(()->{try{ready.await();main.post(callback);}catch(InterruptedException e){Thread.currentThread().interrupt();}});}
}
