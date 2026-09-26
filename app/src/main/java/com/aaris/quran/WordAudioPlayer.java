package com.aaris.quran;

import android.content.*;
import android.media.*;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.io.*;
import java.util.*;

/**
 * Single process-wide owner for exact isolated Quran word clips.
 *
 * A single word tap and an ayah fallback use the same player. Ayah playback chains the verified
 * local word clips in Quran order and holds audio focus across the whole sequence.
 */
final class WordAudioPlayer implements AutoCloseable {
    private final QuranAudioStore store;
    private final Context context;
    private final AudioManager audio;
    private final AudioAttributes attributes;
    private final AudioFocusRequest focus;
    private final Handler main=new Handler(Looper.getMainLooper());
    private MediaPlayer player;
    private RandomAccessFile source;
    private List<ContentStore.Word> sequence=Collections.emptyList();
    private int sequenceIndex;
    private Runnable sequenceComplete;
    private int generation;
    private boolean noisyReceiverRegistered;
    private final BroadcastReceiver noisy=new BroadcastReceiver(){
        @Override public void onReceive(Context context,Intent intent){
            if(AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(intent.getAction()))stop();
        }
    };

    WordAudioPlayer(Context context,QuranAudioStore store){
        this.store=store;
        this.context=context.getApplicationContext();
        audio=this.context.getSystemService(AudioManager.class);
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
    boolean canPlay(List<ContentStore.Word> words){
        if(store==null||words==null||words.isEmpty())return false;
        for(ContentStore.Word word:words)if(word==null||!store.canAddress(word))return false;
        return true;
    }

    synchronized boolean play(ContentStore.Word word){
        if(word==null)return false;
        return playSequence(Collections.singletonList(word),null);
    }

    synchronized boolean playSequence(List<ContentStore.Word> words){
        return playSequence(words,null);
    }

    synchronized boolean playSequence(List<ContentStore.Word> words,Runnable complete){
        generation++;
        releaseLocked();
        if(!canPlay(words))return false;
        if(audio==null||audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED)return false;
        try{registerNoisyReceiverLocked();}
        catch(RuntimeException unavailable){abandonFocus();return false;}
        sequence=new ArrayList<>(words);sequenceIndex=0;sequenceComplete=complete;
        if(openCurrentLocked(generation))return true;
        Runnable done=finishSequenceLocked();if(done!=null)main.post(done);return false;
    }

    private boolean openCurrentLocked(int token){
        if(token!=generation||sequenceIndex<0||sequenceIndex>=sequence.size())return false;
        QuranAudioStore.Clip clip=store.clip(sequence.get(sequenceIndex));
        if(clip==null||!clip.container.isFile()||clip.offset<0||clip.length<32)return false;
        try{
            RandomAccessFile opened=new RandomAccessFile(clip.container,"r");
            MediaPlayer next=new MediaPlayer();
            next.setAudioAttributes(attributes);
            next.setDataSource(opened.getFD(),clip.offset,clip.length);
            next.setOnPreparedListener(p->{
                synchronized(WordAudioPlayer.this){
                    if(player!=p||generation!=token){finishResources(p,opened);return;}
                    try{p.start();}catch(IllegalStateException invalid){failSequence(p,token);}
                }
            });
            next.setOnCompletionListener(p->advance(p,token));
            next.setOnErrorListener((p,what,extra)->{failSequence(p,token);return true;});
            source=opened;player=next;next.prepareAsync();
            return true;
        }catch(IOException|RuntimeException failure){
            releaseCurrentLocked();return false;
        }
    }

    private void advance(MediaPlayer completed,int token){
        Runnable done=null;
        synchronized(this){
            if(player!=completed||generation!=token){safeRelease(completed);return;}
            releaseCurrentLocked();sequenceIndex++;
            if(sequenceIndex<sequence.size()){
                if(!openCurrentLocked(token))done=finishSequenceLocked();
            }else done=finishSequenceLocked();
        }
        if(done!=null)main.post(done);
    }

    private void failSequence(MediaPlayer failed,int token){
        Runnable done=null;
        synchronized(this){
            if(generation!=token){safeRelease(failed);return;}
            if(player==failed)releaseCurrentLocked();else safeRelease(failed);
            done=finishSequenceLocked();
        }
        if(done!=null)main.post(done);
    }

    synchronized void stop(){generation++;releaseLocked();}

    private Runnable finishSequenceLocked(){
        releaseCurrentLocked();
        sequence=Collections.emptyList();sequenceIndex=0;
        Runnable done=sequenceComplete;sequenceComplete=null;
        unregisterNoisyReceiverLocked();abandonFocus();return done;
    }

    private void releaseCurrentLocked(){
        MediaPlayer old=player;player=null;RandomAccessFile opened=source;source=null;
        if(old!=null){try{old.stop();}catch(IllegalStateException ignored){}safeRelease(old);}
        safeClose(opened);
    }

    private void releaseLocked(){
        releaseCurrentLocked();sequence=Collections.emptyList();sequenceIndex=0;sequenceComplete=null;unregisterNoisyReceiverLocked();abandonFocus();
    }

    private void registerNoisyReceiverLocked(){
        if(noisyReceiverRegistered)return;
        IntentFilter filter=new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY);
        if(Build.VERSION.SDK_INT>=33)context.registerReceiver(noisy,filter,Context.RECEIVER_NOT_EXPORTED);
        else context.registerReceiver(noisy,filter);
        noisyReceiverRegistered=true;
    }
    private void unregisterNoisyReceiverLocked(){
        if(!noisyReceiverRegistered)return;
        try{context.unregisterReceiver(noisy);}catch(RuntimeException ignored){}
        noisyReceiverRegistered=false;
    }

    private static void finishResources(MediaPlayer p,RandomAccessFile opened){safeRelease(p);safeClose(opened);}
    private void abandonFocus(){if(audio!=null)try{audio.abandonAudioFocusRequest(focus);}catch(RuntimeException ignored){}}
    private static void safeRelease(MediaPlayer p){if(p!=null)try{p.release();}catch(RuntimeException ignored){}}
    private static void safeClose(Closeable c){if(c!=null)try{c.close();}catch(IOException ignored){}}
    @Override public void close(){stop();}
}
