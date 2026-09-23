package com.aaris.quran;

import android.app.*;
import android.content.*;
import android.media.*;
import android.media.session.*;
import android.os.*;
import com.aaris.quran.core.Ayah;
import java.io.File;
import java.util.concurrent.Future;

/** Whole-ayah playback with one owner, audio focus and Android background controls. */
public final class RecitationService extends Service {
    static final String PLAY="recitation.play",PAUSE="recitation.pause",NEXT="recitation.next",PREVIOUS="recitation.previous",STOP="recitation.stop";
    private QuranApp app;private MediaPlayer player;private MediaSession session;private AudioManager audio;private AudioFocusRequest focus;
    private final Handler main=new Handler(Looper.getMainLooper());private Future<?> pending;private int generation;private boolean destroyed;
    private int surah=1,ayah=1,repeatRemaining=1;private boolean continuous=true,paused;private String reciter;
    static void command(Context context,String action,int surah,int ayah){Intent intent=new Intent(context,RecitationService.class).setAction(action).putExtra("surah",surah).putExtra("ayah",ayah);context.startForegroundService(intent);}
    @Override public void onCreate(){super.onCreate();app=(QuranApp)getApplication();audio=getSystemService(AudioManager.class);
        NotificationManager notifications=getSystemService(NotificationManager.class);notifications.createNotificationChannel(new NotificationChannel("recitation","Quran recitation",NotificationManager.IMPORTANCE_LOW));
        session=new MediaSession(this,"AarisRecitation");session.setCallback(new MediaSession.Callback(){public void onPlay(){resume();}public void onPause(){pause();}public void onStop(){stopSelf();}public void onSkipToNext(){move(1);}public void onSkipToPrevious(){move(-1);}});session.setActive(true);
        AudioAttributes attrs=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
        focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).setAudioAttributes(attrs).setOnAudioFocusChangeListener(change->{if(change<=0)pause();},main).build();
        reciter=getSharedPreferences("recitation",0).getString("reciter",RecitationDownloads.IDS[0]);startForeground(42,notification("Preparing recitation"));
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId){if(intent==null){stopSelf();return START_NOT_STICKY;}String action=intent.getAction();
        if(STOP.equals(action)){stopSelf();return START_NOT_STICKY;}
        app.ready(()->{if(destroyed)return;if(app.content==null){fail("Quran content is unavailable");return;}if(PLAY.equals(action)){
            surah=Math.max(1,Math.min(114,intent.getIntExtra("surah",1)));ayah=Math.max(1,Math.min(app.content.surah(surah).count,intent.getIntExtra("ayah",1)));
            reciter=RecitationDownloads.valid(getSharedPreferences("recitation",0).getString("reciter",RecitationDownloads.IDS[0]));continuous=getSharedPreferences("recitation",0).getBoolean("continuous",true);
            repeatRemaining=getSharedPreferences("recitation",0).getInt("repeat",1);play();
        }else if(PAUSE.equals(action)){if(paused)resume();else pause();}else if(NEXT.equals(action))move(1);else if(PREVIOUS.equals(action))move(-1);});return START_NOT_STICKY;
    }
    private void play(){
        int token=++generation;if(pending!=null)pending.cancel(true);releasePlayer();paused=false;app.recitationActive=true;
        if(app.audio!=null)app.audio.stop();Ayah record=app.content.ayah("Q:"+surah+":"+ayah);if(record==null){stopSelf();return;}
        update("Loading · "+label());String voice=reciter;
        pending=app.recitationWorker.submit(()->{try{File local=app.recitationDownloads.obtain(voice,record);main.post(()->{if(token!=generation)return;try{
            if(audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED){fail("Audio focus unavailable");return;}
            MediaPlayer next=new MediaPlayer();player=next;next.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build());next.setDataSource(local.getAbsolutePath());
            next.setOnPreparedListener(p->{if(token!=generation||player!=p)return;p.start();paused=false;update(label());});
            next.setOnErrorListener((p,what,extra)->{if(token==generation)fail("Audio could not play");return true;});
            next.setOnCompletionListener(p->{if(token!=generation)return;if(--repeatRemaining>0)play();else if(continuous&&ayah<app.content.surah(surah).count){ayah++;repeatRemaining=getSharedPreferences("recitation",0).getInt("repeat",1);play();}else stopSelf();});next.prepareAsync();
        }catch(Exception e){fail("Audio could not play");}});}catch(Exception e){main.post(()->{if(token==generation)fail("Audio unavailable · downloaded reading remains available");});}});
    }
    private String label(){return RecitationDownloads.NAMES[RecitationDownloads.index(reciter)]+" · "+surah+":"+ayah;}
    private void move(int delta){if(app.content==null)return;int next=ayah+delta;if(next<1||next>app.content.surah(surah).count)return;ayah=next;repeatRemaining=getSharedPreferences("recitation",0).getInt("repeat",1);play();}
    private void pause(){
        if(player!=null)try{if(player.isPlaying()){player.pause();paused=true;update("Paused · "+label());return;}}catch(IllegalStateException ignored){}
        generation++;if(pending!=null)pending.cancel(true);releasePlayer();paused=true;update("Paused · "+label());
    }
    private void resume(){if(player!=null)try{if(audio.requestAudioFocus(focus)==AudioManager.AUDIOFOCUS_REQUEST_GRANTED){player.start();paused=false;update(label());return;}}catch(IllegalStateException ignored){}play();}
    private void update(String message){app.recitationSurah=surah;app.recitationAyah=ayah;app.recitationLabel=message;app.main.post(()->{if(app.recitationChanged!=null)app.recitationChanged.run();});session.setMetadata(new MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE,message).build());
        session.setPlaybackState(new PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY|PlaybackState.ACTION_PAUSE|PlaybackState.ACTION_STOP|PlaybackState.ACTION_SKIP_TO_NEXT|PlaybackState.ACTION_SKIP_TO_PREVIOUS).setState(paused?PlaybackState.STATE_PAUSED:PlaybackState.STATE_PLAYING,PlaybackState.PLAYBACK_POSITION_UNKNOWN,1).build());getSystemService(NotificationManager.class).notify(42,notification(message));}
    private PendingIntent action(String action,int request){return PendingIntent.getService(this,request,new Intent(this,RecitationService.class).setAction(action),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);}
    private Notification notification(String message){PendingIntent open=PendingIntent.getActivity(this,10,new Intent(this,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this,"recitation").setSmallIcon(com.aaris.quran.R.drawable.ic_recall_notification).setContentTitle("Aaris · Recitation").setContentText(message).setContentIntent(open).setOngoing(!paused)
            .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_previous,"Previous",action(PREVIOUS,1)).build())
            .addAction(new Notification.Action.Builder(paused?android.R.drawable.ic_media_play:android.R.drawable.ic_media_pause,paused?"Play":"Pause",action(PAUSE,2)).build())
            .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_next,"Next",action(NEXT,3)).build())
            .addAction(new Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel,"Stop",action(STOP,4)).build())
            .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(0,1,2)).build();
    }
    private void fail(String message){android.widget.Toast.makeText(this,message,android.widget.Toast.LENGTH_LONG).show();stopSelf();}
    private void releasePlayer(){MediaPlayer old=player;player=null;if(old!=null)try{old.release();}catch(RuntimeException ignored){}}
    @Override public void onDestroy(){destroyed=true;generation++;if(pending!=null)pending.cancel(true);main.removeCallbacksAndMessages(null);releasePlayer();if(audio!=null)audio.abandonAudioFocusRequest(focus);if(session!=null){session.setActive(false);session.release();}app.recitationActive=false;app.recitationLabel="";app.main.post(()->{if(app.recitationChanged!=null)app.recitationChanged.run();});super.onDestroy();}
    @Override public IBinder onBind(Intent intent){return null;}
}
