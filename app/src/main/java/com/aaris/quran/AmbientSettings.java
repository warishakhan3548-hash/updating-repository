package com.aaris.quran;

import android.content.Context;
import android.content.SharedPreferences;

/** Device-local opt-in controls: restoring a learning backup never enables overlays. */
final class AmbientSettings {
    private static SharedPreferences prefs(Context c){return c.getSharedPreferences("ambient",Context.MODE_PRIVATE);}
    static int minutes(Context c){return Math.max(1,Math.min(120,prefs(c).getInt("minutes",5)));}
    static boolean dueOnly(Context c){return prefs(c).getBoolean("due_only",false);}
    static void save(Context c,int minutes,boolean dueOnly){
        if(minutes<1||minutes>120)throw new IllegalArgumentException("1–120 minutes");
        prefs(c).edit().putInt("minutes",minutes).putBoolean("due_only",dueOnly).apply();
    }
    static void status(Context c,boolean running,String message){prefs(c).edit().putBoolean("was_running",running).putString("status",message).apply();}
    static String status(Context c){return prefs(c).getString("status","Abhi band hai");}
    static void processStarted(Context c){if(prefs(c).getBoolean("was_running",false))status(c,false,"Pichhla session ruk gaya. Shuru karein par tap karein.");}
    static boolean askedNotifications(Context c){return prefs(c).getBoolean("notification_asked",false);}
    static void notificationsAsked(Context c){prefs(c).edit().putBoolean("notification_asked",true).apply();}
}
