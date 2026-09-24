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
    private static final String PINNED_QURAN_SHA256="4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f";
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
        String gloss(String lang){String result="hi".equals(lang)?hi:"ur".equals(lang)?ur:en;return result==null?"No aligned source meaning is available for this word yet.":result;}
        boolean hasGloss(String lang){
            String result="hi".equals(lang)?hi:"ur".equals(lang)?ur:en;
            boolean textAligned="SOURCE_ALIGNED".equals(state)||"SOURCE_ALIGNED_TEXT_ONLY".equals(state);
            return textAligned&&result!=null&&!result.trim().isEmpty();
        }
    }
    private final SQLiteDatabase db;
    final List<Surah> surahs=new ArrayList<>();
    private final int[] surahStarts=new int[115];
    final String packHash,audioAlignmentHash;
    ContentStore(Context context) throws Exception {
        JSONObject manifest=new JSONObject(asset(context,"content-manifest.json"));
        if(manifest.optInt("schema_version",-1)!=1||manifest.optInt("surahs",-1)!=114||manifest.optInt("ayahs",-1)!=6236)
            throw new IOException("Invalid Quran content manifest");
        if(!PINNED_QURAN_SHA256.equals(manifest.optString("quran_source_sha256")))
            throw new IOException("Quran source identity mismatch");
        packHash=manifest.getString("sqlite_sha256");
        audioAlignmentHash=manifest.getString("audio_alignment_sha256");
        if(!packHash.matches("[a-f0-9]{64}")||audioAlignmentHash.length()!=64||manifest.optInt("audio_alignment_words",-1)!=77326)
            throw new IOException("Invalid Quran content identity");
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
        SQLiteDatabase opened=SQLiteDatabase.openDatabase(target.getAbsolutePath(),null,SQLiteDatabase.OPEN_READONLY);
        try{
            try(Cursor c=opened.rawQuery("PRAGMA quick_check",null)){if(!c.moveToFirst()||!"ok".equals(c.getString(0)))throw new IOException("Content integrity check failed");}
            try(Cursor c=opened.rawQuery("PRAGMA user_version",null)){if(!c.moveToFirst()||c.getInt(0)!=1)throw new IOException("Quran schema mismatch");}
            try(Cursor c=opened.rawQuery("SELECT count(*) FROM ayah",null)){if(!c.moveToFirst()||c.getInt(0)!=6236)throw new IOException("Incomplete Quran ayah content");}
            int expectedWords=manifest.optInt("words",-1);
            try(Cursor c=opened.rawQuery("SELECT count(*) FROM word",null)){if(!c.moveToFirst()||expectedWords<1||c.getInt(0)!=expectedWords)throw new IOException("Incomplete Quran word content");}
            int ayahSum=0;
            try(Cursor c=opened.rawQuery("SELECT * FROM surah ORDER BY id",null)){while(c.moveToNext()){
                Surah s=new Surah(c);surahStarts[s.id]=ayahSum;surahs.add(s);ayahSum+=s.count;
            }}
            if(surahs.size()!=114||ayahSum!=6236)throw new IOException("Incomplete Quran surah metadata");
        }catch(Exception invalid){opened.close();throw invalid;}
        db=opened;
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
    Map<String,List<Word>> words(List<Ayah> ayahs) {
        LinkedHashMap<String,List<Word>> out=new LinkedHashMap<>();
        if(ayahs==null||ayahs.isEmpty())return out;
        List<String> ids=new ArrayList<>();
        for(Ayah ayah:ayahs)if(ayah!=null&&!out.containsKey(ayah.id)){out.put(ayah.id,new ArrayList<>());ids.add(ayah.id);}
        if(ids.isEmpty())return out;
        String marks=String.join(",",Collections.nCopies(ids.size(),"?"));
        try(Cursor c=db.rawQuery("SELECT * FROM word WHERE ayah_id IN ("+marks+") ORDER BY ayah_id,start_cp",ids.toArray(new String[0]))){
            while(c.moveToNext()){
                Word word=new Word(c);List<Word> list=out.get(word.ayahId);if(list!=null)list.add(word);
            }
        }
        return out;
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
    private int ordinal(int surah,int ayah){
        if(surah<1||surah>surahs.size())return -1;
        Surah info=surahs.get(surah-1);if(ayah<1||ayah>info.count)return -1;
        return surahStarts[surah]+ayah-1;
    }
    List<Recall.Opportunity> upcoming(Collection<Recall.State> states,String fromId) {
        RecallTarget from=RecallTarget.parse(fromId);
        int fromOrdinal=from==null?-1:ordinal(from.surah,from.ayah);if(fromOrdinal<0)return Collections.emptyList();
        List<Recall.Opportunity> opportunities=new ArrayList<>();
        for(Recall.State state:states) {
            if(!state.active)continue;RecallTarget target=RecallTarget.parse(state.target);
            // Only the SAME saved word occurrence is proven here. Surface similarity is not sense identity.
            if(target==null||target.kind!=RecallTarget.Kind.WORD)continue;
            int nextOrdinal=ordinal(target.surah,target.ayah);if(nextOrdinal<0)continue;
            int distance=nextOrdinal-fromOrdinal;
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
        // Keep source word order explicit. SQLite does not guarantee the input order of
        // group_concat(), and continuity/phonetic ranking must never depend on query-plan luck.
        try(Cursor c=db.rawQuery("SELECT a.id,a.surah,a.number,a.arabic,a.sha256,a.ordinal,"+
                "w.gloss_en,w.gloss_hi,w.gloss_ur,w.transliteration "+
                "FROM ayah a LEFT JOIN word w ON w.ayah_id=a.id "+
                "ORDER BY a.ordinal,w.position,w.start_cp",null)) {
            String currentId=null;Ayah current=null;
            StringBuilder hints=new StringBuilder(),sounds=new StringBuilder();
            while(c.moveToNext()){
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                String id=c.getString(0);
                if(currentId!=null&&!currentId.equals(id)){
                    appendSearchText(hints,meanings.get(currentId));
                    rows.add(new SearchEngine.Document(current,hints.toString(),sounds.toString()));
                    hints.setLength(0);sounds.setLength(0);
                }
                if(!id.equals(currentId)){currentId=id;current=ayah(c);}
                appendSearchText(hints,c.getString(6));
                appendSearchText(hints,c.getString(7));
                appendSearchText(hints,c.getString(8));
                appendSearchText(hints,c.getString(9));
                appendSearchText(sounds,c.getString(9));
            }
            if(currentId!=null){
                appendSearchText(hints,meanings.get(currentId));
                rows.add(new SearchEngine.Document(current,hints.toString(),sounds.toString()));
            }
        }
        return new SearchEngine(rows);
    }
    private static void appendSearchText(StringBuilder out,String value){
        if(value==null||value.trim().isEmpty())return;
        if(out.length()>0)out.append(' ');
        out.append(value);
    }
    String sources(){try(Cursor c=db.rawQuery("SELECT value FROM provenance WHERE key='attribution'",null)){return c.moveToFirst()?c.getString(0):"";}}
    @Override public void close(){db.close();}
}
