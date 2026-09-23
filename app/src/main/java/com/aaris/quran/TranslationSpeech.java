package com.aaris.quran;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.speech.tts.Voice;
import android.widget.Toast;
import java.util.*;

/** Explicit device voice for translations only; never impersonates a scholar or recites Arabic. */
final class TranslationSpeech implements AutoCloseable {
    private final Context context;private TextToSpeech tts;private boolean ready,closed,starting;
    private final Handler main=new Handler(Looper.getMainLooper());private Runnable afterInit;
    TranslationSpeech(Context context){this.context=context;}
    private void ensure(Runnable action){
        if(closed)return;if(ready){action.run();return;}afterInit=action;
        if(starting){message("Device voice is starting…");return;}starting=true;
        tts=new TextToSpeech(context,status->main.post(()->{
            starting=false;if(closed)return;ready=status==TextToSpeech.SUCCESS;
            Runnable next=afterInit;afterInit=null;
            if(!ready){if(tts!=null)tts.shutdown();tts=null;message("Device speech is unavailable");return;}
            if(next!=null)next.run();
        }));
    }
    private List<Voice> voices(String language){
        List<Voice> out=new ArrayList<>();Set<Voice> available=tts.getVoices();
        if(available!=null)for(Voice voice:available)if(!voice.isNetworkConnectionRequired()&&voice.getLocale().getLanguage().equals(language))out.add(voice);
        out.sort(Comparator.comparingInt(Voice::getQuality).reversed().thenComparingInt(Voice::getLatency).thenComparing(Voice::getName));
        return out;
    }
    void speak(TranslationStore.Entry entry){
        if(entry==null||closed)return;ensure(()->speakReady(entry));
    }
    private void speakReady(TranslationStore.Entry entry){
        List<Voice> available=voices(entry.edition.language);if(available.isEmpty()){message("Install an offline "+entry.edition.language+" device voice in Android settings");return;}
        String saved=context.getSharedPreferences("translation_speech",0).getString(entry.edition.language,"");
        Voice selected=saved.isEmpty()?available.get(0):null;
        for(Voice voice:available)if(voiceKey(voice).equals(saved)){selected=voice;break;}
        if(selected==null){message("Your saved device voice is unavailable. Choose another in Translation settings.");return;}
        tts.stop();if(tts.setVoice(selected)!=TextToSpeech.SUCCESS){message("This device voice could not be loaded");return;}
        if(tts.speak(entry.text,TextToSpeech.QUEUE_FLUSH,new Bundle(),"translation")==TextToSpeech.ERROR)message("This text could not be spoken by the selected device voice");
    }
    void chooseVoice(Activity activity,TranslationStore.Entry sample){
        if(sample==null){message("Choose an installed translation first");return;}
        ensure(()->{
            if(activity.isFinishing()||activity.isDestroyed())return;
            List<Voice> available=voices(sample.edition.language);if(available.isEmpty()){message("Install an offline "+sample.edition.language+" voice in Android settings");return;}
            String[] labels=new String[available.size()];int checked=-1;
            String saved=context.getSharedPreferences("translation_speech",0).getString(sample.edition.language,"");
            for(int i=0;i<available.size();i++){Voice voice=available.get(i);labels[i]=voice.getLocale().getDisplayName()+" · Voice "+(i+1);if(voiceKey(voice).equals(saved))checked=i;}
            new AlertDialog.Builder(activity).setTitle("Device voice · Tap to preview")
                .setSingleChoiceItems(labels,checked,(dialog,which)->{
                    context.getSharedPreferences("translation_speech",0).edit().putString(sample.edition.language,voiceKey(available.get(which))).apply();
                    speakReady(sample);
                }).setPositiveButton("Done",(dialog,which)->stop()).setOnCancelListener(dialog->stop()).show();
        });
    }
    private String voiceKey(Voice voice){return tts.getDefaultEngine()+":"+voice.getName();}
    void stop(){afterInit=null;if(tts!=null)tts.stop();}
    private void message(String message){Toast.makeText(context,message,Toast.LENGTH_LONG).show();}
    public void close(){closed=true;ready=false;afterInit=null;main.removeCallbacksAndMessages(null);if(tts!=null){tts.stop();tts.shutdown();tts=null;}}
}
