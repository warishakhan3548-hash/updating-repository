package com.aaris.quran;

import com.aaris.quran.core.Ayah;
import com.aaris.quran.core.Recall;
import com.aaris.quran.core.References;
import org.json.*;
import java.util.*;

/** Validate the whole import before beginning a write. A backup never becomes scripture. */
final class BackupValidator {
    private BackupValidator() {}
    private static final int MAX_ROWS=100000;
    static int validate(JSONObject backup,ContentStore content) throws JSONException {
        if(backup.getInt("schema")!=1||!"Aaris Quran".equals(backup.getString("app")))fail("Unsupported backup");
        Set<String> targets=new HashSet<>();int count=0;
        for(String table:new String[]{"event","bookmark","note","setting","bundle"}) {
            JSONArray rows=backup.getJSONArray(table);
            if(rows.length()>MAX_ROWS)fail("Too many "+table+" rows");
            Set<String> ids=new HashSet<>();
            for(int i=0;i<rows.length();i++) {
                JSONObject row=rows.getJSONObject(i);String key;
                switch(table) {
                    case "event":
                        key=string(row,"id",80,false);
                        target(string(row,"target",80,false),content,targets);
                        try{Recall.Kind.valueOf(string(row,"kind",24,false));}catch(IllegalArgumentException e){fail("Unknown event kind");}
                        timestamp(row,"at");string(row,"session",80,false);
                        String context=string(row,"context",80,false);
                        Ayah origin=content.contextFor(row.getString("target"));
                        if(origin==null||!origin.id.equals(context))fail("Unreviewed cross-context learning assertion");
                        if(!Recall.supportedScheduler(string(row,"scheduler",80,false)))fail("Unsupported scheduler history");
                        count++;break;
                    case "bookmark":
                        key=string(row,"ayah_id",80,false);
                        if(content.ayah(key)==null)fail("Unknown bookmark");timestamp(row,"created");break;
                    case "note":
                        key=string(row,"target",80,false);target(key,content,targets);
                        string(row,"text",8000,true);timestamp(row,"updated");break;
                    case "setting":
                        key=string(row,"key",80,false);setting(key,string(row,"value",65536,false),content);break;
                    case "bundle":
                        key=string(row,"id",80,false);timestamp(row,"created");
                        JSONObject bundle=new JSONObject(string(row,"json",2000000,false));
                        if(!key.equals(bundle.getString("bundle_id")))fail("Bundle identity mismatch");
                        validateBundle(bundle,content);break;
                    default:throw new AssertionError(table);
                }
                if(!ids.add(key))fail("Duplicate "+table+" identity");
            }
        }
        return count;
    }
    static Map<String,String> validateBundle(JSONObject bundle,ContentStore content) throws JSONException {
        if(bundle.getInt("schema")!=1)fail("Unsupported evidence schema");
        JSONArray records=bundle.getJSONArray("records");
        if(records.length()<1||records.length()>50)fail("Invalid evidence count");
        Map<String,String> snapshot=new LinkedHashMap<>();
        for(int i=0;i<records.length();i++) {
            JSONObject record=records.getJSONObject(i);String id=string(record,"citation_id",80,false);
            Ayah ayah=content.ayah(id);String text=string(record,"arabic",30000,false);
            if(ayah==null||!ayah.arabic.equals(text)||!ayah.sha256.equals(record.getString("sha256"))
                ||!References.sha256(text).equals(ayah.sha256))fail("Evidence differs from the installed source");
            if(record.getInt("surah")!=ayah.surah||record.getInt("ayah")!=ayah.number)fail("Citation coordinates differ");
            if(snapshot.put(id,text)!=null)fail("Duplicate evidence citation");
        }
        return snapshot;
    }
    private static void target(String id,ContentStore content,Set<String> known) throws JSONException {
        if(known.contains(id))return;
        if(!content.hasRecallTarget(id))fail("Unknown learning target");
        known.add(id);
    }
    private static void setting(String key,String value,ContentStore content) throws JSONException {
        switch(key) {
            case "language":if(!Arrays.asList("hi","ur","en").contains(value))fail("Invalid language");break;
            case "translation_edition":
                if(!value.matches("[a-z0-9_\\-]{1,80}"))fail("Invalid translation edition");break;
            case "study_pins_v1":
                ayahList(new JSONArray(value),10,content);break;
            case "study_collections_v1":
                JSONObject collections=new JSONObject(value);if(collections.length()>16)fail("Too many collections");
                Iterator<String> names=collections.keys();while(names.hasNext()){
                    String name=names.next();if(name.trim().isEmpty()||name.length()>64)fail("Invalid collection name");
                    ayahList(collections.getJSONArray(name),100,content);
                }break;
            case "search_aliases_v1":
                JSONArray aliases=new JSONArray(value);if(aliases.length()>100)fail("Too many search shortcuts");
                for(int i=0;i<aliases.length();i++){
                    JSONObject item=aliases.getJSONObject(i);String scope=string(item,"scope",8,false);
                    if(!Arrays.asList("quran","hadith").contains(scope))fail("Invalid search scope");
                    if(!string(item,"pack",64,false).matches("[a-f0-9]{64}"))fail("Invalid shortcut pack");
                    string(item,"query",256,false);String id=string(item,"target",80,false);timestamp(item,"at");
                    if("quran".equals(scope)&&content.ayah(id)==null)fail("Unknown Quran shortcut");
                }break;
            case "translation_issues_v1":
                JSONArray issues=new JSONArray(value);if(issues.length()>20)fail("Too many translation drafts");
                for(int i=0;i<issues.length();i++){
                    JSONObject item=issues.getJSONObject(i);if(content.ayah(string(item,"ayah",80,false))==null)fail("Unknown draft ayah");
                    string(item,"edition",80,false);string(item,"version",80,false);string(item,"text",2000,false);timestamp(item,"at");
                    if(!string(item,"pack",64,false).matches("[a-f0-9]{64}"))fail("Invalid draft pack");
                }break;
            case "contrast":if(!value.equals("true")&&!value.equals("false"))fail("Invalid contrast setting");break;
            case "arabic_size":
                try{float n=Float.parseFloat(value);if(!Float.isFinite(n)||n<24||n>46)fail("Invalid text size");}
                catch(NumberFormatException e){fail("Invalid text size");}break;
            case "position":if(content.ayah(value)==null)fail("Invalid reading position");break;
            case "reader_anchor":if(content.readingPosition(value)==null)fail("Invalid reading anchor");break;
            default:fail("Unknown setting: "+key);
        }
    }
    private static void ayahList(JSONArray ids,int maximum,ContentStore content)throws JSONException{
        if(ids.length()>maximum)fail("Too many ayahs");Set<String> unique=new HashSet<>();
        for(int i=0;i<ids.length();i++){String id=ids.getString(i);if(content.ayah(id)==null||!unique.add(id))fail("Invalid or duplicate ayah");}
    }
    private static long timestamp(JSONObject row,String key) throws JSONException {
        Object value=row.get(key);
        if(!(value instanceof Long)&&!(value instanceof Integer))fail("Invalid "+key);
        long at=((Number)value).longValue();
        if(at<0||at>253402300799999L)fail("Invalid timestamp");return at;
    }
    private static String string(JSONObject row,String key,int max,boolean empty) throws JSONException {
        Object value=row.get(key);if(!(value instanceof String))fail("Invalid "+key);
        String s=(String)value;if(s.length()>max||(!empty&&s.isEmpty()))fail("Invalid "+key);return s;
    }
    private static void fail(String message) throws JSONException {throw new JSONException(message);}
}
