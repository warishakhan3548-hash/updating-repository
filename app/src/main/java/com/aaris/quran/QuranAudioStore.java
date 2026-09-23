package com.aaris.quran;

import android.content.Context;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/**
 * App-private store for exact isolated Quran word recordings.
 *
 * One downloaded .aqp file represents one Surah. It contains a tiny coordinate index followed by
 * byte-for-byte Ogg/Opus word clips from the pinned Muallim dataset. Playback addresses one complete
 * source clip by file offset/length; it never seeks into or truncates a full-Surah recitation.
 */
final class QuranAudioStore {
    static final String PROFILE_ID="muallim-isolated-word-v1";
    static final String RECITER_NAME="Muallim · isolated word pronunciation";
    static final String SOURCE_NAME="Quranic Word-By-Word Audio Data";
    static final String SOURCE_REPO="zaibihassan/Quranic-Word-By-Word-Audio-Data";
    static final String SOURCE_REVISION="9796e08caae700f44266255da320adf6e5ab4114";
    static final String CANONICAL_ALIGNMENT_HASH="9971ffae866bc3682d11efccd30fdddb1d62bc4718e5f9cd941395e6f16093ce";
    static final String DELIVERY="ISOLATED_WORD_SURAH_CONTAINER_V1";
    private static final byte[] MAGIC="AARISQW1\n".getBytes(StandardCharsets.US_ASCII);
    private static final int MAX_INDEX_BYTES=4*1024*1024;

    static final class PackMeta {
        final int surah,words;final long bytes;final String sha256,url;
        PackMeta(int surah,int words,long bytes,String sha256,String url){
            this.surah=surah;this.words=words;this.bytes=bytes;this.sha256=sha256;this.url=url;
        }
    }
    static final class Clip {
        final File container;final long offset,length;
        Clip(File container,long offset,long length){this.container=container;this.offset=offset;this.length=length;}
    }
    private static final class Entry {
        final long offset,length;
        Entry(long offset,long length){this.offset=offset;this.length=length;}
    }
    private static final class SurahIndex {
        final long payloadBase;final Map<String,Entry> entries;
        SurahIndex(long payloadBase,Map<String,Entry> entries){this.payloadBase=payloadBase;this.entries=entries;}
    }

    private final File root;
    private final Map<Integer,PackMeta> catalog=new HashMap<>();
    private final Map<Integer,SurahIndex> cache=new HashMap<>();

    QuranAudioStore(Context context,String alignmentHash) throws Exception {
        if(alignmentHash==null||!CANONICAL_ALIGNMENT_HASH.equals(alignmentHash))
            throw new IOException("Quran word identities differ from the isolated pronunciation catalog");
        JSONObject manifest=new JSONObject(ContentStore.asset(context,"quran-audio-word-catalog.json"));
        if(manifest.optInt("schema")!=1||!DELIVERY.equals(manifest.optString("delivery")))
            throw new IOException("Unsupported Quran pronunciation catalog");
        if(!SOURCE_REVISION.equals(manifest.optString("source_revision"))||
           !CANONICAL_ALIGNMENT_HASH.equals(manifest.optString("canonical_quran_alignment_sha256"))||
           manifest.optInt("canonical_quran_audio_words")!=77326||
           manifest.optInt("surahs")!=114)
            throw new IOException("Quran pronunciation catalog/source binding mismatch");
        JSONObject packs=manifest.getJSONObject("packs");
        for(int surah=1;surah<=114;surah++){
            String key=String.format(Locale.ROOT,"%03d",surah);
            JSONObject p=packs.getJSONObject(key);
            int words=p.getInt("words");long bytes=p.getLong("bytes");
            String sha=p.getString("sha256"),url=p.getString("url");
            if(words<1||bytes<64||sha.length()!=64||!url.startsWith("https://github.com/"))
                throw new IOException("Invalid Quran pronunciation pack metadata for Surah "+surah);
            catalog.put(surah,new PackMeta(surah,words,bytes,sha,url));
        }
        root=new File(context.getFilesDir(),"quran-audio/"+PROFILE_ID);
        if(!root.exists()&&!root.mkdirs())throw new IOException("Cannot create local Quran pronunciation storage");
    }

