package com.aaris.quran;

import android.app.Application;
import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import com.aaris.quran.core.SearchEngine;
import com.aaris.quran.core.ExportStaging;
import org.json.JSONObject;
import java.io.File;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

public final class QuranApp extends Application {
    private static ExecutorService worker(String name){
        return Executors.newSingleThreadExecutor(r->new Thread(()->{
            try{android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND);}catch(RuntimeException ignored){}
            r.run();
        },"Aaris-"+name));
    }
    final ExecutorService io=worker("io");
    final ExecutorService searchWorker=worker("hadith-search");
    final ExecutorService hadithBrowseWorker=worker("hadith-browse");
    final ExecutorService quranSearchWorker=worker("quran-search");
    final ExecutorService recitationWorker=worker("recitation");
    final ExecutorService recitationStatusWorker=worker("recitation-status");
    final ExecutorService readerWorker=worker("reader-prefetch");
    volatile RecitationDownloads recitationDownloads;
    volatile boolean recitationActive;
    volatile int recitationSurah=1,recitationAyah=1;
    volatile String recitationLabel="";
    Runnable recitationChanged,hadithChanged,operationChanged,researchPdfChanged,preparedExportChanged,restoreImportChanged;
    final ExecutorService audioWorker=worker("audio");
    final ExecutorService audioStatusWorker=worker("audio-status");
    final ExecutorService recitationDownloadWorker=worker("recitation-download");
    final Handler main=new Handler(Looper.getMainLooper());
    final AtomicBoolean researchPdfBusy=new AtomicBoolean(false);
    final AtomicBoolean exportPrepareBusy=new AtomicBoolean(false);
    final AtomicBoolean exportWriteBusy=new AtomicBoolean(false);
    volatile ContentStore content;
    volatile LearningStore learning;
    volatile HadithStore hadith;
    volatile boolean hadithLoading;
    volatile TranslationStore translations;
    volatile String translationError;
    volatile QuranAudioStore wordAudio;
    volatile WordAudioPlayer audio;
    volatile QuranAudioDownloadManager audioDownloads;
    volatile SearchEngine search;
    volatile String loadError,hadithLoadError,wordAudioLoadError;
    ExportStaging exports;
    boolean activityVisible,ambientRunning;
    Runnable visibilityChanged;
    private int startedActivities;
    private boolean searchWarmPending;
    private ResearchPdfResult pendingResearchPdf;
    private PreparedExportResult pendingPreparedExport;
    private RestoreImportResult pendingRestoreImport;
    private final CountDownLatch ready=new CountDownLatch(1);

    static final class ResearchPdfResult {
        final Uri uri;final String prompt,error;
        ResearchPdfResult(Uri uri,String prompt,String error){this.uri=uri;this.prompt=prompt;this.error=error;}
    }
    synchronized void publishResearchPdf(Uri uri,String prompt){
        ResearchPdfResult old=pendingResearchPdf;pendingResearchPdf=new ResearchPdfResult(uri,prompt,null);
        if(old!=null&&old.uri!=null)ResearchFiles.discard(this,old.uri);
        notifyResearchPdfChanged();
    }
    synchronized void publishResearchPdfFailure(String error){
        ResearchPdfResult old=pendingResearchPdf;pendingResearchPdf=new ResearchPdfResult(null,null,error);
        if(old!=null&&old.uri!=null)ResearchFiles.discard(this,old.uri);
        notifyResearchPdfChanged();
    }
    synchronized ResearchPdfResult takeResearchPdfResult(){
        ResearchPdfResult result=pendingResearchPdf;pendingResearchPdf=null;return result;
    }
    private void notifyResearchPdfChanged(){
        main.post(()->{Runnable current=researchPdfChanged;if(current!=null)current.run();});
    }

    static final class PreparedExportResult {
        final String token,name,type,error;
        PreparedExportResult(String token,String name,String type,String error){this.token=token;this.name=name;this.type=type;this.error=error;}
    }
    synchronized void publishPreparedExport(String token,String name,String type){
        PreparedExportResult old=pendingPreparedExport;
        pendingPreparedExport=new PreparedExportResult(token,name,type,null);
        discardPreparedExport(old);
        notifyPreparedExportChanged();
    }
    synchronized void publishPreparedExportFailure(String error){
        PreparedExportResult old=pendingPreparedExport;
        pendingPreparedExport=new PreparedExportResult(null,null,null,error);
        discardPreparedExport(old);
        notifyPreparedExportChanged();
    }
    PreparedExportResult takePreparedExportResult(){
        PreparedExportResult result;
        synchronized(this){
            result=pendingPreparedExport;
            if(result==null)return null;
            pendingPreparedExport=null;
            exportPrepareBusy.set(false);
        }
        notifyOperationChanged();
        return result;
    }
    private void discardPreparedExport(PreparedExportResult result){
        if(result==null||result.token==null||exports==null)return;
        try{exports.discard(result.token);}catch(Exception ignored){}
    }
    private void notifyPreparedExportChanged(){
        main.post(()->{Runnable current=preparedExportChanged;if(current!=null)current.run();});
        notifyOperationChanged();
    }

    static final class RestoreImportResult {
        final JSONObject backup;final int count;final String error;
        RestoreImportResult(JSONObject backup,int count,String error){this.backup=backup;this.count=count;this.error=error;}
    }
    synchronized void publishRestoreImport(JSONObject backup,int count){
        pendingRestoreImport=new RestoreImportResult(backup,count,null);
        notifyRestoreImportChanged();
    }
    synchronized void publishRestoreImportFailure(String error){
        pendingRestoreImport=new RestoreImportResult(null,0,error);
        notifyRestoreImportChanged();
    }
    synchronized RestoreImportResult peekRestoreImportResult(){return pendingRestoreImport;}
    synchronized boolean clearRestoreImportResult(RestoreImportResult expected){
        if(pendingRestoreImport!=expected)return false;
        pendingRestoreImport=null;return true;
    }
    private void notifyRestoreImportChanged(){
        main.post(()->{Runnable current=restoreImportChanged;if(current!=null)current.run();});
    }
    @Override public void onCreate(){
        super.onCreate();
        Glass.apply(Appearance.load(this));recitationDownloads=new RecitationDownloads(this);
        AmbientSettings.processStarted(this);
        registerActivityLifecycleCallbacks(new ActivityLifecycleCallbacks(){
            public void onActivityStarted(Activity a){startedActivities++;visibility();}
            public void onActivityStopped(Activity a){startedActivities=Math.max(0,startedActivities-1);visibility();}
            private void visibility(){activityVisible=startedActivities>0;if(activityVisible)scheduleSearchWarmup();if(visibilityChanged!=null)visibilityChanged.run();}
            public void onActivityCreated(Activity a,Bundle b){}
            public void onActivityResumed(Activity a){}
            public void onActivityPaused(Activity a){}
            public void onActivitySaveInstanceState(Activity a,Bundle b){}
            public void onActivityDestroyed(Activity a){}
        });
        exports=new ExportStaging(new File(getFilesDir(),"export-staging"));io.execute(()->{
            try{
                content=new ContentStore(this);learning=new LearningStore(this);learning.getWritableDatabase();
                try{translations=new TranslationStore(this);}catch(Exception e){translationError=e.getMessage();}
                try{
                    wordAudio=new QuranAudioStore(this,content.audioAlignmentHash);
                    audio=new WordAudioPlayer(this,wordAudio);
                    audioDownloads=new QuranAudioDownloadManager(wordAudio,audioWorker,this::notifyOperationChanged);
                }catch(Exception e){
                    wordAudio=null;audio=null;audioDownloads=null;
                    wordAudioLoadError="Local Quran audio storage could not be opened: "+e.getMessage();
                }
                hadithLoading=true;
                searchWorker.execute(()->{
                    try{hadith=HadithStore.openIfBundled(this);}
                    catch(Exception e){hadith=null;hadithLoadError="Hadith pack could not be opened: "+e.getMessage();}
                    finally{
                        hadithLoading=false;
                        main.post(()->{Runnable changed=hadithChanged;if(changed!=null)changed.run();});
                    }
                });
            }catch(Exception e){loadError="Offline content could not be opened: "+e.getMessage();}
            finally{
                ready.countDown();
                main.post(this::scheduleSearchWarmup);
            }
        });
    }
    private boolean lowRamDevice(){android.app.ActivityManager manager=(android.app.ActivityManager)getSystemService(ACTIVITY_SERVICE);return manager!=null&&manager.isLowRamDevice();}
    private void scheduleSearchWarmup(){
        if(ready.getCount()!=0||loadError!=null||search!=null||searchWarmPending||lowRamDevice()||!activityVisible)return;
        searchWarmPending=true;
        main.postDelayed(()->{
            searchWarmPending=false;
            if(ready.getCount()==0&&loadError==null&&search==null&&activityVisible)quranSearchWorker.execute(this::warmSearchIndex);
        },1200L);
    }
    synchronized SearchEngine searchIndex(){
        SearchEngine current=search;if(current!=null)return current;
        current=content.buildSearch(translations);search=current;return current;
    }
    private void warmSearchIndex(){
        try{searchIndex();}catch(CancellationException ignored){}catch(Exception e){android.util.Log.w("AarisSearch","Quran search warm-up failed",e);}
    }
    void notifyOperationChanged(){
        if(Looper.myLooper()==Looper.getMainLooper()){
            Runnable current=operationChanged;if(current!=null)current.run();
        }else main.post(()->{Runnable current=operationChanged;if(current!=null)current.run();});
    }
    void ready(Runnable callback){
        if(callback==null)return;
        if(ready.getCount()==0){main.post(callback);return;}
        io.execute(()->{try{ready.await();main.post(callback);}catch(InterruptedException e){Thread.currentThread().interrupt();}});
    }
}
