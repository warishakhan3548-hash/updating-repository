package com.aaris.quran;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import org.json.JSONObject;

import java.io.*;
import java.security.MessageDigest;
import java.text.Normalizer;
import java.util.*;

/**
 * Immutable, APK-bundled Hadith content.
 *
 * The store never performs network I/O. A pack is optional during development; when present it is
 * checksum-verified, copied into private storage and opened read-only. User state must never be
 * written into this database.
 */
final class HadithStore implements AutoCloseable {
    static final class CollectionInfo {
        final String id,group,nameEn,nameAr,kind,edition,sourceName,sourceVersion;
        CollectionInfo(Cursor c){
            id=c.getString(0);group=c.getString(1);nameEn=c.getString(2);nameAr=c.getString(3);
            kind=c.getString(4);edition=c.getString(5);sourceName=c.getString(6);sourceVersion=c.getString(7);
        }
    }

    static final class Book {
        final String id,collectionId,number,nameEn,nameAr;
        Book(Cursor c){id=c.getString(0);collectionId=c.getString(1);number=c.getString(2);nameEn=c.getString(3);nameAr=c.getString(4);}
    }

    static final class Chapter {
        final String id,collectionId,bookId,number,nameEn,nameAr;
        Chapter(Cursor c){id=c.getString(0);collectionId=c.getString(1);bookId=c.getString(2);number=c.getString(3);nameEn=c.getString(4);nameAr=c.getString(5);}
    }

    static final class Record {
        final String id,collectionId,bookId,chapterId,recordNumber,kind;
        final String arabic,english,urdu,bangla,narratorEn,isnadAr,isnadEn,matnAr,matnEn,sourceRef;
        Record(Cursor c){
            id=c.getString(0);collectionId=c.getString(1);bookId=c.getString(2);chapterId=c.getString(3);
            recordNumber=c.getString(4);kind=c.getString(5);arabic=c.getString(6);english=c.getString(7);
            urdu=c.getString(8);bangla=c.getString(9);narratorEn=c.getString(10);isnadAr=c.getString(11);
            isnadEn=c.getString(12);matnAr=c.getString(13);matnEn=c.getString(14);sourceRef=c.getString(15);
        }
        String bestEnglish(){return english==null||english.trim().isEmpty()?null:english;}
    }

    static final class Grade {
        final String grade,grader,sourceVersion;
        Grade(Cursor c){grade=c.getString(0);grader=c.getString(1);sourceVersion=c.getString(2);}
    }

    private SQLiteDatabase db;
    private final List<CollectionInfo> collections=new ArrayList<>();
    private String packId="",packHash="",contentVersion="";
    private String unavailableReason="Hadith pack is not installed in this build.";

    HadithStore(Context context){
        try{
            if(!assetExists(context,"hadith-manifest.json")||!assetExists(context,"hadith.sqlite"))return;
            JSONObject manifest=new JSONObject(ContentStore.asset(context,"hadith-manifest.json"));
            packHash=manifest.getString("sqlite_sha256");
            packId=manifest.getString("pack_id");
            contentVersion=manifest.getString("content_version");
            int expectedRecords=manifest.getInt("records");
            int expectedCollections=manifest.getInt("collections");
            if(packHash.length()!=64||expectedRecords<=0||expectedCollections<=0)
                throw new IOException("Invalid Hadith manifest");

            File folder=new File(context.getFilesDir(),"evidence");
            if(!folder.exists()&&!folder.mkdirs())throw new IOException("Cannot create evidence storage");
            File target=new File(folder,"hadith-"+packHash.substring(0,16)+".sqlite");
            if(!target.exists()||!packHash.equals(ContentStore.hash(target))){
                File staging=new File(folder,"hadith-install.tmp");
                try(InputStream in=context.getAssets().open("hadith.sqlite");
                    FileOutputStream out=new FileOutputStream(staging)){
                    byte[] bytes=new byte[65536];int n;
                    while((n=in.read(bytes))!=-1)out.write(bytes,0,n);
                    out.getFD().sync();
                }
                if(!packHash.equals(ContentStore.hash(staging))){
                    staging.delete();throw new IOException("Hadith content checksum mismatch");
                }
                if(target.exists()&&!target.delete())throw new IOException("Cannot replace corrupt Hadith content");
                if(!staging.renameTo(target))throw new IOException("Hadith content install failed");
            }

            db=SQLiteDatabase.openDatabase(target.getAbsolutePath(),null,SQLiteDatabase.OPEN_READONLY);
            try(Cursor c=db.rawQuery("PRAGMA quick_check",null)){
                if(!c.moveToFirst()||!"ok".equals(c.getString(0)))throw new IOException("Hadith integrity check failed");
            }
            int actualRecords=count("hadith"),actualCollections=count("collection");
            if(actualRecords!=expectedRecords||actualCollections!=expectedCollections)
                throw new IOException("Hadith manifest count mismatch");

            try(Cursor c=db.rawQuery("SELECT id,group_name,name_en,name_ar,kind,edition,source_name,source_version FROM collection ORDER BY name_en",null)){
                while(c.moveToNext())collections.add(new CollectionInfo(c));
            }
            unavailableReason="";
        }catch(Exception e){
            close();
            unavailableReason="Hadith pack could not be opened: "+safeMessage(e);
        }
    }

