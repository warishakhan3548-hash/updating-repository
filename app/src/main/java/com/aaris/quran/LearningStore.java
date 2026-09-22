package com.aaris.quran;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import com.aaris.quran.core.Recall;
import org.json.*;
import java.util.*;

/** Precious user history lives in its own database. No destructive upgrade fallback. */
final class LearningStore extends SQLiteOpenHelper {
    final String session=UUID.randomUUID().toString();
    private Map<String,Recall.State> cachedStates;
    private long lastEventTime;
    LearningStore(Context context){super(context,"learning.sqlite",null,1);setWriteAheadLoggingEnabled(true);}
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE event(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,target TEXT NOT NULL,kind TEXT NOT NULL,at INTEGER NOT NULL,session TEXT NOT NULL,context TEXT NOT NULL,scheduler TEXT NOT NULL)");
        db.execSQL("CREATE INDEX event_target ON event(target,seq)");
        db.execSQL("CREATE TABLE bookmark(ayah_id TEXT PRIMARY KEY,created INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE note(target TEXT PRIMARY KEY,text TEXT NOT NULL,updated INTEGER NOT NULL)");
        db.execSQL("CREATE TABLE setting(key TEXT PRIMARY KEY,value TEXT NOT NULL)");
        db.execSQL("CREATE TABLE bundle(id TEXT PRIMARY KEY,json TEXT NOT NULL,created INTEGER NOT NULL)");
    }
    @Override public void onUpgrade(SQLiteDatabase db,int old,int version){throw new IllegalStateException("A non-destructive learning migration is required");}
    void event(String target,Recall.Kind kind,String context){event(UUID.randomUUID().toString(),target,kind,context);}
    synchronized void event(String id,String target,Recall.Kind kind,String context) {
        if(lastEventTime==0)try(Cursor c=getReadableDatabase().rawQuery("SELECT COALESCE(MAX(at),0) FROM event",null)){if(c.moveToFirst())lastEventTime=c.getLong(0);}
        ContentValues v=new ContentValues();v.put("id",id);v.put("target",target);v.put("kind",kind.name());
        v.put("at",lastEventTime=Math.max(System.currentTimeMillis(),lastEventTime+1));v.put("session",session);v.put("context",context==null?target:context);v.put("scheduler",Recall.VERSION);
        try(Cursor existing=getReadableDatabase().rawQuery("SELECT target,kind,context FROM event WHERE id=?",new String[]{id})) {
            if(existing.moveToFirst()) {
                if(!target.equals(existing.getString(0))||!kind.name().equals(existing.getString(1))||!v.getAsString("context").equals(existing.getString(2)))
                    throw new IllegalArgumentException("Conflicting event identity");
                return;
            }
        }
        getWritableDatabase().insertOrThrow("event",null,v);cachedStates=null;
    }
    List<Recall.Event> events() {
        List<Recall.Event> list=new ArrayList<>();
        try(Cursor c=getReadableDatabase().rawQuery("SELECT id,target,kind,at,session,context,scheduler FROM event ORDER BY seq",null)) {
            while(c.moveToNext())list.add(new Recall.Event(c.getString(0),c.getString(1),Recall.Kind.valueOf(c.getString(2)),c.getLong(3),c.getString(4),c.getString(5),c.getString(6)));
        }
        return list;
    }
    synchronized Map<String,Recall.State> states(){
        if(cachedStates==null)cachedStates=Collections.unmodifiableMap(Recall.replay(events(),new Recall.ConservativeScheduler()));
        return cachedStates;
    }
    String get(String key,String fallback) {
        try(Cursor c=getReadableDatabase().rawQuery("SELECT value FROM setting WHERE key=?",new String[]{key})){return c.moveToFirst()?c.getString(0):fallback;}
    }
    synchronized void set(String key,String value){ContentValues v=new ContentValues();v.put("key",key);v.put("value",value);getWritableDatabase().insertWithOnConflict("setting",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    boolean bookmarked(String id){try(Cursor c=getReadableDatabase().rawQuery("SELECT 1 FROM bookmark WHERE ayah_id=?",new String[]{id})){return c.moveToFirst();}}
    synchronized void toggleBookmark(String id) {
        if(bookmarked(id)){getWritableDatabase().delete("bookmark","ayah_id=?",new String[]{id});return;}
        ContentValues v=new ContentValues();v.put("ayah_id",id);v.put("created",System.currentTimeMillis());getWritableDatabase().insert("bookmark",null,v);
    }
    List<String> bookmarks(){List<String> ids=new ArrayList<>();try(Cursor c=getReadableDatabase().rawQuery("SELECT ayah_id FROM bookmark ORDER BY created DESC",null)){while(c.moveToNext())ids.add(c.getString(0));}return ids;}
    String note(String id){try(Cursor c=getReadableDatabase().rawQuery("SELECT text FROM note WHERE target=?",new String[]{id})){return c.moveToFirst()?c.getString(0):"";}}
    synchronized void note(String id,String text){ContentValues v=new ContentValues();v.put("target",id);v.put("text",text);v.put("updated",System.currentTimeMillis());getWritableDatabase().insertWithOnConflict("note",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    synchronized void saveBundle(String id,String json){ContentValues v=new ContentValues();v.put("id",id);v.put("json",json);v.put("created",System.currentTimeMillis());getWritableDatabase().insertWithOnConflict("bundle",null,v,SQLiteDatabase.CONFLICT_REPLACE);}
    String lastBundle(){try(Cursor c=getReadableDatabase().rawQuery("SELECT json FROM bundle ORDER BY created DESC LIMIT 1",null)){return c.moveToFirst()?c.getString(0):null;}}
    synchronized JSONObject backup() throws JSONException {
        JSONObject root=new JSONObject().put("schema",1).put("app","Aaris Quran").put("created_at",System.currentTimeMillis());
        SQLiteDatabase db=getReadableDatabase();db.beginTransactionNonExclusive();
        try { for(String table:new String[]{"event","bookmark","note","setting","bundle"}) {
            JSONArray a=new JSONArray();try(Cursor c=getReadableDatabase().rawQuery("SELECT * FROM "+table,null)) {
                while(c.moveToNext()){JSONObject row=new JSONObject();for(int i=0;i<c.getColumnCount();i++)if(!"seq".equals(c.getColumnName(i)))row.put(c.getColumnName(i),c.getType(i)==Cursor.FIELD_TYPE_INTEGER?c.getLong(i):c.getString(i));a.put(row);}
            }root.put(table,a);
        }db.setTransactionSuccessful();return root;
        }finally{db.endTransaction();}
    }
    int validateBackup(JSONObject backup,ContentStore content) throws JSONException {
        return BackupValidator.validate(backup,content);
    }
    /** Merge by immutable event ID; incoming backups cannot erase current history. */
    synchronized void restore(JSONObject backup,ContentStore content) throws JSONException {
        validateBackup(backup,content);
        Map<String,String[]> fields=new LinkedHashMap<>();
        fields.put("event",new String[]{"id","target","kind","at","session","context","scheduler"});
        fields.put("bookmark",new String[]{"ayah_id","created"});fields.put("note",new String[]{"target","text","updated"});
        fields.put("setting",new String[]{"key","value"});fields.put("bundle",new String[]{"id","json","created"});
        SQLiteDatabase db=getWritableDatabase();db.beginTransaction();
        try {
            for(Map.Entry<String,String[]> f:fields.entrySet()) {
                JSONArray rows=backup.getJSONArray(f.getKey());for(int i=0;i<rows.length();i++) {
                    JSONObject row=rows.getJSONObject(i);ContentValues values=new ContentValues();
                    for(String key:f.getValue()){Object value=row.get(key);if(value instanceof Number)values.put(key,((Number)value).longValue());else values.put(key,String.valueOf(value));}
                    if("event".equals(f.getKey())) {
                        try(Cursor existing=db.rawQuery("SELECT target,kind,at,session,context,scheduler FROM event WHERE id=?",new String[]{row.getString("id")})) {
                            if(existing.moveToFirst()) {
                                for(int column=0;column<existing.getColumnCount();column++)
                                    if(!existing.getString(column).equals(values.getAsString(existing.getColumnName(column))))
                                        throw new JSONException("Conflicting event ID; nothing imported");
                                continue;
                            }
                        }
                        db.insertOrThrow(f.getKey(),null,values);
                    }else db.insertWithOnConflict(f.getKey(),null,values,SQLiteDatabase.CONFLICT_IGNORE);
                }
            }db.setTransactionSuccessful();
        }finally{db.endTransaction();cachedStates=null;lastEventTime=0;}
    }
}
