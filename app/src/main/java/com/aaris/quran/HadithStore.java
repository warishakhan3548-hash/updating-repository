package com.aaris.quran;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteException;
import org.json.JSONObject;
import org.json.JSONArray;
import java.io.*;
import java.text.Normalizer;
import java.util.*;

/** Verified APK-bundled Hadith content. Source records are read-only; user data lives elsewhere. */
final class HadithStore implements AutoCloseable {
    static final class CollectionInfo {
        final String id,group,nameEn,nameAr,edition; final int count;
        CollectionInfo(Cursor c){id=c.getString(0);group=c.getString(1);nameEn=c.getString(2);
            nameAr=c.getString(3);edition=c.getString(4);count=c.getInt(5);}
    }
    static final class BookInfo {
        final String id,collectionId,number,nameEn,nameAr; final int count;
        BookInfo(Cursor c){id=c.getString(0);collectionId=c.getString(1);number=c.getString(2);
            nameEn=c.getString(3);nameAr=c.getString(4);count=c.getInt(5);}
    }
    static final class ChapterInfo {
        final String id,collectionId,bookId,number,nameEn,nameAr; final int count;
        ChapterInfo(Cursor c){id=c.getString(0);collectionId=c.getString(1);bookId=c.getString(2);
            number=c.getString(3);nameEn=c.getString(4);nameAr=c.getString(5);count=c.getInt(6);}
    }
    static final class Record {
        final String id,collectionId,bookId,chapterId,number,arabic,english,urdu,bangla,
            narrator,isnadAr,isnadEn,matnAr,matnEn,sourceRef;
        Record(Cursor c){id=c.getString(0);collectionId=c.getString(1);bookId=c.getString(2);
            chapterId=c.getString(3);number=c.getString(4);arabic=c.getString(5);
            english=c.getString(6);urdu=c.getString(7);bangla=c.getString(8);
            narrator=c.getString(9);isnadAr=c.getString(10);isnadEn=c.getString(11);
            matnAr=c.getString(12);matnEn=c.getString(13);sourceRef=c.getString(14);}
    }
    static final class DisplayTranslation {
        final String language,text,provenance;
        DisplayTranslation(String language,String text,String provenance){
            this.language=language;this.text=text;this.provenance=provenance;
        }
    }

    private static final String RECORD_COLUMNS =
        "h.id,h.collection_id,h.book_id,h.chapter_id,h.record_number,h.arabic,h.english,"+
        "h.urdu,h.bangla,h.narrator_en,h.isnad_ar,h.isnad_en,h.matn_ar,h.matn_en,h.source_ref";
    private SQLiteDatabase db;
    final String packHash,packId,contentVersion,sourceName,sourceVersion,redistributionBasis;
    final int recordCount,collectionCount;
    final Set<String> languageCoverage;

    static HadithStore openIfBundled(Context context) throws Exception {
        boolean manifest=false,database=false;
        String[] root=context.getAssets().list("");
        if(root!=null)for(String name:root){
            if("hadith-manifest.json".equals(name))manifest=true;
            if("hadith.sqlite".equals(name))database=true;
        }
        if(!manifest&&!database)return null;
        if(manifest!=database)throw new IOException("Incomplete bundled Hadith pack");
        return new HadithStore(context);
    }

