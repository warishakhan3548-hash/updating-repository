package com.aaris.quran;

import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * App-private, on-demand Quran recitation store.
 *
 * Audio is never bundled in the APK. A Surah becomes playable only after its immutable full-Surah
 * Opus file and matching word-timing protobuf have both been downloaded, validated, and atomically
 * installed under the app's private files directory. Once installed, playback is fully local.
 */
final class QuranAudioStore {
    static final String PROFILE_ID="abdul-basit-abdul-samad-mujawwad";
    static final String RECITER_NAME="Abdul Basit Abdul Samad · Mujawwad";
    static final String SOURCE_NAME="Quranic Recitation Data";
    static final String RIGHTS_NOTICE="source metadata Apache-2.0; recording-rights review pending";
    static final String SOURCE_REVISION="6875b35e45cc83107daf3ab7d3a8bd8b2baa51b3";
    static final String CANONICAL_QURAN_HASH="521fdc94f176d3e73e2889a8a4af07259731d289491c08ed1cda9b3f302ab8b1";

    static final class Clip {
        final File audio;
        final int startMs,endMs;
        Clip(File audio,int startMs,int endMs){this.audio=audio;this.startMs=startMs;this.endMs=endMs;}
        int durationMs(){return Math.max(1,endMs-startMs);}
    }
    static final class Segment {
        final int oneBased,startMs,endMs;
        Segment(int oneBased,int startMs,int endMs){this.oneBased=oneBased;this.startMs=startMs;this.endMs=endMs;}
    }
    private static final class SurahTiming {
        final Map<String,Map<Integer,Segment>> verses;
        SurahTiming(Map<String,Map<Integer,Segment>> verses){this.verses=verses;}
        Segment get(int surah,int ayah,int position){
            Map<Integer,Segment> words=verses.get(surah+":"+ayah);
            return words==null?null:words.get(position);
        }
    }

    private final File root;
    private final Map<Integer,SurahTiming> cache=new HashMap<>();

    QuranAudioStore(Context context,String quranPackHash) throws IOException {
        if(quranPackHash==null||!CANONICAL_QURAN_HASH.equals(quranPackHash))
            throw new IOException("Downloaded Quran audio timing is pinned to a different Quran content pack");
        root=new File(context.getFilesDir(),"quran-audio/"+PROFILE_ID);
        if(!root.exists()&&!root.mkdirs())throw new IOException("Cannot create local Quran audio storage");
    }

    File root(){return root;}
    File surahDir(int surah){return new File(root,String.format(Locale.ROOT,"%03d",surah));}
    File audioFile(int surah){String n=String.format(Locale.ROOT,"%03d",surah);return new File(surahDir(surah),n+".opus");}
    File timingFile(int surah){String n=String.format(Locale.ROOT,"%03d",surah);return new File(surahDir(surah),n+".pb");}

    synchronized boolean installedSurah(int surah){
        if(surah<1||surah>114)return false;
        File audio=audioFile(surah),timing=timingFile(surah);
        if(!audio.isFile()||!timing.isFile()||audio.length()<32||timing.length()<2)return false;
        try{
            if(!cache.containsKey(surah))cache.put(surah,parseTiming(timing,surah));
            return true;
        }catch(IOException invalid){
            cache.remove(surah);return false;
        }
    }

    synchronized int installedCount(){
        int count=0;for(int s=1;s<=114;s++)if(installedSurah(s))count++;return count;
    }

    synchronized long installedBytes(){
        long total=0;
        for(int s=1;s<=114;s++){
            File a=audioFile(s),p=timingFile(s);
            if(a.isFile())total+=a.length();
            if(p.isFile())total+=p.length();
        }
        return total;
    }

    synchronized void refreshSurah(int surah){cache.remove(surah);}

    synchronized Clip clip(ContentStore.Word word){
        if(word==null||word.position<1||word.ayahId==null)return null;
        int[] coordinate=coordinate(word.ayahId);
        if(coordinate==null)return null;
        int surah=coordinate[0],ayah=coordinate[1];
        if(!installedSurah(surah))return null;
        SurahTiming timing=cache.get(surah);
        Segment segment=timing==null?null:timing.get(surah,ayah,word.position);
        if(segment==null||segment.endMs<=segment.startMs)return null;
        return new Clip(audioFile(surah),segment.startMs,segment.endMs);
    }

    boolean canAddress(ContentStore.Word word){return clip(word)!=null;}

    String attribution(){return RECITER_NAME+" · "+SOURCE_NAME+" · "+RIGHTS_NOTICE+" · local after download";}

    static void validateSurahFiles(File audio,File timing,int surah) throws IOException {
        if(surah<1||surah>114)throw new IOException("Invalid Surah number");
        if(!audio.isFile()||audio.length()<32)throw new IOException("Downloaded Surah audio is missing or empty");
        try(InputStream in=new FileInputStream(audio)){
            byte[] header=new byte[4];
            if(in.read(header)!=4||header[0]!='O'||header[1]!='g'||header[2]!='g'||header[3]!='S')
                throw new IOException("Downloaded Surah audio is not an Ogg/Opus file");
        }
        SurahTiming parsed=parseTiming(timing,surah);
        if(parsed.verses.isEmpty())throw new IOException("Downloaded Surah timing file has no verses");
    }

