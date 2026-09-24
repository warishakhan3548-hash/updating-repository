package com.aaris.quran;

import android.content.Context;
import android.media.MediaMetadataRetriever;
import com.aaris.quran.core.Ayah;
import com.aaris.quran.core.RecitationAddress;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;

/** Optional whole-ayah audio. Core content builds never fetch this remote catalog. */
final class RecitationDownloads {
    static final String[] IDS={"ar.alafasy","ar.husary","ar.minshawi"};
    static final String[] NAMES={"Mishary Rashid Alafasy","Mahmoud Khalil Al-Husary","Mohamed Siddiq al-Minshawi"};
    static final String ATTRIBUTION="Recitations: Islamic Network / AlQuran.cloud; copyright remains with each reciter. Free non-commercial educational use. https://alquran.cloud/terms-and-conditions";
    private static final int LOCK_STRIPES=64;
    private final File root;
    private final Object[] locks=new Object[LOCK_STRIPES];
    private final Map<String,long[]> completionCache=new java.util.concurrent.ConcurrentHashMap<>();
    private final Set<String> missingCompletions=java.util.concurrent.ConcurrentHashMap.newKeySet();
    volatile boolean cancelled,busy;
    volatile String progress="";
    // v1 cached ordinal-1 audio under the requested coordinate. Its hashes only verify bytes,
    // not verse identity, so those files must never be reused by the corrected mapping.
    RecitationDownloads(Context c){
        root=new File(c.getFilesDir(),"recitations-v2-coordinate");
        for(int i=0;i<locks.length;i++)locks[i]=new Object();
    }
    static int index(String id){for(int i=0;i<IDS.length;i++)if(IDS[i].equals(id))return i;return 0;}
    static String valid(String id){return IDS[index(id)];}
    private Object lockFor(String key){return locks[(key.hashCode()&0x7fffffff)%locks.length];}
    private File folder(String reciter,int surah){return new File(new File(root,valid(reciter)),""+surah);}
    private File file(String reciter,Ayah a){return new File(folder(reciter,a.surah),a.number+".mp3");}
    private File hashFile(String reciter,Ayah a){return new File(folder(reciter,a.surah),a.number+".sha256");}
    private String completionKey(String reciter,int surah){return valid(reciter)+":"+surah;}
    private void invalidateCompletion(String reciter,int surah){
        String key=completionKey(reciter,surah);completionCache.remove(key);missingCompletions.remove(key);
    }
    private long[] completionLengths(String reciter,int surah,int ayahs){
        String key=completionKey(reciter,surah);long[] cached=completionCache.get(key);
        if(cached!=null)return cached.length==ayahs+1?cached:null;
        if(missingCompletions.contains(key))return null;
        File marker=new File(folder(reciter,surah),"complete.json");
        if(!marker.isFile()){missingCompletions.add(key);return null;}
        try{
            JSONObject m=new JSONObject(new String(java.nio.file.Files.readAllBytes(marker.toPath()),StandardCharsets.UTF_8));
            if(m.length()!=ayahs){missingCompletions.add(key);return null;}
            long[] lengths=new long[ayahs+1];
            for(int i=1;i<=ayahs;i++){long length=m.optLong(""+i,-1);if(length<512){missingCompletions.add(key);return null;}lengths[i]=length;}
            completionCache.put(key,lengths);missingCompletions.remove(key);return lengths;
        }catch(Exception e){missingCompletions.add(key);return null;}
    }
    /** Fast list-state check: parse a completion marker once per process, then use memory. */
    boolean markedComplete(String reciter,int surah,int ayahs){return completionLengths(reciter,surah,ayahs)!=null;}
    /** O(1) playback readiness: validate only the requested ayah against the completed-Surah marker. */
    boolean ayahReady(String reciter,Ayah ayah,int ayahs){
        long[] lengths=completionLengths(reciter,ayah.surah,ayahs);if(lengths==null)return false;File audio=file(reciter,ayah);
        return audio.isFile()&&audio.length()==lengths[ayah.number];
    }
    /** Strong whole-Surah verification. Run on the download worker, never a render hot path. */
    boolean ready(String reciter,int surah,int ayahs){
        long[] lengths=completionLengths(reciter,surah,ayahs);if(lengths==null)return false;File directory=folder(reciter,surah);
        for(int i=1;i<=ayahs;i++){File audio=new File(directory,i+".mp3");if(!audio.isFile()||audio.length()!=lengths[i])return false;}return true;
    }
    File obtain(String reciter,Ayah a)throws Exception{
        int globalNumber=RecitationAddress.globalNumber(a);
        reciter=valid(reciter);Object lock=lockFor(reciter+":"+a.id);
        synchronized(lock){
            File target=file(reciter,a),hash=hashFile(reciter,a),directory=target.getParentFile();
            if(target.isFile()&&hash.isFile()){
                String expected=new String(java.nio.file.Files.readAllBytes(hash.toPath()),StandardCharsets.UTF_8).trim();
                if(expected.equals(ContentStore.hash(target)))return target;
            }
            File completion=new File(directory,"complete.json");
            invalidateCompletion(reciter,a.surah);
            if(completion.exists()&&!completion.delete())throw new IOException("Could not invalidate stale Surah completion state");
            if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("Audio storage unavailable");
            File temporary=new File(directory,a.number+".download");
            URL url=new URL("https://cdn.islamic.network/quran/audio/128/"+reciter+"/"+globalNumber+".mp3");
            HttpURLConnection connection=(HttpURLConnection)url.openConnection();connection.setConnectTimeout(15000);connection.setReadTimeout(30000);connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("Accept-Encoding","identity");connection.setRequestProperty("User-Agent","Aaris-Quran/0.4 recitation");
            try{
                int response=connection.getResponseCode();
                if(response!=200)throw new IOException("Reciter source unavailable ("+response+")");
                long expected=connection.getContentLengthLong();if(expected>20*1024*1024)throw new IOException("Unexpected audio size");long count=0;
                try(InputStream in=connection.getInputStream();FileOutputStream out=new FileOutputStream(temporary)){byte[] b=new byte[32768];int n;while((n=in.read(b))!=-1){if(Thread.currentThread().isInterrupted())throw new InterruptedIOException();count+=n;if(count>20*1024*1024)throw new IOException("Audio too large");out.write(b,0,n);}out.getFD().sync();}
                if(count<512||expected>=0&&count!=expected)throw new IOException("Incomplete audio");
                MediaMetadataRetriever media=new MediaMetadataRetriever();try{media.setDataSource(temporary.getAbsolutePath());String duration=media.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);if(duration==null||Long.parseLong(duration)<=0)throw new IOException("Invalid audio file");}finally{media.release();}
                String sha=ContentStore.hash(temporary);if(target.exists()&&!target.delete())throw new IOException("Could not replace audio");if(!temporary.renameTo(target))throw new IOException("Could not install audio");
                // Local digest detects corruption after acquisition, not an upstream authenticity signature.
                try(FileOutputStream out=new FileOutputStream(hash)){out.write(sha.getBytes(StandardCharsets.UTF_8));out.getFD().sync();}return target;
            }finally{connection.disconnect();temporary.delete();}
        }
    }
    void download(ContentStore content,String reciter,int startSurah,int endSurah,Runnable changed)throws Exception{
        synchronized(this){if(busy)throw new IOException("Another recitation download is running");busy=true;cancelled=false;}
        long lastProgressNanos=0L;
        try{for(int s=startSurah;s<=endSurah&&!cancelled;s++){
            JSONObject completed=new JSONObject();int count=content.surah(s).count;
            for(int a=1;a<=count&&!cancelled;a++){
                Ayah ayah=content.ayah("Q:"+s+":"+a);File file=obtain(reciter,ayah);completed.put(""+a,file.length());
                progress=NAMES[index(reciter)]+" · Surah "+s+" · "+a+"/"+count;
                long now=System.nanoTime();
                if(a==count||lastProgressNanos==0L||now-lastProgressNanos>=250_000_000L){lastProgressNanos=now;changed.run();}
            }
            if(!cancelled){File temp=new File(folder(reciter,s),"complete.tmp"),target=new File(folder(reciter,s),"complete.json");try(FileOutputStream out=new FileOutputStream(temp)){out.write(completed.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}invalidateCompletion(reciter,s);if(target.exists()&&!target.delete())throw new IOException("Could not replace Surah completion state");if(!temp.renameTo(target))throw new IOException("Could not finish Surah download");if(!ready(reciter,s,count)){target.delete();invalidateCompletion(reciter,s);throw new IOException("Downloaded Surah verification failed");}}
        }progress=cancelled?"Download paused · completed ayahs are kept":"Download complete";
        }finally{busy=false;changed.run();}
    }
}
