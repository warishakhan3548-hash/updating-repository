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
    /** Explicit query-to-record shortcuts, scoped to the immutable pack; never corpus edits. */
    synchronized void confirmSearch(String scope,String pack,String query,String target){
        String key=com.aaris.quran.core.TextMatch.normalize(query);
        if(key.isEmpty()||key.length()>256||!pack.matches("[a-f0-9]{64}")||target.length()>80||
            !Arrays.asList("quran","hadith").contains(scope))throw new IllegalArgumentException("Invalid search shortcut");
        try{
            JSONArray current=new JSONArray(get("search_aliases_v1","[]")),next=new JSONArray();
            long now=System.currentTimeMillis();
            for(int i=Math.max(0,current.length()-99);i<current.length();i++){
                JSONObject item=current.getJSONObject(i);
                if(item.optLong("at",0)>now||now-item.optLong("at",0)>180L*86400000)continue;
                if(scope.equals(item.optString("scope"))&&pack.equals(item.optString("pack"))&&key.equals(item.optString("query")))continue;
                next.put(item);
            }
            next.put(new JSONObject().put("scope",scope).put("pack",pack).put("query",key).put("target",target).put("at",now));
            boundedRecords("search_aliases_v1",next);
        }catch(JSONException e){throw new IllegalStateException("Search shortcut storage is invalid",e);}
    }
    String confirmedSearch(String scope,String pack,String query){
        String key=com.aaris.quran.core.TextMatch.normalize(query);long now=System.currentTimeMillis();
        try{JSONArray items=new JSONArray(get("search_aliases_v1","[]"));for(int i=items.length()-1;i>=0;i--){
            JSONObject item=items.getJSONObject(i);
            if(scope.equals(item.optString("scope"))&&pack.equals(item.optString("pack"))&&key.equals(item.optString("query"))&&
                item.optLong("at",0)<=now&&now-item.optLong("at",0)<=180L*86400000)return item.optString("target","");
        }}catch(JSONException ignored){}return "";
    }
    synchronized void clearSearchShortcuts(){set("search_aliases_v1","[]");}
    List<String> pinnedAyahs(){
        List<String> out=new ArrayList<>();try{JSONArray a=new JSONArray(get("study_pins_v1","[]"));for(int i=0;i<Math.min(10,a.length());i++)out.add(a.getString(i));}catch(JSONException ignored){}return out;
    }
    synchronized boolean togglePin(String id){
        List<String> ids=pinnedAyahs();if(ids.contains(id))ids.remove(id);else{if(ids.size()>=10)return false;ids.add(id);}
        set("study_pins_v1",new JSONArray(ids).toString());return true;
    }
    Map<String,List<String>> collections(){
        Map<String,List<String>> out=new TreeMap<>();try{JSONObject root=new JSONObject(get("study_collections_v1","{}"));
            Iterator<String> keys=root.keys();while(keys.hasNext()){String name=keys.next();JSONArray a=root.getJSONArray(name);List<String> ids=new ArrayList<>();for(int i=0;i<a.length();i++)ids.add(a.getString(i));out.put(name,ids);}
        }catch(JSONException ignored){}return out;
    }
    synchronized void collect(String name,String id,boolean add){
        name=name.trim();if(name.isEmpty()||name.length()>64)throw new IllegalArgumentException("Use a collection name of 1–64 characters");
        Map<String,List<String>> all=collections();
        if(add&&!all.containsKey(name)&&all.size()>=16)throw new IllegalArgumentException("Up to 16 collections");
        List<String> ids=all.computeIfAbsent(name,k->new ArrayList<>());
        if(add&&!ids.contains(id)){if(ids.size()>=100)throw new IllegalArgumentException("Up to 100 ayahs per collection");ids.add(id);}else if(!add)ids.remove(id);
        JSONObject root=new JSONObject();try{for(Map.Entry<String,List<String>> item:all.entrySet())if(!item.getValue().isEmpty())root.put(item.getKey(),new JSONArray(item.getValue()));}catch(JSONException e){throw new IllegalStateException(e);}
        set("study_collections_v1",root.toString());
    }
    synchronized void translationIssue(String ayah,String edition,String version,String pack,String text){
        if(text.trim().isEmpty()||text.length()>2000)throw new IllegalArgumentException("Write 1–2,000 characters");
        try{JSONArray current=new JSONArray(get("translation_issues_v1","[]")),next=new JSONArray();
            for(int i=Math.max(0,current.length()-19);i<current.length();i++)next.put(current.getJSONObject(i));
            next.put(new JSONObject().put("ayah",ayah).put("edition",edition).put("version",version).put("pack",pack).put("text",text).put("at",System.currentTimeMillis()));
            boundedRecords("translation_issues_v1",next);
        }catch(JSONException e){throw new IllegalStateException(e);}
    }
    private void boundedRecords(String key,JSONArray rows){
        String encoded=rows.toString();while(encoded.length()>65536&&rows.length()>1){rows.remove(0);encoded=rows.toString();}
        if(encoded.length()>65536)throw new IllegalArgumentException("Local records exceed backup size limit");set(key,encoded);
    }
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
