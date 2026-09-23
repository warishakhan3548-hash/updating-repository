package com.aaris.quran;

import android.content.Context;
import android.media.*;
import android.os.Handler;
import android.os.Looper;
import java.io.IOException;

/** Single process-wide owner for short local Quran word pronunciation playback. */
final class WordAudioPlayer implements AutoCloseable {
    private final QuranAudioStore store;
    private final AudioManager audio;
    private final AudioAttributes attributes;
    private final AudioFocusRequest focus;
    private final Handler main=new Handler(Looper.getMainLooper());
    private MediaPlayer player;
    private int generation;
    private Runnable stopRunnable;

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
            },main)
            .build();
    }

    boolean available(){return store!=null;}
    boolean canPlay(ContentStore.Word word){return store!=null&&store.canAddress(word);}

    synchronized boolean play(ContentStore.Word word) {
        generation++;
        releaseLocked();
        if(store==null)return false;
        QuranAudioStore.Clip clip=store.clip(word);
        if(clip==null||!clip.audio.isFile())return false;
        try {
            if(audio==null||audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED)return false;
            final int token=generation;
            MediaPlayer next=new MediaPlayer();
            next.setAudioAttributes(attributes);
            next.setDataSource(clip.audio.getAbsolutePath());
            next.setOnPreparedListener(p->{
                synchronized(WordAudioPlayer.this) {
                    if(player!=p||generation!=token){safeRelease(p);return;}
                    p.setOnSeekCompleteListener(seeked->{
                        synchronized(WordAudioPlayer.this){
                            if(player!=seeked||generation!=token){safeRelease(seeked);return;}
                            try{
                                seeked.start();
                                Runnable stop=()->finishIfCurrent(seeked,token);
                                stopRunnable=stop;
                                main.postDelayed(stop,Math.max(180,clip.durationMs()+120L));
                            }catch(IllegalStateException invalid){finish(seeked);}
                        }
                    });
                    try{p.seekTo(clip.startMs,MediaPlayer.SEEK_CLOSEST);}
                    catch(IllegalStateException invalid){finish(p);}
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
        }
    }

    synchronized void stop(){generation++;releaseLocked();}

    private void finishIfCurrent(MediaPlayer completed,int token){
        synchronized(this){
            if(player==completed&&generation==token)finish(completed);
        }
    }

    private void finish(MediaPlayer completed) {
        synchronized(this) {
            boolean current=player==completed;
            if(current)player=null;
            if(stopRunnable!=null){main.removeCallbacks(stopRunnable);stopRunnable=null;}
            safeRelease(completed);
            if(current)abandonFocus();
        }
    }

    private void releaseLocked() {
        if(stopRunnable!=null){main.removeCallbacks(stopRunnable);stopRunnable=null;}
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