    private static String safeMessage(Exception e){
        String m=e.getMessage();return m==null||m.trim().isEmpty()?e.getClass().getSimpleName():m;
    }

    private static boolean assetExists(Context context,String name){
        try(InputStream ignored=context.getAssets().open(name)){return true;}catch(IOException missing){return false;}
    }

    boolean available(){return db!=null&&!collections.isEmpty();}
    String unavailableReason(){return unavailableReason;}
    String packId(){return packId;}
    String contentVersion(){return contentVersion;}
    String packHash(){return packHash;}
    List<CollectionInfo> collections(){return Collections.unmodifiableList(collections);}

    private int count(String table){
        try(Cursor c=db.rawQuery("SELECT COUNT(*) FROM "+table,null)){return c.moveToFirst()?c.getInt(0):0;}
    }

    int recordCount(String collectionId){
        if(db==null)return 0;
        try(Cursor c=db.rawQuery("SELECT COUNT(*) FROM hadith WHERE collection_id=?",new String[]{collectionId})){
            return c.moveToFirst()?c.getInt(0):0;
        }
    }

    List<Book> books(String collectionId){
        List<Book> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery(
            "SELECT id,collection_id,number,name_en,name_ar FROM book WHERE collection_id=? ORDER BY CAST(number AS INTEGER),number",
            new String[]{collectionId})){
            while(c.moveToNext())out.add(new Book(c));
        }return out;
    }

    List<Chapter> chapters(String collectionId,String bookId){
        List<Chapter> out=new ArrayList<>();if(db==null)return out;
        String sql;String[] args;
        if(bookId==null){
            sql="SELECT id,collection_id,book_id,number,name_en,name_ar FROM chapter WHERE collection_id=? AND book_id IS NULL ORDER BY CAST(number AS INTEGER),number";
            args=new String[]{collectionId};
        }else{
            sql="SELECT id,collection_id,book_id,number,name_en,name_ar FROM chapter WHERE collection_id=? AND book_id=? ORDER BY CAST(number AS INTEGER),number";
            args=new String[]{collectionId,bookId};
        }
        try(Cursor c=db.rawQuery(sql,args)){while(c.moveToNext())out.add(new Chapter(c));}
        return out;
    }

    List<Record> records(String collectionId,String bookId,String chapterId,int limit,int offset){
        List<Record> out=new ArrayList<>();if(db==null)return out;
        limit=Math.max(1,Math.min(100,limit));offset=Math.max(0,offset);
        StringBuilder where=new StringBuilder("collection_id=?");List<String> args=new ArrayList<>();args.add(collectionId);
        if(bookId!=null){where.append(" AND book_id=?");args.add(bookId);}
        if(chapterId!=null){where.append(" AND chapter_id=?");args.add(chapterId);}
        args.add(""+limit);args.add(""+offset);
        try(Cursor c=db.rawQuery(
            "SELECT id,collection_id,book_id,chapter_id,record_number,record_kind,arabic,english,urdu,bangla,narrator_en,isnad_ar,isnad_en,matn_ar,matn_en,source_ref "+
            "FROM hadith WHERE "+where+" ORDER BY CAST(record_number AS INTEGER),record_number LIMIT ? OFFSET ?",
            args.toArray(new String[0]))){
            while(c.moveToNext())out.add(new Record(c));
        }
        return out;
    }

    Record record(String id){
        if(db==null)return null;
        try(Cursor c=db.rawQuery(
            "SELECT id,collection_id,book_id,chapter_id,record_number,record_kind,arabic,english,urdu,bangla,narrator_en,isnad_ar,isnad_en,matn_ar,matn_en,source_ref FROM hadith WHERE id=?",
            new String[]{id})){
            return c.moveToFirst()?new Record(c):null;
        }
    }

    List<Grade> grades(String recordId){
        List<Grade> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT grade,grader,source_version FROM grade_assertion WHERE hadith_id=? ORDER BY grader,grade",new String[]{recordId})){
            while(c.moveToNext())out.add(new Grade(c));
        }return out;
    }

    List<Record> search(String query,String collectionId,int limit){
        List<Record> out=new ArrayList<>();if(db==null)return out;
        query=query==null?"":query.trim();if(query.isEmpty())return out;
        limit=Math.max(1,Math.min(100,limit));
        String ar=normalizeArabic(query),latin=normalizeLatin(query);
        String likeAr="%"+escapeLike(ar)+"%",likeLatin="%"+escapeLike(latin)+"%";
        List<String> args=new ArrayList<>();
        StringBuilder where=new StringBuilder();
        if(collectionId!=null&&!collectionId.isEmpty()){where.append("collection_id=? AND ");args.add(collectionId);}
        where.append("(record_number=? OR arabic_search LIKE ? ESCAPE '\\' OR english_search LIKE ? ESCAPE '\\' OR id=?)");
        args.add(query);args.add(likeAr);args.add(likeLatin);args.add(query);args.add(""+limit);
        try(Cursor c=db.rawQuery(
            "SELECT id,collection_id,book_id,chapter_id,record_number,record_kind,arabic,english,urdu,bangla,narrator_en,isnad_ar,isnad_en,matn_ar,matn_en,source_ref "+
            "FROM hadith WHERE "+where+" ORDER BY CASE WHEN record_number=? THEN 0 ELSE 1 END, collection_id, CAST(record_number AS INTEGER), record_number LIMIT ?",
            appendBeforeLast(args,query))){
            while(c.moveToNext())out.add(new Record(c));
        }
        return out;
    }

    private static String[] appendBeforeLast(List<String> args,String value){
        // ORDER BY adds one placeholder before the final LIMIT placeholder.
        List<String> copy=new ArrayList<>(args);
        copy.add(copy.size()-1,value);
        return copy.toArray(new String[0]);
    }

    static String normalizeArabic(String value){
        String n=Normalizer.normalize(value,Normalizer.Form.NFC);
        StringBuilder out=new StringBuilder();
        for(int i=0;i<n.length();){
            int cp=n.codePointAt(i);i+=Character.charCount(cp);
            int type=Character.getType(cp);
            if(type==Character.NON_SPACING_MARK||type==Character.COMBINING_SPACING_MARK||cp==0x0640)continue;
            if(cp==0x0671||cp==0x0622||cp==0x0623||cp==0x0625)cp=0x0627;
            out.appendCodePoint(cp);
        }
        return out.toString().trim();
    }

    static String normalizeLatin(String value){
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+"," ").trim();
    }

    private static String escapeLike(String value){
        return value.replace("\\","\\\\").replace("%","\\%").replace("_","\\_");
    }

    @Override public void close(){
        if(db!=null){db.close();db=null;}collections.clear();
    }
}
