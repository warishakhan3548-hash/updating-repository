package com.aaris.quran;

import android.content.Context;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.Voice;
import android.widget.Toast;

/** Explicit device voice for translations only; never impersonates a scholar or recites Arabic. */
final class TranslationSpeech implements AutoCloseable {
    private final Context context;private TextToSpeech tts;private boolean ready,closed;
    TranslationSpeech(Context context){this.context=context;}
    void speak(TranslationStore.Entry entry){
        if(entry==null||closed)return;
        if(tts==null){tts=new TextToSpeech(context,status->{if(closed)return;ready=status==TextToSpeech.SUCCESS;if(ready)speak(entry);else message("Device speech is unavailable");});return;}
        if(!ready){message("Device voice is starting. Tap Listen again.");return;}
        Voice selected=null;if(tts.getVoices()==null){message("No device voices are installed");return;}for(Voice voice:tts.getVoices())if(!voice.isNetworkConnectionRequired()&&voice.getLocale().getLanguage().equals(entry.edition.language)){selected=voice;break;}
        if(selected==null){message("Install an offline "+entry.edition.language+" device voice in Android settings");return;}
        tts.stop();tts.setVoice(selected);tts.speak(entry.text,TextToSpeech.QUEUE_FLUSH,new Bundle(),"translation");
    }
    void stop(){if(tts!=null)tts.stop();}
    private void message(String message){Toast.makeText(context,message,Toast.LENGTH_LONG).show();}
    public void close(){closed=true;ready=false;if(tts!=null){tts.stop();tts.shutdown();tts=null;}}
}
