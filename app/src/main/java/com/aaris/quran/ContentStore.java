package com.aaris.quran;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import com.aaris.quran.core.*;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** APK-bundled content, verified before opening read-only. No network or learning writes. */
final class ContentStore implements AutoCloseable {
    static final class Surah {
        final int id,count;final String arabic,name,meaning,revelation;
        Surah(Cursor c){id=c.getInt(0);arabic=c.getString(1);name=c.getString(2);meaning=c.getString(3);count=c.getInt(4);revelation=c.getString(5);}
    }
    static final class Word {
        final String id,ayahId,arabic,surface,en,hi,ur,transliteration,source,state;
        final int position,start,end;
        Word(Cursor c){id=c.getString(0);ayahId=c.getString(1);position=c.getInt(2);start=c.getInt(3);end=c.getInt(4);
            arabic=c.getString(5);surface=c.getString(6);en=c.getString(7);hi=c.getString(8);ur=c.getString(9);
            transliteration=c.getString(10);source=c.getString(11);state=c.getString(12);}
        String gloss(String lang){String result="hi".equals(lang)?hi:"ur".equals(lang)?ur:en;return result==null?"Is lafz ka aligned source meaning abhi nahi hai.":result;}
        boolean hasGloss(){return "SOURCE_ALIGNED".equals(state)&&en!=null;}
    }
    private final SQLiteDatabase db;
    final List<Surah> surahs=new ArrayList<>();
    final String packHash,audioAlignmentHash;
    ContentStore(Context context) throws Exception {
        JSONObject manifest=new JSONObject(asset(context,"content-manifest.json"));
        packHash=manifest.getString("sqlite_sha256");
        audioAlignmentHash=manifest.getString("audio_alignment_sha256");
        if(audioAlignmentHash.length()!=64||manifest.optInt("audio_alignment_words",-1)!=77326)throw new IOException("Invalid Quran audio alignment identity");
        File folder=new File(context.getFilesDir(),"evidence");if(!folder.exists()&&!folder.mkdirs())throw new IOException("Cannot create evidence storage");
        File target=new File(folder,"quran-"+packHash.substring(0,16)+".sqlite");
        if(!target.exists()||!packHash.equals(hash(target))) {
            File staging=new File(folder,"install.tmp");
            try(InputStream in=context.getAssets().open("quran.sqlite");FileOutputStream out=new FileOutputStream(staging)) {
                byte[] bytes=new byte[65536];int n;while((n=in.read(bytes))!=-1)out.write(bytes,0,n);out.getFD().sync();
            }
            if(!packHash.equals(hash(staging))){staging.delete();throw new IOException("Content checksum mismatch");}
            if(target.exists()&&!target.delete())throw new IOException("Cannot replace corrupt content");
            if(!staging.renameTo(target))throw new IOException("Content install failed");
        }
        db=SQLiteDatabase.openDatabase(target.getAbsolutePath(),null,SQLiteDatabase.OPEN_READONLY);
        try(Cursor c=db.rawQuery("PRAGMA quick_check",null)){if(!c.moveToFirst()||!"ok".equals(c.getString(0)))throw new IOException("Content integrity check failed");}
        try(Cursor c=db.rawQuery("SELECT * FROM surah ORDER BY id",null)){while(c.moveToNext())surahs.add(new Surah(c));}
        if(surahs.size()!=114)throw new IOException("Incomplete Quran content");
    }
    static String asset(Context c,String name) throws IOException {
        try(InputStream in=c.getAssets().open(name);ByteArrayOutputStream out=new ByteArrayOutputStream()) {
            byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)out.write(b,0,n);return out.toString("UTF-8");
        }
    }
    static String hash(File file) throws Exception {
        MessageDigest sha=MessageDigest.getInstance("SHA-256");
        try(InputStream in=new FileInputStream(file)){byte[] b=new byte[65536];int n;while((n=in.read(b))!=-1)sha.update(b,0,n);}
        StringBuilder out=new StringBuilder();for(byte b:sha.digest())out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();
    }
    Surah surah(int id){return surahs.get(Math.max(1,Math.min(114,id))-1);}
    private Ayah ayah(Cursor c){return new Ayah(c.getInt(1),c.getInt(2),c.getString(3),c.getString(4),c.getInt(5));}
    Ayah ayah(String id){try(Cursor c=db.rawQuery("SELECT * FROM ayah WHERE id=?",new String[]{id})){return c.moveToFirst()?ayah(c):null;}}
    ReadingPosition readingPosition(String encoded) {
        ReadingPosition p=ReadingPosition.parse(encoded);if(p==null||ayah(p.pageId)==null)return null;
        Ayah anchor=ayah(p.anchorId);
        return anchor!=null&&p.codePoint<=anchor.arabic.codePointCount(0,anchor.arabic.length())?p:null;
    }
    List<Ayah> page(int surah,int start,int limit) {
        List<Ayah> list=new ArrayList<>();
        try(Cursor c=db.rawQuery("SELECT * FROM ayah WHERE surah=? AND number>=? ORDER BY number LIMIT ?",new String[]{""+surah,""+start,""+Math.min(limit,30)})){while(c.moveToNext())list.add(ayah(c));}
        return list;
    }
    List<Word> words(String ayahId) {
        List<Word> list=new ArrayList<>();
        try(Cursor c=db.rawQuery("SELECT * FROM word WHERE ayah_id=? ORDER BY start_cp",new String[]{ayahId})){while(c.moveToNext())list.add(new Word(c));}
        return list;
    }
    Word word(String id){try(Cursor c=db.rawQuery("SELECT * FROM word WHERE id=?",new String[]{id})){return c.moveToFirst()?new Word(c):null;}}
    Ayah contextFor(String id) {
        RecallTarget target=RecallTarget.parse(id);return target==null?null:ayah(target.ayahId);
    }
    AyahTransition transition(String id) {
        RecallTarget target=RecallTarget.parse(id);if(target==null||target.kind!=RecallTarget.Kind.TRANSITION)return null;
        Ayah from=ayah(target.ayahId),to=ayah(target.nextAyahId);
        if(from==null||to==null)return null;
        try{return new AyahTransition(from,to);}catch(IllegalArgumentException invalid){return null;}
    }
    boolean hasRecallTarget(String id) {
        RecallTarget target=RecallTarget.parse(id);
        return target!=null&&(target.kind==RecallTarget.Kind.TRANSITION?transition(id)!=null:recallText(id)!=null);
    }
    /** A phrase is an exact substring, including its source marks, never reconstructed text. */
    String recallText(String id) {
        RecallTarget target=RecallTarget.parse(id);if(target==null)return null;
        Ayah a=ayah(target.ayahId);if(a==null)return null;
        if(target.kind==RecallTarget.Kind.AYAH)return a.arabic;
        // Edges have two separately cited excerpts, never a fabricated combined verse.
        if(target.kind==RecallTarget.Kind.TRANSITION)return null;
        if(target.kind==RecallTarget.Kind.WORD||target.kind==RecallTarget.Kind.PREFATORY_WORD){Word w=word(id);return w==null?null:w.arabic;}
        Word first=word(target.ayahId+":W:"+target.first),last=word(target.ayahId+":W:"+target.last);
        if(first==null||last==null)return null;
        return a.arabic.substring(a.arabic.offsetByCodePoints(0,first.start),a.arabic.offsetByCodePoints(0,last.end));
    }
    List<Recall.Opportunity> upcoming(Collection<Recall.State> states,String fromId) {
        Ayah from=ayah(fromId);if(from==null)return Collections.emptyList();
        List<Recall.Opportunity> opportunities=new ArrayList<>();
        for(Recall.State state:states) {
            if(!state.active)continue;RecallTarget target=RecallTarget.parse(state.target);
            // Only the SAME saved word occurrence is proven here. Surface similarity is not sense identity.
            if(target==null||target.kind!=RecallTarget.Kind.WORD)continue;
            Ayah next=ayah(target.ayahId);if(next==null)continue;
            int distance=next.ordinal-from.ordinal;
            if(distance>=0&&distance<=10)opportunities.add(new Recall.Opportunity(state.target,distance,true));
        }
        return opportunities;
    }
    int occurrences(String surface) {try(Cursor c=db.rawQuery("SELECT count(*) FROM word WHERE surface_key=? AND position>0",new String[]{surface})){return c.moveToFirst()?c.getInt(0):0;}}
    List<Word> related(Word w) {
        List<Word> result=new ArrayList<>();
        // Same gloss/surface helps choose another context, never transfers a mastery score.
        try(Cursor c=db.rawQuery("SELECT * FROM word WHERE surface_key=? AND gloss_en=? AND ayah_id<>? ORDER BY id LIMIT 4",new String[]{w.surface,w.en,w.ayahId})){while(c.moveToNext())result.add(new Word(c));}
        return result;
    }
    SearchEngine buildSearch(TranslationStore translations) {
        Map<String,String> meanings=translations==null?Collections.emptyMap():translations.searchText();
        List<SearchEngine.Document> rows=new ArrayList<>();
        try(Cursor c=db.rawQuery("SELECT a.*,group_concat(COALESCE(w.gloss_en,'')||' '||COALESCE(w.gloss_hi,'')||' '||COALESCE(w.gloss_ur,'')||' '||COALESCE(w.transliteration,''),' '),group_concat(COALESCE(w.transliteration,''),' ') FROM ayah a LEFT JOIN word w ON w.ayah_id=a.id GROUP BY a.id ORDER BY a.ordinal",null)) {
            while(c.moveToNext()){if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();rows.add(new SearchEngine.Document(ayah(c),c.getString(6)+" "+meanings.getOrDefault(c.getString(0),""),c.getString(7)));}
        }
        return new SearchEngine(rows);
    }
    String sources(){try(Cursor c=db.rawQuery("SELECT value FROM provenance WHERE key='attribution'",null)){return c.moveToFirst()?c.getString(0):"";}}
    @Override public void close(){db.close();}
}
