package com.aaris.quran;

import android.os.Handler;
import android.os.Looper;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Explicit user-initiated downloader for immutable isolated-word Surah containers. */
final class QuranAudioDownloadManager {
    interface Listener {
        void onProgress(int surah,int completed,int total);
        void onComplete();
        void onError(int surah,String message);
    }
    private static final String REPO="warishakhan3548-hash/updating-repository";
    private static final String REVISION=QuranAudioStore.SOURCE_REVISION;
    private static final int CONNECT_TIMEOUT_MS=20_000;
    private static final int READ_TIMEOUT_MS=60_000;
    private static final int MAX_ATTEMPTS=3;
    private static final long RETRY_BASE_MS=1_000L;
    private static final long STORAGE_HEADROOM_BYTES=16L*1024L*1024L;

    private final QuranAudioStore store;
    private final ExecutorService io;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final AtomicBoolean busy=new AtomicBoolean(false);
    private final Object connectionLock=new Object();
    private volatile boolean cancel;
    private HttpURLConnection activeConnection;

    QuranAudioDownloadManager(QuranAudioStore store,ExecutorService io){this.store=store;this.io=io;}
    boolean busy(){return busy.get();}
    void cancel(){
        cancel=true;
        HttpURLConnection connection;
        synchronized(connectionLock){connection=activeConnection;}
        if(connection!=null)connection.disconnect();
    }

    void downloadSurah(int surah,Listener listener){
        if(surah<1||surah>114){postError(listener,surah,"Invalid Surah");return;}
        if(!busy.compareAndSet(false,true)){postError(listener,surah,"Audio download is already running");return;}
        cancel=false;
        try{
            io.execute(()->{
                String failure=null;
                try{
                    if(!store.installedSurah(surah))downloadOne(surah);
                    if(cancel)throw new IOException("Download cancelled");
                    postProgress(listener,surah,1,1);
                }catch(Exception e){failure=safeMessage(e);}
                finally{busy.set(false);}
                if(failure==null)postComplete(listener);else postError(listener,surah,failure);
            });
        }catch(RejectedExecutionException rejected){
            busy.set(false);
            postError(listener,surah,"Audio download could not start");
        }
    }

    void downloadAll(Listener listener){
        if(!busy.compareAndSet(false,true)){postError(listener,0,"Audio download is already running");return;}
        cancel=false;
        try{
            io.execute(()->{
                int completed=0,current=1;String failure=null;
                try{
                    for(current=1;current<=114;current++){
                        if(cancel)throw new IOException("Download cancelled");
                        if(!store.installedSurah(current))downloadOne(current);
                        completed++;postProgress(listener,current,completed,114);
                    }
                }catch(Exception e){failure=safeMessage(e);}
                finally{busy.set(false);}
                if(failure==null)postComplete(listener);else postError(listener,current,failure);
            });
        }catch(RejectedExecutionException rejected){
            busy.set(false);
            postError(listener,0,"Audio download could not start");
        }
    }

    private void downloadOne(int surah) throws Exception {
        QuranAudioStore.PackMeta meta=store.meta(surah);
        if(meta==null)throw new IOException("Surah pronunciation catalog missing");
        File partial=store.partialFile(surah);
        downloadResumable(meta.url,partial,meta.bytes);
        if(cancel)throw new IOException("Download cancelled");
        try{store.installDownloaded(surah,partial);}
        catch(Exception invalid){partial.delete();throw invalid;}
        if(!store.installedSurah(surah))throw new IOException("Installed Surah pronunciation verification failed");
    }

    private void downloadResumable(String address,File target,long expectedBytes) throws IOException {
        IOException last=null;
        for(int attempt=1;attempt<=MAX_ATTEMPTS;attempt++){
            if(cancel)throw new IOException("Download cancelled");
            try{downloadAttempt(address,target,expectedBytes);return;}
            catch(IOException failure){
                last=failure;
                if(cancel)throw new IOException("Download cancelled",failure);
                if(attempt==MAX_ATTEMPTS)throw failure;
                try{Thread.sleep(RETRY_BASE_MS*attempt);}
                catch(InterruptedException x){Thread.currentThread().interrupt();throw new IOException("Audio download interrupted",x);}
            }
        }
        throw last==null?new IOException("Audio download did not complete"):last;
    }

