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
 *
 * Interrupted downloads are intentionally kept under a revision-scoped .partial directory.
 * Retrying the same Surah uses HTTP Range when supported; if the origin ignores Range, the file is
 * safely restarted from byte zero. A partial directory is never considered installed/playable.
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
    private static final int MAX_ATTEMPTS=3;
    private static final long RETRY_BASE_MS=1_000L;
    private static final long MAX_SURAH_AUDIO_BYTES=40L*1024L*1024L;
    private static final long MAX_TIMING_BYTES=8L*1024L*1024L;
    private static final long STORAGE_HEADROOM_BYTES=16L*1024L*1024L;

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
        // Revision in the directory name prevents a future source upgrade from resuming old bytes.
        File staging=new File(root,".partial-"+REVISION.substring(0,12)+"-"+number);
        File finalDir=store.surahDir(surah);
        if(!staging.exists()&&!staging.mkdirs())throw new IOException("Temporary audio folder nahi ban saka");
        if(!staging.isDirectory())throw new IOException("Temporary audio path invalid hai");

        File audio=new File(staging,number+".opus");
        File timing=new File(staging,number+".pb");

        downloadResumable(BASE+number+"/"+number+".opus?download=true",audio,MAX_SURAH_AUDIO_BYTES);
        if(cancel)throw new IOException("Download cancelled");
        downloadResumable(BASE+number+"/"+number+".pb?download=true",timing,MAX_TIMING_BYTES);
        if(cancel)throw new IOException("Download cancelled");

        try{
            QuranAudioStore.validateSurahFiles(audio,timing,surah);
        }catch(IOException invalid){
            // Structurally invalid complete bytes must never be repeatedly resumed/reused.
            deleteRecursive(staging);
            throw invalid;
        }

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
        if(!store.installedSurah(surah)){
            // Do not leave an unplayable directory looking installed.
            deleteRecursive(finalDir);
            throw new IOException("Installed Surah audio verification fail hui");
        }
    }

    private void downloadResumable(String address,File target,long maxBytes) throws IOException {
        IOException last=null;
        for(int attempt=1;attempt<=MAX_ATTEMPTS;attempt++){
            if(cancel)throw new IOException("Download cancelled");
            try{
                downloadAttempt(address,target,maxBytes);
                return;
            }catch(IOException failure){
                last=failure;
                if(cancel||attempt==MAX_ATTEMPTS)throw failure;
                try{Thread.sleep(RETRY_BASE_MS*attempt);}
                catch(InterruptedException interrupted){
                    Thread.currentThread().interrupt();
                    throw new IOException("Audio download interrupted",interrupted);
                }
            }
        }
        throw last==null?new IOException("Audio download complete nahi hua"):last;
    }

    private void downloadAttempt(String address,File target,long maxBytes) throws IOException {
        File parent=target.getParentFile();
        if(parent==null||(!parent.exists()&&!parent.mkdirs()))
            throw new IOException("Audio temporary storage available nahi hai");

        long existing=target.isFile()?target.length():0L;
        if(existing<0||existing>maxBytes){
            if(target.exists()&&!target.delete())throw new IOException("Invalid partial audio clear nahi hua");
            existing=0L;
        }

        boolean restartedAfterRangeFailure=false;
        while(true){
            if(cancel)throw new IOException("Download cancelled");
            HttpURLConnection connection=(HttpURLConnection)new URL(address).openConnection();
            connection.setInstanceFollowRedirects(true);
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setRequestProperty("Accept-Encoding","identity");
            connection.setRequestProperty("User-Agent","Aaris-Quran/0.3 audio-pack");
            if(existing>0)connection.setRequestProperty("Range","bytes="+existing+"-");

            try{
                int code=connection.getResponseCode();
                if(!"https".equalsIgnoreCase(connection.getURL().getProtocol()))
                    throw new IOException("Audio download HTTPS se bahar redirect hua");

                if(existing>0&&code==416&&!restartedAfterRangeFailure){
                    connection.disconnect();
                    if(target.exists()&&!target.delete())throw new IOException("Stale partial audio clear nahi hua");
                    existing=0L;restartedAfterRangeFailure=true;
                    continue;
                }
                if(code!=200&&code!=206)throw new IOException("Audio server HTTP "+code);

                boolean append=existing>0&&code==206;
                if(append){
                    String range=connection.getHeaderField("Content-Range");
                    String expectedPrefix="bytes "+existing+"-";
                    if(range==null||!range.startsWith(expectedPrefix)){
                        connection.disconnect();
                        if(target.exists()&&!target.delete())throw new IOException("Mismatched partial audio clear nahi hua");
                        existing=0L;restartedAfterRangeFailure=true;
                        continue;
                    }
                }else if(existing>0){
                    // Origin ignored Range and returned a full 200 response. Restart safely.
                    existing=0L;
                }

                long declared=connection.getContentLengthLong();
                long finalDeclared=declared<0?-1L:(append?existing+declared:declared);
                if(finalDeclared>maxBytes)
                    throw new IOException("Surah audio file expected limit se badi hai");
                if(declared>0){
                    long needed=Math.max(0L,declared)+STORAGE_HEADROOM_BYTES;
                    long usable=parent.getUsableSpace();
                    if(usable>0&&usable<needed)
                        throw new IOException("Phone storage kam hai; audio download ke liye jagah khaali karein");
                }

                long received=0L;
                try(InputStream in=new BufferedInputStream(connection.getInputStream());
                    FileOutputStream out=new FileOutputStream(target,append)){
                    byte[] buffer=new byte[64*1024];int n;
                    while((n=in.read(buffer))!=-1){
                        if(cancel)throw new IOException("Download cancelled");
                        received+=n;
                        long total=(append?existing:0L)+received;
                        if(total>maxBytes)throw new IOException("Downloaded audio file size limit se badi hai");
                        out.write(buffer,0,n);
                    }
                    out.getFD().sync();
                }
                if(declared>=0&&received!=declared)
                    throw new IOException("Audio download beech mein ruk gaya; retry par resume hoga");
                if(!target.isFile()||target.length()<2)
                    throw new IOException("Downloaded audio file empty hai");
                return;
            }finally{
                connection.disconnect();
            }
        }
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