    File root(){return root;}
    PackMeta meta(int surah){return catalog.get(surah);}
    File surahFile(int surah){return new File(root,String.format(Locale.ROOT,"%03d.aqp",surah));}
    private File markerFile(int surah){return new File(root,String.format(Locale.ROOT,"%03d.ok",surah));}
    File partialFile(int surah){return new File(root,".partial-"+SOURCE_REVISION.substring(0,12)+"-"+String.format(Locale.ROOT,"%03d",surah)+".aqp");}

    synchronized boolean installedSurah(int surah){
        PackMeta meta=meta(surah);if(meta==null)return false;
        File file=surahFile(surah),marker=markerFile(surah);
        if(!file.isFile()||file.length()!=meta.bytes)return false;
        try{
            String marked=marker.isFile()?readSmall(marker,256).trim():"";
            if(!meta.sha256.equals(marked)){
                // Crash-safe recovery: an atomically renamed complete file may exist before marker write.
                validateContainer(file,meta,true);
                writeMarker(marker,meta.sha256);
            }
            if(!cache.containsKey(surah))cache.put(surah,parseIndex(file,meta,false));
            return true;
        }catch(Exception invalid){
            cache.remove(surah);return false;
        }
    }

    synchronized int installedCount(){int n=0;for(int s=1;s<=114;s++)if(installedSurah(s))n++;return n;}
    synchronized long installedBytes(){long total=0;for(int s=1;s<=114;s++){File f=surahFile(s);if(f.isFile())total+=f.length();}return total;}
    synchronized void refreshSurah(int surah){cache.remove(surah);}

    synchronized Clip clip(ContentStore.Word word){
        if(word==null||word.position<1||word.ayahId==null)return null;
        int[] coordinate=coordinate(word.ayahId);if(coordinate==null)return null;
        int surah=coordinate[0],ayah=coordinate[1];
        if(!installedSurah(surah))return null;
        SurahIndex index=cache.get(surah);if(index==null)return null;
        Entry e=index.entries.get(ayah+":"+word.position);if(e==null)return null;
        return new Clip(surahFile(surah),index.payloadBase+e.offset,e.length);
    }

    boolean canAddress(ContentStore.Word word){return clip(word)!=null;}
    String attribution(){return RECITER_NAME+" · "+SOURCE_NAME+" · exact isolated local clip";}

    synchronized void installDownloaded(int surah,File staging) throws Exception {
        PackMeta meta=meta(surah);if(meta==null)throw new IOException("Unknown Surah audio pack");
        validateContainer(staging,meta,true);
        File target=surahFile(surah),marker=markerFile(surah),old=new File(root,String.format(Locale.ROOT,".%03d.old",surah));
        delete(old);delete(marker);
        if(target.exists()&&!target.renameTo(old))throw new IOException("Purana Surah pronunciation replace nahi ho saka");
        if(!staging.renameTo(target)){
            if(old.exists())old.renameTo(target);
            throw new IOException("Verified Surah pronunciation install nahi ho saka");
        }
        try{
            writeMarker(marker,meta.sha256);
            cache.put(surah,parseIndex(target,meta,false));
        }catch(Exception fail){
            delete(marker);delete(target);if(old.exists())old.renameTo(target);throw fail;
        }
        delete(old);
    }

