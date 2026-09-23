package com.aaris.quran;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.media.*;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;

/** Single process-wide owner for short offline Quran word pronunciation playback. */
final class WordAudioPlayer implements AutoCloseable {
    private final QuranAudioStore store;
    private final AudioManager audio;
    private final AudioAttributes attributes;
    private final AudioFocusRequest focus;
    private MediaPlayer player;
    private int generation;

    WordAudioPlayer(Context context,QuranAudioStore store) {
        this.store=store;
        audio=context.getSystemService(AudioManager.class);
        attributes=new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build();
        focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener(change->{
                if(change==AudioManager.AUDIOFOCUS_LOSS||
                   change==AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)stop();
            },new Handler(Looper.getMainLooper()))
            .build();
    }

    boolean available(){return store!=null;}
    boolean canPlay(ContentStore.Word word){return store!=null&&store.canAddress(word);}

    synchronized boolean play(ContentStore.Word word) {
        generation++;
        releaseLocked();
        if(store==null)return false;
        QuranAudioStore.Clip clip=store.clip(word);
        if(clip==null)return false;
        AssetFileDescriptor fd=null;
        try {
            fd=store.open(clip);
            if(audio==null||audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED)return false;
            final int token=generation;
            MediaPlayer next=new MediaPlayer();
            next.setAudioAttributes(attributes);
            next.setDataSource(fd.getFileDescriptor(),fd.getStartOffset()+clip.offset,clip.length);
            next.setOnPreparedListener(p->{
                synchronized(WordAudioPlayer.this) {
                    if(player!=p||generation!=token){safeRelease(p);return;}
                    try{p.start();}catch(IllegalStateException invalid){finish(p);}
                }
            });
            next.setOnCompletionListener(this::finish);
            next.setOnErrorListener((p,what,extra)->{finish(p);return true;});
            player=next;
            next.prepareAsync();
            return true;
        } catch(IOException|RuntimeException failure) {
            releaseLocked();
            return false;
        } finally {
            if(fd!=null)try{fd.close();}catch(IOException ignored){}
        }
    }

    synchronized void stop(){generation++;releaseLocked();}

    private void finish(MediaPlayer completed) {
        synchronized(this) {
            if(player==completed)player=null;
            safeRelease(completed);
            abandonFocus();
        }
    }

    private void releaseLocked() {
        MediaPlayer old=player;player=null;
        if(old!=null){
            try{old.stop();}catch(IllegalStateException ignored){}
            safeRelease(old);
        }
        abandonFocus();
    }

    private void abandonFocus(){if(audio!=null)try{audio.abandonAudioFocusRequest(focus);}catch(RuntimeException ignored){}}
    private static void safeRelease(MediaPlayer p){try{p.release();}catch(RuntimeException ignored){}}
    @Override public void close(){stop();}
}