    private void downloadAttempt(String address,File target,long expectedBytes) throws IOException {
        if(expectedBytes<64)throw new IOException("Invalid expected Surah pronunciation size");
        File parent=target.getParentFile();
        if(parent==null||(!parent.exists()&&!parent.mkdirs()))throw new IOException("Temporary audio storage is not available");
        long existing=target.isFile()?target.length():0L;
        if(existing==expectedBytes)return;
        if(existing<0||existing>expectedBytes){if(target.exists()&&!target.delete())throw new IOException("Invalid partial audio could not be cleared");existing=0;}

        boolean restarted=false;
        while(true){
            if(cancel)throw new IOException("Download cancelled");
            HttpURLConnection c=(HttpURLConnection)new URL(address).openConnection();
            c.setInstanceFollowRedirects(true);c.setConnectTimeout(CONNECT_TIMEOUT_MS);c.setReadTimeout(READ_TIMEOUT_MS);
            c.setRequestProperty("Accept-Encoding","identity");c.setRequestProperty("User-Agent","Aaris-Quran/0.4 isolated-word-audio");
            if(existing>0)c.setRequestProperty("Range","bytes="+existing+"-");
            synchronized(connectionLock){
                if(cancel){c.disconnect();throw new IOException("Download cancelled");}
                activeConnection=c;
            }
            try{
                int code=c.getResponseCode();
                if(!"https".equalsIgnoreCase(c.getURL().getProtocol()))throw new IOException("Audio download redirected away from HTTPS");
                if(existing>0&&code==416&&!restarted){
                    if(target.exists()&&!target.delete())throw new IOException("Stale partial audio could not be cleared");
                    existing=0;restarted=true;continue;
                }
                if(code!=200&&code!=206)throw new IOException("Audio server HTTP "+code);
                boolean append=existing>0&&code==206;
                if(append){
                    String range=c.getHeaderField("Content-Range"),prefix="bytes "+existing+"-";
                    if(range==null||!range.startsWith(prefix)){
                        if(target.exists()&&!target.delete())throw new IOException("Mismatched partial audio could not be cleared");
                        existing=0;restarted=true;continue;
                    }
                }else if(existing>0){existing=0;}

                long declared=c.getContentLengthLong();
                long finalDeclared=declared<0?-1:(append?existing+declared:declared);
                if(finalDeclared>expectedBytes)throw new IOException("Surah pronunciation is larger than the verified catalog size");
                long needed=Math.max(0,expectedBytes-(append?existing:0))+STORAGE_HEADROOM_BYTES;
                long usable=parent.getUsableSpace();
                if(usable>0&&usable<needed)throw new IOException("Not enough phone storage for this audio download");

                long received=0;
                try(InputStream in=new BufferedInputStream(c.getInputStream());FileOutputStream out=new FileOutputStream(target,append)){
                    byte[] b=new byte[64*1024];int n;
                    while((n=in.read(b))!=-1){
                        if(cancel)throw new IOException("Download cancelled");
                        received+=n;long total=(append?existing:0)+received;
                        if(total>expectedBytes)throw new IOException("Downloaded pronunciation is larger than the verified catalog size");
                        out.write(b,0,n);
                    }
                    out.getFD().sync();
                }
                if(declared>=0&&received!=declared)throw new IOException("Audio download was interrupted; retry will resume it");
                if(target.length()!=expectedBytes)throw new IOException("Audio download is incomplete; retry will resume it");
                return;
            }finally{
                synchronized(connectionLock){if(activeConnection==c)activeConnection=null;}
                c.disconnect();
            }
        }
    }

    private void postProgress(Listener l,int surah,int completed,int total){if(l!=null)main.post(()->l.onProgress(surah,completed,total));}
    private void postComplete(Listener l){if(l!=null)main.post(l::onComplete);}
    private void postError(Listener l,int surah,String message){if(l!=null)main.post(()->l.onError(surah,message));}
    private static String safeMessage(Exception e){String m=e.getMessage();return m==null||m.trim().isEmpty()?"Audio download did not complete":m;}
}
