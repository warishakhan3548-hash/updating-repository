package com.aaris.quran;

import android.os.Handler;
import android.os.Looper;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Explicit user-initiated downloader for Quran recitation packs.
 *
 * Normal app reading, Hadith, search and recall never need the network. This class is the only
 * runtime network boundary: it downloads one immutable full-Surah Opus file plus its word timing
 * protobuf, validates both, then atomically installs them in app-private storage.
 */
final class QuranAudioDownloadManager {
    interface Listener {
        void onProgress(int surah,int completed,int total);
        void onComplete();
        void onError(int surah,String message);
    }

    private static final String REPO="zaibihassan/Quranic-Recitation-Data";
    private static final String REVISION=QuranAudioStore.SOURCE_REVISION;
    private static final String FOLDER="Abdul%20Basit%20Abdul%20Samad%20%28Mujawwad%29";
    private static final String BASE="https://huggingface.co/datasets/"+REPO+"/resolve/"+REVISION+"/"+FOLDER+"/";
    private static final int CONNECT_TIMEOUT_MS=20_000;
    private static final int READ_TIMEOUT_MS=60_000;
    private static final long MAX_SURAH_AUDIO_BYTES=40L*1024L*1024L;
    private static final long MAX_TIMING_BYTES=8L*1024L*1024L;

    private final QuranAudioStore store;
    private final ExecutorService io;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final AtomicBoolean busy=new AtomicBoolean(false);
    private volatile boolean cancel;

    QuranAudioDownloadManager(QuranAudioStore store,ExecutorService io){
        this.store=store;this.io=io;
    }

    boolean busy(){return busy.get();}
    void cancel(){cancel=true;}

    void downloadSurah(int surah,Listener listener){
        if(surah<1||surah>114){postError(listener,surah,"Invalid Surah");return;}
        if(!busy.compareAndSet(false,true)){postError(listener,surah,"Audio download already chal raha hai");return;}
        cancel=false;
        io.execute(()->{
            try{
                if(!store.installedSurah(surah))downloadOne(surah);
                if(cancel)throw new IOException("Download cancelled");
                postProgress(listener,surah,1,1);postComplete(listener);
            }catch(Exception e){postError(listener,surah,safeMessage(e));}
            finally{busy.set(false);}
        });
    }

    void downloadAll(Listener listener){
        if(!busy.compareAndSet(false,true)){postError(listener,0,"Audio download already chal raha hai");return;}
        cancel=false;
        io.execute(()->{
            int completed=0,current=1;
            try{
                for(current=1;current<=114;current++){
                    if(cancel)throw new IOException("Download cancelled");
                    if(!store.installedSurah(current))downloadOne(current);
                    completed++;
                    postProgress(listener,current,completed,114);
                }
                postComplete(listener);
            }catch(Exception e){postError(listener,current,safeMessage(e));}
            finally{busy.set(false);}
        });
    }

    private void downloadOne(int surah) throws Exception {
        String number=String.format(Locale.ROOT,"%03d",surah);
        File root=store.root();
        File staging=new File(root,".staging-"+number+"-"+System.nanoTime());
        File finalDir=store.surahDir(surah);
        deleteRecursive(staging);
        if(!staging.mkdirs())throw new IOException("Temporary audio folder nahi ban saka");
        File audio=new File(staging,number+".opus");
        File timing=new File(staging,number+".pb");
        try{
            download(BASE+number+"/"+number+".opus?download=true",audio,MAX_SURAH_AUDIO_BYTES);
            if(cancel)throw new IOException("Download cancelled");
            download(BASE+number+"/"+number+".pb?download=true",timing,MAX_TIMING_BYTES);
            if(cancel)throw new IOException("Download cancelled");
            QuranAudioStore.validateSurahFiles(audio,timing,surah);

            File old=new File(root,".old-"+number);
            deleteRecursive(old);
            if(finalDir.exists()&&!finalDir.renameTo(old))
                throw new IOException("Purana Surah audio replace nahi ho saka");
            if(!staging.renameTo(finalDir)){
                if(old.exists())old.renameTo(finalDir);
                throw new IOException("Verified Surah audio install nahi ho saka");
            }
            deleteRecursive(old);
            store.refreshSurah(surah);
            if(!store.installedSurah(surah))
                throw new IOException("Installed Surah audio verification fail hui");
        }finally{
            deleteRecursive(staging);
        }
    }

    private void download(String address,File target,long maxBytes) throws IOException {
        HttpURLConnection connection=(HttpURLConnection)new URL(address).openConnection();
        connection.setInstanceFollowRedirects(true);
        connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
        connection.setReadTimeout(READ_TIMEOUT_MS);
        connection.setRequestProperty("Accept-Encoding","identity");
        connection.setRequestProperty("User-Agent","Aaris-Quran/0.3 audio-pack");
        try{
            int code=connection.getResponseCode();
            if(code<200||code>=300)throw new IOException("Audio server HTTP "+code);
            if(!"https".equalsIgnoreCase(connection.getURL().getProtocol()))
                throw new IOException("Audio download HTTPS se bahar redirect hua");
            long declared=connection.getContentLengthLong();
            if(declared>maxBytes)throw new IOException("Surah audio file expected limit se badi hai");
            try(InputStream in=new BufferedInputStream(connection.getInputStream());
                FileOutputStream out=new FileOutputStream(target)){
                byte[] buffer=new byte[64*1024];int n;long total=0;
                while((n=in.read(buffer))!=-1){
                    if(cancel)throw new IOException("Download cancelled");
                    total+=n;if(total>maxBytes)throw new IOException("Downloaded audio file size limit se badi hai");
                    out.write(buffer,0,n);
                }
                out.getFD().sync();
                if(total<2)throw new IOException("Downloaded audio file empty hai");
            }
        }finally{connection.disconnect();}
    }

    private void postProgress(Listener l,int surah,int completed,int total){
        if(l!=null)main.post(()->l.onProgress(surah,completed,total));
    }
    private void postComplete(Listener l){if(l!=null)main.post(l::onComplete);}
    private void postError(Listener l,int surah,String message){if(l!=null)main.post(()->l.onError(surah,message));}
    private static String safeMessage(Exception e){
        String m=e.getMessage();return m==null||m.trim().isEmpty()?"Audio download complete nahi hua":m;
    }
    private static void deleteRecursive(File file){
        if(file==null||!file.exists())return;
        if(file.isDirectory()){
            File[] children=file.listFiles();
            if(children!=null)for(File child:children)deleteRecursive(child);
        }
        file.delete();
    }
}