    private HadithStore(Context context) throws Exception {
        JSONObject manifest=new JSONObject(ContentStore.asset(context,"hadith-manifest.json"));
        if(manifest.getInt("schema_version")!=2)throw new IOException("Unsupported Hadith pack schema");
        packHash=manifest.getString("sqlite_sha256");
        packId=manifest.getString("pack_id");
        contentVersion=manifest.getString("content_version");
        sourceName=manifest.getString("source_name");
        sourceVersion=manifest.getString("source_version");
        redistributionBasis=manifest.optString("redistribution_basis","Source license recorded in pack manifest");
        LinkedHashSet<String> languages=new LinkedHashSet<>();
        JSONArray languageArray=manifest.optJSONArray("language_coverage");
        if(languageArray!=null)for(int i=0;i<languageArray.length();i++){
            String code=languageArray.optString(i,"").trim().toLowerCase(Locale.ROOT);
            if(!code.isEmpty())languages.add(code);
        }
        if(languages.isEmpty())languages.add("ar");
        languageCoverage=Collections.unmodifiableSet(languages);
        recordCount=manifest.getInt("records");
        collectionCount=manifest.getInt("collections");
        if(packHash.length()!=64||recordCount<1||collectionCount<1)throw new IOException("Invalid Hadith manifest");

        File folder=new File(context.getFilesDir(),"evidence");
        if(!folder.exists()&&!folder.mkdirs())throw new IOException("Cannot create evidence storage");
        File target=new File(folder,"hadith-"+packHash.substring(0,16)+".sqlite");
        if(!target.exists()||!packHash.equals(ContentStore.hash(target))){
            File staging=new File(folder,"hadith-install.tmp");
            if(staging.exists()&&!staging.delete())throw new IOException("Cannot clear Hadith staging file");
            try(InputStream in=context.getAssets().open("hadith.sqlite");FileOutputStream out=new FileOutputStream(staging)){
                byte[] bytes=new byte[65536];int n;
                while((n=in.read(bytes))!=-1)out.write(bytes,0,n);
                out.getFD().sync();
            }
            if(!packHash.equals(ContentStore.hash(staging))){staging.delete();throw new IOException("Hadith checksum mismatch");}
            if(target.exists()&&!target.delete())throw new IOException("Cannot replace corrupt Hadith pack");
            if(!staging.renameTo(target))throw new IOException("Hadith pack install failed");
        }
        db=SQLiteDatabase.openDatabase(target.getAbsolutePath(),null,SQLiteDatabase.OPEN_READONLY);
        try(Cursor c=db.rawQuery("PRAGMA quick_check",null)){
            if(!c.moveToFirst()||!"ok".equals(c.getString(0)))throw new IOException("Hadith integrity check failed");
        }
        try(Cursor c=db.rawQuery("PRAGMA user_version",null)){
            if(!c.moveToFirst()||c.getInt(0)!=2)throw new IOException("Hadith schema mismatch");
        }
        try(Cursor c=db.rawQuery("SELECT count(*) FROM hadith",null)){
            if(!c.moveToFirst()||c.getInt(0)!=recordCount)throw new IOException("Hadith record count mismatch");
        }
        try(Cursor c=db.rawQuery("SELECT count(*) FROM collection",null)){
            if(!c.moveToFirst()||c.getInt(0)!=collectionCount)throw new IOException("Hadith collection count mismatch");
        }
    }

