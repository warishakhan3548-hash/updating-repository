package com.aaris.quran;

import android.content.Context;
import android.media.MediaMetadataRetriever;
import com.aaris.quran.core.Ayah;
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
    private final File root;
    private final Map<String,Object> locks=new HashMap<>();
    volatile boolean cancelled,busy;
    volatile String progress="";
    RecitationDownloads(Context c){root=new File(c.getFilesDir(),"recitations-v1");}
    static int index(String id){for(int i=0;i<IDS.length;i++)if(IDS[i].equals(id))return i;return 0;}
    static String valid(String id){return IDS[index(id)];}
    private File folder(String reciter,int surah){return new File(new File(root,valid(reciter)),""+surah);}
    private File file(String reciter,Ayah a){return new File(folder(reciter,a.surah),a.number+".mp3");}
    private File hashFile(String reciter,Ayah a){return new File(folder(reciter,a.surah),a.number+".sha256");}
    boolean ready(String reciter,int surah,int ayahs){
        File directory=folder(reciter,surah),marker=new File(directory,"complete.json");if(!marker.isFile())return false;
        try{JSONObject m=new JSONObject(new String(java.nio.file.Files.readAllBytes(marker.toPath()),StandardCharsets.UTF_8));if(m.length()!=ayahs)return false;
            for(int i=1;i<=ayahs;i++){File audio=new File(directory,i+".mp3");if(!audio.isFile()||audio.length()!=m.getLong(""+i))return false;}return true;
        }catch(Exception e){return false;}
    }
    File obtain(String reciter,Ayah a)throws Exception{
        reciter=valid(reciter);String key=reciter+":"+a.id;Object lock;synchronized(locks){lock=locks.computeIfAbsent(key,k->new Object());}
        synchronized(lock){
            File target=file(reciter,a),hash=hashFile(reciter,a),directory=target.getParentFile();
            if(target.isFile()&&hash.isFile()){
                String expected=new String(java.nio.file.Files.readAllBytes(hash.toPath()),StandardCharsets.UTF_8).trim();
                if(expected.equals(ContentStore.hash(target)))return target;
            }
            new File(directory,"complete.json").delete();
            if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("Audio storage unavailable");
            File temporary=new File(directory,a.number+".download");
            URL url=new URL("https://cdn.islamic.network/quran/audio/128/"+reciter+"/"+a.ordinal+".mp3");
            HttpURLConnection connection=(HttpURLConnection)url.openConnection();connection.setConnectTimeout(15000);connection.setReadTimeout(20000);connection.setInstanceFollowRedirects(false);
            try{
                if(connection.getResponseCode()!=200)throw new IOException("Reciter source unavailable ("+connection.getResponseCode()+")");
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
        try{for(int s=startSurah;s<=endSurah&&!cancelled;s++){
            JSONObject completed=new JSONObject();int count=content.surah(s).count;
            for(int a=1;a<=count&&!cancelled;a++){Ayah ayah=content.ayah("Q:"+s+":"+a);File file=obtain(reciter,ayah);completed.put(""+a,file.length());progress=NAMES[index(reciter)]+" · Surah "+s+" · "+a+"/"+count;changed.run();}
            if(!cancelled){File temp=new File(folder(reciter,s),"complete.tmp"),target=new File(folder(reciter,s),"complete.json");try(FileOutputStream out=new FileOutputStream(temp)){out.write(completed.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}if(target.exists())target.delete();if(!temp.renameTo(target))throw new IOException("Could not finish Surah download");}
        }progress=cancelled?"Download paused · completed ayahs are kept":"Download complete";
        }finally{busy=false;changed.run();}
    }
}
