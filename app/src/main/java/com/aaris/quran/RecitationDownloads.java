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
    private static final long MAX_AUDIO_BYTES=20L*1024L*1024L;
    private static final long STORAGE_HEADROOM_BYTES=8L*1024L*1024L;
    private final File root;
    private final Object[] locks=new Object[LOCK_STRIPES];
    private final Object batchConnectionLock=new Object();
    private final Object playbackConnectionLock=new Object();
    private final Map<String,long[]> completionCache=new java.util.concurrent.ConcurrentHashMap<>();
    private final Set<String> missingCompletions=java.util.concurrent.ConcurrentHashMap.newKeySet();
    private volatile boolean cancelled;
    private HttpURLConnection activeBatchConnection;
    private HttpURLConnection activePlaybackConnection;
    volatile boolean busy;
    volatile String progress="";
    // v1 cached ordinal-1 audio under the requested coordinate. Its hashes only verify bytes,
    // not verse identity, so those files must never be reused by the corrected mapping.
    private final File legacyRoot;
    RecitationDownloads(Context c){
        root=new File(c.getFilesDir(),"recitations-v2-coordinate");
        legacyRoot=new File(c.getFilesDir(),"recitations-v1");
        for(int i=0;i<locks.length;i++)locks[i]=new Object();
    }
    /** v1 used ordinal-1 audio under verse coordinates, so its bytes are never valid fallback data. */
    void cleanupLegacyCache(){
        deleteTree(legacyRoot);
    }
    private static void deleteTree(File root){
        if(root==null||!root.exists())return;
        File[] children=root.listFiles();
        if(children!=null)for(File child:children){
            if(child.isDirectory())deleteTree(child);else child.delete();
        }
        root.delete();
    }
    static int index(String id){for(int i=0;i<IDS.length;i++)if(IDS[i].equals(id))return i;return 0;}
    static String valid(String id){return IDS[index(id)];}
    synchronized boolean reserveDownload(){
        if(busy)return false;
        busy=true;cancelled=false;progress="Preparing download…";return true;
    }
    void cancelDownload(){
        cancelled=true;progress="Pausing download…";
        HttpURLConnection connection;
        synchronized(batchConnectionLock){connection=activeBatchConnection;}
        if(connection!=null)connection.disconnect();
    }
    void cancelPlaybackFetch(){
        HttpURLConnection connection;
        synchronized(playbackConnectionLock){connection=activePlaybackConnection;}
        if(connection!=null)connection.disconnect();
    }
    synchronized void releaseDownloadReservation(){busy=false;cancelled=true;progress="Download paused";}
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
    /**
     * Non-blocking completion state for render hot paths.
     *  1 = known complete, 0 = known incomplete/missing, -1 = not checked in this process yet.
     */
    int markedCompleteState(String reciter,int surah,int ayahs){
        String key=completionKey(reciter,surah);
        long[] cached=completionCache.get(key);
        if(cached!=null)return cached.length==ayahs+1?1:0;
        return missingCompletions.contains(key)?0:-1;
    }
    /** Fast list-state check: parse a completion marker once per process, then use memory. */
    boolean markedComplete(String reciter,int surah,int ayahs){return completionLengths(reciter,surah,ayahs)!=null;}
    /** Fast for completed Surahs; paused downloads verify only the requested saved ayah on demand. */
    boolean ayahReady(String reciter,Ayah ayah,int ayahs){
        if(ayah==null||ayah.number<1||ayah.number>ayahs)return false;
        File audio=file(reciter,ayah);
        long[] lengths=completionLengths(reciter,ayah.surah,ayahs);
        if(lengths!=null)return ayah.number<lengths.length&&audio.isFile()&&audio.length()==lengths[ayah.number];

        // A paused Surah has no complete.json by design, but already acquired ayahs retain their
        // digest sidecars. Verify the one requested file so saved reciter audio wins over fallback
        // word clips without scanning the rest of the Surah on the UI thread.
        File digest=hashFile(reciter,ayah);
        if(!audio.isFile()||!digest.isFile())return false;
        try{
            String expected=new String(java.nio.file.Files.readAllBytes(digest.toPath()),StandardCharsets.UTF_8).trim();
            return expected.length()==64&&expected.equals(ContentStore.hash(audio));
        }catch(Exception invalid){return false;}
    }
    /** Strong whole-Surah verification. Run on the download worker, never a render hot path. */
    boolean ready(String reciter,int surah,int ayahs){
        long[] lengths=completionLengths(reciter,surah,ayahs);if(lengths==null)return false;File directory=folder(reciter,surah);
        for(int i=1;i<=ayahs;i++){File audio=new File(directory,i+".mp3");if(!audio.isFile()||audio.length()!=lengths[i])return false;}return true;
    }
    private static final class ResumeState {
        final String validator;final long total;
        ResumeState(String validator,long total){this.validator=validator;this.total=total;}
    }
    private static File resumeFile(File temporary){return new File(temporary.getParentFile(),temporary.getName()+".resume");}
    private static ResumeState readResumeState(File file){
        if(!file.isFile()||file.length()>1024)return null;
        try(DataInputStream in=new DataInputStream(new BufferedInputStream(new FileInputStream(file)))){
            String validator=in.readUTF();long total=in.readLong();
            if(in.read()!=-1||validator.trim().isEmpty()||total>MAX_AUDIO_BYTES||total==0||total<-1)return null;
            return new ResumeState(validator,total);
        }catch(IOException invalid){return null;}
    }
    private static void writeResumeState(File file,String validator,long total)throws IOException{
        if(validator==null||validator.trim().isEmpty()||total>MAX_AUDIO_BYTES||total==0||total<-1){
            if(file.exists()&&!file.delete())throw new IOException("Could not clear stale recitation resume state");
            return;
        }
        File temp=new File(file.getParentFile(),file.getName()+".tmp");
        try{
            try(DataOutputStream out=new DataOutputStream(new BufferedOutputStream(new FileOutputStream(temp)))){
                out.writeUTF(validator);out.writeLong(total);out.flush();
            }
            if(file.exists()&&!file.delete())throw new IOException("Could not replace recitation resume state");
            if(!temp.renameTo(file))throw new IOException("Could not save recitation resume state");
        }finally{if(temp.exists())temp.delete();}
    }
    private static String responseValidator(HttpURLConnection connection){
        String etag=connection.getHeaderField("ETag");
        if(etag!=null){etag=etag.trim();if(!etag.isEmpty()&&!etag.regionMatches(true,0,"W/",0,2))return etag;}
        String modified=connection.getHeaderField("Last-Modified");
        return modified==null||modified.trim().isEmpty()?null:modified.trim();
    }
    private static long contentRangeTotal(String header,long expectedStart)throws IOException{
        if(header==null)throw new IOException("Reciter source returned an invalid partial response");
        String prefix="bytes "+expectedStart+"-";if(!header.startsWith(prefix))throw new IOException("Reciter source returned a mismatched partial response");
        int slash=header.indexOf('/');if(slash<0||slash==header.length()-1)throw new IOException("Reciter source omitted partial size");
        try{
            long total=Long.parseLong(header.substring(slash+1));
            if(total<=expectedStart||total>MAX_AUDIO_BYTES)throw new IOException("Unexpected recitation audio size");
            return total;
        }catch(NumberFormatException malformed){throw new IOException("Reciter source returned an invalid partial size",malformed);}
    }
    private static void clearPartial(File temporary,File resume)throws IOException{
        if(temporary.exists()&&!temporary.delete())throw new IOException("Could not clear stale recitation download");
        if(resume.exists()&&!resume.delete())throw new IOException("Could not clear stale recitation resume state");
    }
    File obtain(String reciter,Ayah a)throws Exception{return obtain(reciter,a,false);}
    private File obtain(String reciter,Ayah a,boolean batchDownload)throws Exception{
        int globalNumber=RecitationAddress.globalNumber(a);
        reciter=valid(reciter);Object lock=lockFor(reciter+":"+a.id);
        synchronized(lock){
            if(Thread.currentThread().isInterrupted())throw new InterruptedIOException(batchDownload?"Download paused":"Playback cancelled");
            if(batchDownload&&cancelled)throw new InterruptedIOException("Download paused");
            File target=file(reciter,a),hash=hashFile(reciter,a),directory=target.getParentFile();
            if(target.isFile()&&hash.isFile()){
                String expected=new String(java.nio.file.Files.readAllBytes(hash.toPath()),StandardCharsets.UTF_8).trim();
                if(expected.equals(ContentStore.hash(target)))return target;
            }
            File completion=new File(directory,"complete.json");
            invalidateCompletion(reciter,a.surah);
            if(completion.exists()&&!completion.delete())throw new IOException("Could not invalidate stale Surah completion state");
            if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("Audio storage unavailable");
            File temporary=new File(directory,a.number+".download"),resume=resumeFile(temporary);
            long existing=temporary.isFile()?temporary.length():0L;ResumeState state=readResumeState(resume);
            if(existing<0||existing>MAX_AUDIO_BYTES||(existing>0&&state==null)){
                clearPartial(temporary,resume);existing=0;state=null;
            }else if(existing==0&&resume.exists()){
                if(!resume.delete())throw new IOException("Could not clear stale recitation resume state");
                state=null;
            }
            boolean transferComplete=existing>=512&&state!=null&&state.total==existing;
            if(!transferComplete){
                boolean restarted=false;
                while(true){
                    if(Thread.currentThread().isInterrupted())throw new InterruptedIOException(batchDownload?"Download paused":"Playback cancelled");
                    if(batchDownload&&cancelled)throw new InterruptedIOException("Download paused");
                    existing=temporary.isFile()?temporary.length():0L;state=readResumeState(resume);
                    if(existing>0&&state==null){clearPartial(temporary,resume);existing=0;}
                    URL url=new URL("https://cdn.islamic.network/quran/audio/128/"+reciter+"/"+globalNumber+".mp3");
                    HttpURLConnection connection=(HttpURLConnection)url.openConnection();connection.setConnectTimeout(15000);connection.setReadTimeout(30000);connection.setInstanceFollowRedirects(true);
                    connection.setRequestProperty("Accept-Encoding","identity");connection.setRequestProperty("User-Agent","Aaris-Quran/0.4 recitation");
                    if(existing>0){
                        connection.setRequestProperty("Range","bytes="+existing+"-");
                        connection.setRequestProperty("If-Range",state.validator);
                    }
                    if(batchDownload){
                        synchronized(batchConnectionLock){
                            if(cancelled){connection.disconnect();throw new InterruptedIOException("Download paused");}
                            activeBatchConnection=connection;
                        }
                    }else{
                        synchronized(playbackConnectionLock){
                            if(Thread.currentThread().isInterrupted()){connection.disconnect();throw new InterruptedIOException("Playback cancelled");}
                            activePlaybackConnection=connection;
                        }
                    }
                    try{
                        int response=connection.getResponseCode();
                        if(!"https".equalsIgnoreCase(connection.getURL().getProtocol()))throw new IOException("Reciter source redirected away from HTTPS");
                        if(existing>0&&response==416&&!restarted){
                            clearPartial(temporary,resume);restarted=true;continue;
                        }
                        if(response!=200&&response!=206)throw new IOException("Reciter source unavailable ("+response+")");
                        if(existing==0&&response==206)throw new IOException("Reciter source returned an unsolicited partial response");
                        boolean append=existing>0&&response==206;
                        long base=append?existing:0L;
                        long declared=connection.getContentLengthLong();
                        long total=response==206?contentRangeTotal(connection.getHeaderField("Content-Range"),existing):
                            (declared>=0?declared:-1L);
                        if(append&&state.total>0&&total!=state.total){
                            clearPartial(temporary,resume);if(!restarted){restarted=true;continue;}
                            throw new IOException("Reciter source changed during resume");
                        }
                        String validator=responseValidator(connection);
                        if(append&&validator!=null&&!validator.equals(state.validator)){
                            clearPartial(temporary,resume);if(!restarted){restarted=true;continue;}
                            throw new IOException("Reciter source changed during resume");
                        }
                        String stableValidator=append?state.validator:validator;
                        writeResumeState(resume,stableValidator,total);
                        long finalDeclared=total>=0?total:(declared<0?-1L:base+declared);
                        if(finalDeclared>MAX_AUDIO_BYTES)throw new IOException("Unexpected audio size");
                        long needed=finalDeclared<0?-1L:Math.max(0L,finalDeclared-base)+STORAGE_HEADROOM_BYTES;
                        long usable=directory.getUsableSpace();
                        if(needed>=0&&usable>0&&usable<needed)throw new IOException("Not enough phone storage for recitation audio");
                        long received=0;
                        try(InputStream in=connection.getInputStream();FileOutputStream out=new FileOutputStream(temporary,append)){
                            byte[] b=new byte[32768];int n;while((n=in.read(b))!=-1){
                                if(Thread.currentThread().isInterrupted()||(batchDownload&&cancelled))throw new InterruptedIOException(batchDownload?"Download paused":"Playback cancelled");
                                received+=n;long count=base+received;if(count>MAX_AUDIO_BYTES){clearPartial(temporary,resume);throw new IOException("Audio too large");}
                                out.write(b,0,n);
                            }out.getFD().sync();
                        }
                        long count=temporary.length();
                        if(declared>=0&&received!=declared)throw new IOException("Incomplete audio; retry will resume");
                        if(total>=0&&count!=total)throw new IOException("Incomplete audio; retry will resume");
                        if(count<512){clearPartial(temporary,resume);throw new IOException("Incomplete audio");}
                        transferComplete=true;break;
                    }finally{
                        if(batchDownload)synchronized(batchConnectionLock){if(activeBatchConnection==connection)activeBatchConnection=null;}
                        else synchronized(playbackConnectionLock){if(activePlaybackConnection==connection)activePlaybackConnection=null;}
                        connection.disconnect();
                    }
                }
            }
            if(!transferComplete)throw new IOException("Incomplete audio");
            try{
                MediaMetadataRetriever media=new MediaMetadataRetriever();try{media.setDataSource(temporary.getAbsolutePath());String duration=media.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);if(duration==null||Long.parseLong(duration)<=0)throw new IOException("Invalid audio file");}finally{media.release();}
            }catch(Exception invalid){clearPartial(temporary,resume);throw invalid;}
            String sha=ContentStore.hash(temporary);
            if(target.exists()&&!target.delete())throw new IOException("Could not replace audio");
            if(!temporary.renameTo(target))throw new IOException("Could not install audio");
            if(resume.exists()&&!resume.delete())throw new IOException("Could not clear completed recitation resume state");
            // Local digest detects corruption after acquisition, not an upstream authenticity signature.
            try(FileOutputStream out=new FileOutputStream(hash)){out.write(sha.getBytes(StandardCharsets.UTF_8));out.getFD().sync();}
            return target;
        }
    }
    void runReservedDownload(ContentStore content,String reciter,int startSurah,int endSurah,Runnable changed)throws Exception{
        synchronized(this){if(!busy)throw new IllegalStateException("Recitation download was not reserved");}
        long lastProgressNanos=0L;
        try{
            for(int s=startSurah;s<=endSurah&&!cancelled;s++){
                JSONObject completed=new JSONObject();int count=content.surah(s).count;
                for(int a=1;a<=count&&!cancelled;a++){
                    Ayah ayah=content.ayah("Q:"+s+":"+a);File file=obtain(reciter,ayah,true);completed.put(""+a,file.length());
                    progress=NAMES[index(reciter)]+" · Surah "+s+" · "+a+"/"+count;
                    long now=System.nanoTime();
                    if(a==count||lastProgressNanos==0L||now-lastProgressNanos>=250_000_000L){lastProgressNanos=now;changed.run();}
                }
                if(!cancelled){File temp=new File(folder(reciter,s),"complete.tmp"),target=new File(folder(reciter,s),"complete.json");try(FileOutputStream out=new FileOutputStream(temp)){out.write(completed.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}invalidateCompletion(reciter,s);if(target.exists()&&!target.delete())throw new IOException("Could not replace Surah completion state");if(!temp.renameTo(target))throw new IOException("Could not finish Surah download");if(!ready(reciter,s,count)){target.delete();invalidateCompletion(reciter,s);throw new IOException("Downloaded Surah verification failed");}}
            }
            progress=cancelled?"Download paused · completed ayahs are kept":"Download complete";
        }catch(Exception failure){
            progress=cancelled||failure instanceof InterruptedIOException?
                "Download paused · completed ayahs are kept":
                "Download stopped · completed ayahs are kept; tap Download to retry";
            throw failure;
        }finally{busy=false;changed.run();}
    }
}