    List<CollectionInfo> collections(){
        List<CollectionInfo> out=new ArrayList<>();
        if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT c.id,c.group_name,c.name_en,c.name_ar,c.edition,count(h.id) "+
            "FROM collection c LEFT JOIN hadith h ON h.collection_id=c.id GROUP BY c.id "+
            "ORDER BY c.group_name,c.name_en",null)){while(c.moveToNext())out.add(new CollectionInfo(c));}
        return out;
    }

    CollectionInfo collection(String id){
        if(db==null)return null;
        try(Cursor c=db.rawQuery("SELECT c.id,c.group_name,c.name_en,c.name_ar,c.edition,count(h.id) "+
            "FROM collection c LEFT JOIN hadith h ON h.collection_id=c.id WHERE c.id=? GROUP BY c.id",
            new String[]{id})){return c.moveToFirst()?new CollectionInfo(c):null;}
    }

    List<BookInfo> books(String collectionId){
        List<BookInfo> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT b.id,b.collection_id,b.number,b.name_en,b.name_ar,count(h.id) "+
            "FROM book b LEFT JOIN hadith h ON h.book_id=b.id WHERE b.collection_id=? "+
            "GROUP BY b.id ORDER BY CAST(b.number AS INTEGER),b.number",new String[]{collectionId})){
            while(c.moveToNext())out.add(new BookInfo(c));
        }
        return out;
    }

    List<ChapterInfo> chapters(String collectionId,String bookId){
        List<ChapterInfo> out=new ArrayList<>();if(db==null)return out;
        String sql="SELECT ch.id,ch.collection_id,ch.book_id,ch.number,ch.name_en,ch.name_ar,count(h.id) "+
            "FROM chapter ch LEFT JOIN hadith h ON h.chapter_id=ch.id WHERE ch.collection_id=? AND "+
            (bookId==null?"ch.book_id IS NULL":"ch.book_id=?")+
            " GROUP BY ch.id ORDER BY CAST(ch.number AS INTEGER),ch.number";
        String[] args=bookId==null?new String[]{collectionId}:new String[]{collectionId,bookId};
        try(Cursor c=db.rawQuery(sql,args)){while(c.moveToNext())out.add(new ChapterInfo(c));}
        return out;
    }

    List<Record> records(String collectionId,String bookId,String chapterId,int limit,int offset){
        List<Record> out=new ArrayList<>();if(db==null)return out;
        List<String> args=new ArrayList<>();StringBuilder where=new StringBuilder("h.collection_id=?");args.add(collectionId);
        if(bookId!=null){where.append(" AND h.book_id=?");args.add(bookId);}
        if(chapterId!=null){where.append(" AND h.chapter_id=?");args.add(chapterId);}
        args.add(""+Math.max(1,Math.min(200,limit)));args.add(""+Math.max(0,offset));
        try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE "+where+
            " ORDER BY h.rowid LIMIT ? OFFSET ?",args.toArray(new String[0]))){
            while(c.moveToNext())out.add(new Record(c));
        }
        return out;
    }

    Record record(String id){
        if(db==null)return null;
        try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE h.id=?",
            new String[]{id})){return c.moveToFirst()?new Record(c):null;}
    }

    List<Record> search(String query,int limit){
        String raw=query==null?"":query.trim();if(raw.isEmpty()||db==null)return Collections.emptyList();
        int cap=Math.max(1,Math.min(100,limit));
        LinkedHashMap<String,Record> unique=new LinkedHashMap<>();

        // Exact identities/references always come first and do not depend on tokenization.
        try(Cursor c=db.rawQuery("SELECT DISTINCT "+RECORD_COLUMNS+" FROM hadith h "+
            "LEFT JOIN hadith_reference r ON r.hadith_id=h.id WHERE h.id=? OR h.record_number=? OR r.value=? "+
            "ORDER BY h.collection_id,h.rowid LIMIT ?",
            new String[]{raw,raw,raw,""+cap})){
            while(c.moveToNext()){Record record=new Record(c);unique.put(record.id,record);}
        }

        String match=ftsQuery(raw);
        if(!match.isEmpty()&&unique.size()<cap){
            try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith_fts f "+
                "JOIN hadith h ON h.id=f.hadith_id WHERE hadith_fts MATCH ? "+
                "ORDER BY h.collection_id,h.rowid LIMIT ?",
                new String[]{match,""+cap})){
                while(c.moveToNext()&&unique.size()<cap){Record record=new Record(c);unique.put(record.id,record);}
            }catch(SQLiteException unavailable){
                // Compatibility fallback for an older local pack. New schema-2 packs always include FTS4.
                String ar=normalizeArabic(raw),latin=normalizeLatin(raw);
                try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE "+
                    "h.search_ar LIKE ? OR h.search_latin LIKE ? ORDER BY h.collection_id,h.rowid LIMIT ?",
                    new String[]{"%"+ar+"%","%"+latin+"%",""+cap})){
                    while(c.moveToNext()&&unique.size()<cap){Record record=new Record(c);unique.put(record.id,record);}
                }
            }
        }
        return new ArrayList<>(unique.values());
    }

    private static String ftsQuery(String raw){
        String normalized=normalizeArabic(normalizeLatin(raw));
        StringBuilder query=new StringBuilder();
        for(String token:normalized.split("\\s+")){
            token=token.replaceAll("[^\\p{L}\\p{N}]+","");
            if(token.isEmpty())continue;
            if(query.length()>0)query.append(" AND ");
            query.append('"').append(token.replace("\"","\"\"")).append('"');
        }
        return query.toString();
    }

    List<String> grades(String id){
        List<String> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT grade,grader,source_version FROM grade_assertion "+
            "WHERE hadith_id=? ORDER BY id",new String[]{id})){
            while(c.moveToNext())out.add(c.getString(0)+" · "+c.getString(1)+" · "+c.getString(2));
        }
        return out;
    }

    List<String> references(String id){
        List<String> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT scheme,value FROM hadith_reference WHERE hadith_id=? ORDER BY id",
            new String[]{id})){while(c.moveToNext())out.add(c.getString(0)+": "+c.getString(1));}
        return out;
    }

    boolean hasLanguage(String code){
        return code!=null&&languageCoverage.contains(code.toLowerCase(Locale.ROOT));
    }

    String searchHint(){
        return hasLanguage("en")?"Search Arabic, English or Hadith number":"Search Arabic or Hadith number";
    }

    DisplayTranslation translation(Record record,String preferredLanguage){
        if(record==null||db==null)return null;
        String preferred=preferredLanguage==null?"en":preferredLanguage.toLowerCase(Locale.ROOT);
        LinkedHashSet<String> candidates=new LinkedHashSet<>();
        if("hi".equals(preferred)){candidates.add("hi");candidates.add("en");}
        else if("ur".equals(preferred)){candidates.add("ur");candidates.add("en");}
        else if("bn".equals(preferred)){candidates.add("bn");candidates.add("en");}
        else{candidates.add(preferred);candidates.add("en");}

        for(String language:candidates){
            try(Cursor cursor=db.rawQuery(
                "SELECT text,revision,status,source_ref FROM editorial_translation "+
                "WHERE hadith_id=? AND language=? AND status IN ('released','reviewed') "+
                "ORDER BY CASE status WHEN 'released' THEN 0 ELSE 1 END,rowid DESC LIMIT 1",
                new String[]{record.id,language})){
                if(cursor.moveToFirst()){
                    String provenance="Aaris "+cursor.getString(2)+" · revision "+cursor.getString(1);
                    String source=cursor.getString(3);if(source!=null&&!source.trim().isEmpty())provenance+=" · "+source;
                    return new DisplayTranslation(language,cursor.getString(0),provenance);
                }
            }
            String sourceText=null;
            if("en".equals(language))sourceText=record.english;
            else if("ur".equals(language))sourceText=record.urdu;
            else if("bn".equals(language))sourceText=record.bangla;
            if(sourceText!=null&&!sourceText.trim().isEmpty())
                return new DisplayTranslation(language,sourceText,"Imported source translation · "+sourceName);
        }
        return null;
    }

    private static String normalizeArabic(String value){
        String s=Normalizer.normalize(value,Normalizer.Form.NFC)
            .replace("ٱ","ا").replace("أ","ا").replace("إ","ا").replace("آ","ا")
            .replace("ى","ي").replace("ؤ","و").replace("ئ","ي").replace("ـ","");
        StringBuilder out=new StringBuilder();
        for(int i=0;i<s.length();i++){char ch=s.charAt(i);int type=Character.getType(ch);
            if(type!=Character.NON_SPACING_MARK&&type!=Character.COMBINING_SPACING_MARK)out.append(ch);}
        return out.toString().replaceAll("\\s+"," ").trim();
    }
    private static String normalizeLatin(String value){
        String s=Normalizer.normalize(value,Normalizer.Form.NFKD).toLowerCase(Locale.ROOT);
        StringBuilder out=new StringBuilder();
        for(int i=0;i<s.length();i++){char ch=s.charAt(i);int type=Character.getType(ch);
            if(type!=Character.NON_SPACING_MARK&&type!=Character.COMBINING_SPACING_MARK)out.append(ch);}
        return out.toString().replaceAll("\\s+"," ").trim();
    }

    @Override public void close(){if(db!=null){db.close();db=null;}}
}