    private static SurahIndex parseIndex(File file,PackMeta meta,boolean verifyOgg) throws Exception {
        try(RandomAccessFile raf=new RandomAccessFile(file,"r")){
            byte[] magic=new byte[MAGIC.length];raf.readFully(magic);
            if(!Arrays.equals(MAGIC,magic))throw new IOException("Invalid isolated Quran audio container magic");
            int indexLength=raf.readInt();
            if(indexLength<1||indexLength>MAX_INDEX_BYTES||indexLength>raf.length()-MAGIC.length-4)
                throw new IOException("Invalid isolated Quran audio index length");
            byte[] raw=new byte[indexLength];raf.readFully(raw);
            long payloadBase=MAGIC.length+4L+indexLength,payloadBytes=raf.length()-payloadBase;
            String text=new String(raw,StandardCharsets.UTF_8);
            Map<String,Entry> entries=new HashMap<>();
            int count=0;
            for(String line:text.split("\n")){
                if(line.isEmpty())continue;
                String[] p=line.split("\t");
                if(p.length!=4)throw new IOException("Malformed Quran word-audio index row");
                int ayah=Integer.parseInt(p[0]),position=Integer.parseInt(p[1]);
                long off=Long.parseLong(p[2]),len=Long.parseLong(p[3]);
                if(ayah<1||position<1||off<0||len<32||off+len>payloadBytes)
                    throw new IOException("Out-of-range Quran word-audio index row");
                String key=ayah+":"+position;
                if(entries.put(key,new Entry(off,len))!=null)throw new IOException("Duplicate Quran word-audio coordinate");
                if(verifyOgg){
                    raf.seek(payloadBase+off);
                    if(raf.read()!='O'||raf.read()!='g'||raf.read()!='g'||raf.read()!='S')
                        throw new IOException("Indexed Quran word clip is not an Ogg stream");
                }
                count++;
            }
            if(count!=meta.words)throw new IOException("Quran word-audio pack coverage mismatch");
            return new SurahIndex(payloadBase,entries);
        }catch(NumberFormatException malformed){throw new IOException("Malformed Quran word-audio index number",malformed);}
    }

    private static void validateContainer(File file,PackMeta meta,boolean verifyOgg) throws Exception {
        if(!file.isFile()||file.length()!=meta.bytes)throw new IOException("Downloaded Surah pronunciation size mismatch");
        if(!meta.sha256.equals(sha256(file)))throw new IOException("Downloaded Surah pronunciation checksum mismatch");
        parseIndex(file,meta,verifyOgg);
    }

    private static int[] coordinate(String ayahId){
        try{
            String[] p=ayahId.split(":");if(p.length!=3||!"Q".equals(p[0]))return null;
            int s=Integer.parseInt(p[1]),a=Integer.parseInt(p[2]);return s>=1&&s<=114&&a>=1?new int[]{s,a}:null;
        }catch(RuntimeException e){return null;}
    }
    private static String sha256(File file) throws Exception {
        MessageDigest sha=MessageDigest.getInstance("SHA-256");
        try(InputStream in=new BufferedInputStream(new FileInputStream(file))){
            byte[] b=new byte[65536];int n;while((n=in.read(b))!=-1)sha.update(b,0,n);
        }
        StringBuilder out=new StringBuilder();for(byte b:sha.digest())out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();
    }
    private static String readSmall(File file,int max) throws IOException {
        if(file.length()>max)throw new IOException("Marker too large");
        try(InputStream in=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] b=new byte[256];int n;while((n=in.read(b))!=-1){if(out.size()+n>max)throw new IOException("Marker too large");out.write(b,0,n);}
            return out.toString("UTF-8");
        }
    }
    private static void writeMarker(File marker,String text) throws IOException {
        File tmp=new File(marker.getParentFile(),marker.getName()+".tmp");
        try(FileOutputStream out=new FileOutputStream(tmp)){out.write((text+"\n").getBytes(StandardCharsets.US_ASCII));out.getFD().sync();}
        if(marker.exists()&&!marker.delete())throw new IOException("Old audio marker clear nahi hua");
        if(!tmp.renameTo(marker))throw new IOException("Audio marker install nahi hua");
    }
    private static void delete(File f){if(f!=null&&f.exists())f.delete();}
}