    private static int[] coordinate(String ayahId){
        try{
            String[] parts=ayahId.split(":");
            if(parts.length!=3||!"Q".equals(parts[0]))return null;
            int s=Integer.parseInt(parts[1]),a=Integer.parseInt(parts[2]);
            return s>=1&&s<=114&&a>=1?new int[]{s,a}:null;
        }catch(RuntimeException bad){return null;}
    }

    private static SurahTiming parseTiming(File file,int expectedSurah) throws IOException {
        if(!file.isFile()||file.length()<2||file.length()>8*1024*1024)
            throw new IOException("Invalid Quran timing file");
        byte[] data=readAll(file,(int)Math.min(Integer.MAX_VALUE,file.length()+1));
        Proto top=new Proto(data);
        Map<String,Map<Integer,Segment>> verses=new HashMap<>();
        while(!top.done()){
            int tag=top.varint32();int field=tag>>>3,wire=tag&7;
            if(field==1&&wire==2){
                Proto entry=new Proto(top.bytes());
                String key=null;byte[] value=null;
                while(!entry.done()){
                    int eTag=entry.varint32();int eField=eTag>>>3,eWire=eTag&7;
                    if(eField==1&&eWire==2)key=new String(entry.bytes(),StandardCharsets.UTF_8);
                    else if(eField==2&&eWire==2)value=entry.bytes();
                    else entry.skip(eWire);
                }
                if(key==null||value==null)continue;
                String[] parts=key.split(":");
                if(parts.length!=2)throw new IOException("Invalid Quran timing verse key");
                int surah,ayah;
                try{surah=Integer.parseInt(parts[0]);ayah=Integer.parseInt(parts[1]);}
                catch(NumberFormatException bad){throw new IOException("Invalid Quran timing verse coordinate",bad);}
                if(surah!=expectedSurah||ayah<1)throw new IOException("Quran timing file belongs to a different Surah");
                Map<Integer,Segment> words=parseVerse(value);
                if(!words.isEmpty())verses.put(key,words);
            }else top.skip(wire);
        }
        if(verses.isEmpty())throw new IOException("Quran timing protobuf contains no usable word segments");
        return new SurahTiming(verses);
    }

    private static Map<Integer,Segment> parseVerse(byte[] bytes) throws IOException {
        Proto verse=new Proto(bytes);
        Map<Integer,Segment> words=new HashMap<>();
        while(!verse.done()){
            int tag=verse.varint32();int field=tag>>>3,wire=tag&7;
            if(field==1&&wire==2){
                Proto word=new Proto(verse.bytes());
                int zero=-1,one=-1,start=-1,end=-1;
                while(!word.done()){
                    int wTag=word.varint32();int wField=wTag>>>3,wWire=wTag&7;
                    if(wWire==0){
                        int value=word.varint32();
                        if(wField==1)zero=value;
                        else if(wField==2)one=value;
                        else if(wField==3)start=value;
                        else if(wField==4)end=value;
                    }else word.skip(wWire);
                }
                int position=one>0?one:(zero>=0?zero+1:-1);
                if(position>0&&start>=0&&end>start&&end<24*60*60*1000)
                    words.put(position,new Segment(position,start,end));
            }else verse.skip(wire);
        }
        return words;
    }

    private static byte[] readAll(File file,int max) throws IOException {
        if(file.length()>max)throw new IOException("Quran timing file is too large");
        try(InputStream in=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream((int)file.length())){
            byte[] buffer=new byte[8192];int n,total=0;
            while((n=in.read(buffer))!=-1){
                total+=n;if(total>max)throw new IOException("Quran timing file exceeds limit");
                out.write(buffer,0,n);
            }
            return out.toByteArray();
        }
    }

    /** Minimal decoder for the fixed protobuf schema used by the pinned recitation dataset. */
    private static final class Proto {
        final byte[] data;int pos;
        Proto(byte[] data){this.data=data;}
        boolean done(){return pos>=data.length;}
        int varint32() throws IOException {
            long value=0;
            for(int shift=0;shift<35;shift+=7){
                if(pos>=data.length)throw new EOFException("Truncated protobuf varint");
                int b=data[pos++]&255;value|=(long)(b&127)<<shift;
                if((b&128)==0){
                    if(value>Integer.MAX_VALUE)throw new IOException("Protobuf integer overflow");
                    return (int)value;
                }
            }
            throw new IOException("Invalid protobuf varint");
        }
        byte[] bytes() throws IOException {
            int length=varint32();
            if(length<0||length>data.length-pos)throw new EOFException("Truncated protobuf field");
            byte[] out=Arrays.copyOfRange(data,pos,pos+length);pos+=length;return out;
        }
        void skip(int wire) throws IOException {
            switch(wire){
                case 0: varint32();break;
                case 1: advance(8);break;
                case 2: advance(varint32());break;
                case 5: advance(4);break;
                default: throw new IOException("Unsupported protobuf wire type "+wire);
            }
        }
        void advance(int count) throws IOException {
            if(count<0||count>data.length-pos)throw new EOFException("Truncated protobuf field");
            pos+=count;
        }
    }
}
