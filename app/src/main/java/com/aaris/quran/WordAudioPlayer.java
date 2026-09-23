package com.aaris.quran;

import android.content.Context;
import android.media.*;
import android.os.Handler;
import android.os.Looper;
import java.io.*;

/** Single process-wide owner for complete isolated Quran word-clip playback. */
final class WordAudioPlayer implements AutoCloseable {
    private final QuranAudioStore store;
    private final AudioManager audio;
    private final AudioAttributes attributes;
    private final AudioFocusRequest focus;
    private final Handler main=new Handler(Looper.getMainLooper());
    private MediaPlayer player;
    private RandomAccessFile source;
    private int generation;

    WordAudioPlayer(Context context,QuranAudioStore store){
        this.store=store;
        audio=context.getSystemService(AudioManager.class);
        attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
        focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener(change->{
                if(change==AudioManager.AUDIOFOCUS_LOSS||change==AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)stop();
            },main).build();
    }

    boolean available(){return store!=null;}
    boolean canPlay(ContentStore.Word word){return store!=null&&store.canAddress(word);}

    synchronized boolean play(ContentStore.Word word){
        generation++;releaseLocked();
        if(store==null)return false;
        QuranAudioStore.Clip clip=store.clip(word);
        if(clip==null||!clip.container.isFile()||clip.offset<0||clip.length<32)return false;
        try{
            if(audio==null||audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED)return false;
            final int token=generation;
            RandomAccessFile opened=new RandomAccessFile(clip.container,"r");
            MediaPlayer next=new MediaPlayer();
            next.setAudioAttributes(attributes);
            next.setDataSource(opened.getFD(),clip.offset,clip.length);
            next.setOnPreparedListener(p->{
                synchronized(WordAudioPlayer.this){
                    if(player!=p||generation!=token){finishResources(p,opened,false);return;}
                    try{p.start();}catch(IllegalStateException invalid){finish(p);}
                }
            });
            next.setOnCompletionListener(this::finish);
            next.setOnErrorListener((p,what,extra)->{finish(p);return true;});
            source=opened;player=next;next.prepareAsync();
            return true;
        }catch(IOException|RuntimeException failure){
            releaseLocked();return false;
        }
    }

    synchronized void stop(){generation++;releaseLocked();}

    private void finish(MediaPlayer completed){
        synchronized(this){
            if(player!=completed){safeRelease(completed);return;}
            player=null;RandomAccessFile opened=source;source=null;
            safeRelease(completed);safeClose(opened);abandonFocus();
        }
    }
    private void finishResources(MediaPlayer p,RandomAccessFile opened,boolean abandon){
        safeRelease(p);safeClose(opened);if(abandon)abandonFocus();
    }
    private void releaseLocked(){
        MediaPlayer old=player;player=null;RandomAccessFile opened=source;source=null;
        if(old!=null){try{old.stop();}catch(IllegalStateException ignored){}safeRelease(old);}
        safeClose(opened);abandonFocus();
    }
    private void abandonFocus(){if(audio!=null)try{audio.abandonAudioFocusRequest(focus);}catch(RuntimeException ignored){}}
    private static void safeRelease(MediaPlayer p){if(p!=null)try{p.release();}catch(RuntimeException ignored){}}
    private static void safeClose(Closeable c){if(c!=null)try{c.close();}catch(IOException ignored){}}
    @Override public void close(){stop();}
}
