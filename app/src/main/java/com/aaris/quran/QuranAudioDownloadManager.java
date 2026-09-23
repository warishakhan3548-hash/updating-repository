package com.aaris.quran;

import android.os.Handler;
import android.os.Looper;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
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
    private volatile boolean cancel;

    QuranAudioDownloadManager(QuranAudioStore store,ExecutorService io){this.store=store;this.io=io;}
    boolean busy(){return busy.get();}
    void cancel(){cancel=true;}

    void downloadSurah(int surah,Listener listener){
        if(surah<1||surah>114){postError(listener,surah,"Invalid Surah");return;}
        if(!busy.compareAndSet(false,true)){postError(listener,surah,"Audio download already chal raha hai");return;}
        cancel=false;io.execute(()->{
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
        cancel=false;io.execute(()->{
            int completed=0,current=1;
            try{
                for(current=1;current<=114;current++){
                    if(cancel)throw new IOException("Download cancelled");
                    if(!store.installedSurah(current))downloadOne(current);
                    completed++;postProgress(listener,current,completed,114);
                }
                postComplete(listener);
            }catch(Exception e){postError(listener,current,safeMessage(e));}
            finally{busy.set(false);}
        });
    }

    private void downloadOne(int surah) throws Exception {
        QuranAudioStore.PackMeta meta=store.meta(surah);
        if(meta==null)throw new IOException("Surah pronunciation catalog missing");
        File partial=store.partialFile(surah);
        downloadResumable(meta.url,partial,meta.bytes);
        if(cancel)throw new IOException("Download cancelled");
        try{store.installDownloaded(surah,partial);}
        catch(Exception invalid){partial.delete();throw invalid;}
        if(!store.installedSurah(surah))throw new IOException("Installed Surah pronunciation verification fail hui");
    }

    private void downloadResumable(String address,File target,long expectedBytes) throws IOException {
        IOException last=null;
        for(int attempt=1;attempt<=MAX_ATTEMPTS;attempt++){
            if(cancel)throw new IOException("Download cancelled");
            try{downloadAttempt(address,target,expectedBytes);return;}
            catch(IOException failure){
                last=failure;if(cancel||attempt==MAX_ATTEMPTS)throw failure;
                try{Thread.sleep(RETRY_BASE_MS*attempt);}
                catch(InterruptedException x){Thread.currentThread().interrupt();throw new IOException("Audio download interrupted",x);}
            }
        }
        throw last==null?new IOException("Audio download complete nahi hua"):last;
    }

    private void downloadAttempt(String address,File target,long expectedBytes) throws IOException {
        if(expectedBytes<64)throw new IOException("Invalid expected Surah pronunciation size");
        File parent=target.getParentFile();
        if(parent==null||(!parent.exists()&&!parent.mkdirs()))throw new IOException("Audio temporary storage available nahi hai");
        long existing=target.isFile()?target.length():0L;
        if(existing==expectedBytes)return;
        if(existing<0||existing>expectedBytes){if(target.exists()&&!target.delete())throw new IOException("Invalid partial audio clear nahi hua");existing=0;}

        boolean restarted=false;
        while(true){
            if(cancel)throw new IOException("Download cancelled");
            HttpURLConnection c=(HttpURLConnection)new URL(address).openConnection();
            c.setInstanceFollowRedirects(true);c.setConnectTimeout(CONNECT_TIMEOUT_MS);c.setReadTimeout(READ_TIMEOUT_MS);
            c.setRequestProperty("Accept-Encoding","identity");c.setRequestProperty("User-Agent","Aaris-Quran/0.4 isolated-word-audio");
            if(existing>0)c.setRequestProperty("Range","bytes="+existing+"-");
            try{
                int code=c.getResponseCode();
                if(!"https".equalsIgnoreCase(c.getURL().getProtocol()))throw new IOException("Audio download HTTPS se bahar redirect hua");
                if(existing>0&&code==416&&!restarted){
                    if(target.exists()&&!target.delete())throw new IOException("Stale partial audio clear nahi hua");
                    existing=0;restarted=true;continue;
                }
                if(code!=200&&code!=206)throw new IOException("Audio server HTTP "+code);
                boolean append=existing>0&&code==206;
                if(append){
                    String range=c.getHeaderField("Content-Range"),prefix="bytes "+existing+"-";
                    if(range==null||!range.startsWith(prefix)){
                        if(target.exists()&&!target.delete())throw new IOException("Mismatched partial audio clear nahi hua");
                        existing=0;restarted=true;continue;
                    }
                }else if(existing>0){existing=0;}

                long declared=c.getContentLengthLong();
                long finalDeclared=declared<0?-1:(append?existing+declared:declared);
                if(finalDeclared>expectedBytes)throw new IOException("Surah pronunciation expected size se badi hai");
                long needed=Math.max(0,expectedBytes-(append?existing:0))+STORAGE_HEADROOM_BYTES;
                long usable=parent.getUsableSpace();
                if(usable>0&&usable<needed)throw new IOException("Phone storage kam hai; audio download ke liye jagah khaali karein");

                long received=0;
                try(InputStream in=new BufferedInputStream(c.getInputStream());FileOutputStream out=new FileOutputStream(target,append)){
                    byte[] b=new byte[64*1024];int n;
                    while((n=in.read(b))!=-1){
                        if(cancel)throw new IOException("Download cancelled");
                        received+=n;long total=(append?existing:0)+received;
                        if(total>expectedBytes)throw new IOException("Downloaded pronunciation expected size se badi hai");
                        out.write(b,0,n);
                    }
                    out.getFD().sync();
                }
                if(declared>=0&&received!=declared)throw new IOException("Audio download beech mein ruk gaya; retry par resume hoga");
                if(target.length()!=expectedBytes)throw new IOException("Audio download incomplete hai; retry par resume hoga");
                return;
            }finally{c.disconnect();}
        }
    }

    private void postProgress(Listener l,int surah,int completed,int total){if(l!=null)main.post(()->l.onProgress(surah,completed,total));}
    private void postComplete(Listener l){if(l!=null)main.post(l::onComplete);}
    private void postError(Listener l,int surah,String message){if(l!=null)main.post(()->l.onError(surah,message));}
    private static String safeMessage(Exception e){String m=e.getMessage();return m==null||m.trim().isEmpty()?"Audio download complete nahi hua":m;}
}
