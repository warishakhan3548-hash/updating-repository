package com.aaris.quran;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import org.json.JSONObject;
import java.io.*;
import java.util.Locale;

/**
 * Immutable APK-bundled Quran word-audio pack.
 *
 * Word identity always comes from the canonical Quran database. Audio bytes are stored in only
 * 114 uncompressed Surah pack assets; a verified local SQLite index maps Word ID -> byte slice.
 * No runtime URL, network fallback, or temporary per-word extraction is used.
 */
final class QuranAudioStore implements AutoCloseable {
    static final class Clip {
        final int surah; final long offset,length;
        Clip(int surah,long offset,long length){this.surah=surah;this.offset=offset;this.length=length;}
    }

    private static final String MANIFEST="quran-audio/manifest.json";
    private final Context context;
    private SQLiteDatabase index;
    final String packId,sourceName,sourceVersion,license,style,packRoot,indexAsset,indexHash,canonicalQuranHash;
    final int wordCount;
    final boolean complete;

    static QuranAudioStore openIfBundled(Context context,String quranPackHash) throws Exception {
        boolean folder=false;
        String[] root=context.getAssets().list("");
        if(root!=null)for(String name:root)if("quran-audio".equals(name)){folder=true;break;}
        if(!folder)return null;
        return new QuranAudioStore(context,new JSONObject(ContentStore.asset(context,MANIFEST)),quranPackHash);
    }

    private QuranAudioStore(Context context,JSONObject manifest,String quranPackHash) throws Exception {
        this.context=context.getApplicationContext();
        if(manifest.getInt("schema_version")!=2)throw new IOException("Unsupported Quran audio pack schema");
        if(manifest.optBoolean("runtime_network_required",true))
            throw new IOException("Quran audio pack may not require runtime network access");
        packId=required(manifest,"pack_id");
        sourceName=required(manifest,"source_name");
        sourceVersion=required(manifest,"source_version");
        license=required(manifest,"license");
        style=required(manifest,"style");
        packRoot=required(manifest,"pack_root");
        indexAsset=required(manifest,"index_asset");
        indexHash=required(manifest,"index_sha256");
        canonicalQuranHash=required(manifest,"canonical_quran_sqlite_sha256");
        wordCount=manifest.getInt("word_count");
        complete=manifest.optBoolean("coverage_complete",false);
        if(wordCount<1||indexHash.length()!=64||canonicalQuranHash.length()!=64)throw new IOException("Invalid Quran audio manifest");
        if(quranPackHash==null||!canonicalQuranHash.equals(quranPackHash))
            throw new IOException("Quran audio pack was built for a different canonical Quran pack");
        if(!packRoot.startsWith("quran-audio/")||packRoot.contains("..")||
           !indexAsset.startsWith("quran-audio/")||indexAsset.contains(".."))
            throw new IOException("Unsafe Quran audio asset path");

        File folder=new File(context.getFilesDir(),"evidence");
        if(!folder.exists()&&!folder.mkdirs())throw new IOException("Cannot create evidence storage");
        File target=new File(folder,"quran-audio-index-"+indexHash.substring(0,16)+".sqlite");
        if(!target.exists()||!indexHash.equals(ContentStore.hash(target))){
            File staging=new File(folder,"quran-audio-index.tmp");
            if(staging.exists()&&!staging.delete())throw new IOException("Cannot clear Quran audio staging index");
            try(InputStream in=context.getAssets().open(indexAsset);FileOutputStream out=new FileOutputStream(staging)){
                byte[] bytes=new byte[65536];int n;
                while((n=in.read(bytes))!=-1)out.write(bytes,0,n);
                out.getFD().sync();
            }
            if(!indexHash.equals(ContentStore.hash(staging))){
                staging.delete();throw new IOException("Quran audio index checksum mismatch");
            }
            if(target.exists()&&!target.delete())throw new IOException("Cannot replace corrupt Quran audio index");
            if(!staging.renameTo(target))throw new IOException("Quran audio index install failed");
        }

        index=SQLiteDatabase.openDatabase(target.getAbsolutePath(),null,SQLiteDatabase.OPEN_READONLY);
        try(Cursor c=index.rawQuery("PRAGMA quick_check",null)){
            if(!c.moveToFirst()||!"ok".equals(c.getString(0)))throw new IOException("Quran audio index integrity check failed");
        }
        try(Cursor c=index.rawQuery("PRAGMA user_version",null)){
            if(!c.moveToFirst()||c.getInt(0)!=1)throw new IOException("Quran audio index schema mismatch");
        }
        try(Cursor c=index.rawQuery("SELECT count(*) FROM clip",null)){
            if(!c.moveToFirst()||c.getInt(0)!=wordCount)throw new IOException("Quran audio word count mismatch");
        }
    }

    private static String required(JSONObject object,String key) throws IOException {
        String value=object.optString(key,"").trim();
        if(value.isEmpty())throw new IOException("Missing Quran audio manifest field: "+key);
        return value;
    }

    Clip clip(ContentStore.Word word){
        if(index==null||word==null||word.position<1||word.id==null||!word.id.contains(":W:"))return null;
        try(Cursor c=index.rawQuery(
            "SELECT surah,byte_offset,byte_length FROM clip WHERE word_id=?",
            new String[]{word.id})){
            if(!c.moveToFirst())return null;
            long offset=c.getLong(1),length=c.getLong(2);
            int surah=c.getInt(0);
            return surah>=1&&surah<=114&&offset>=0&&length>0?new Clip(surah,offset,length):null;
        }
    }

    boolean canAddress(ContentStore.Word word){return clip(word)!=null;}

    AssetFileDescriptor open(Clip clip) throws IOException {
        if(clip==null)throw new FileNotFoundException("No Quran audio clip");
        String path=String.format(Locale.ROOT,"%s/%03d.pack",packRoot,clip.surah);
        return context.getAssets().openFd(path);
    }

    String attribution(){return sourceName+" · "+style+" · "+license+" · "+sourceVersion;}

    @Override public void close(){if(index!=null){index.close();index=null;}}
}
