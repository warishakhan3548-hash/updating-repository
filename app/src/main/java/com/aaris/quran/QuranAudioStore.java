package com.aaris.quran;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import org.json.JSONObject;
import java.io.*;
import java.util.Locale;

/**
 * Immutable APK-bundled word-audio pack.
 *
 * The pack is optional, but when present it is local-only: the runtime never constructs a URL,
 * opens a socket, or falls back to a website. Canonical Quran Word IDs remain the identity;
 * audio is only a presentation layer keyed by that identity.
 */
final class QuranAudioStore {
    private static final String MANIFEST = "quran-audio/manifest.json";

    private final Context context;
    final String packId,sourceName,sourceVersion,license,style,extension,assetRoot;
    final int wordCount;
    final boolean complete;

    static QuranAudioStore openIfBundled(Context context) throws Exception {
        String raw;
        try {
            raw=ContentStore.asset(context,MANIFEST);
        } catch(FileNotFoundException missing) {
            return null;
        }
        return new QuranAudioStore(context,new JSONObject(raw));
    }

    private QuranAudioStore(Context context,JSONObject manifest) throws Exception {
        this.context=context.getApplicationContext();
        if(manifest.getInt("schema_version")!=1)throw new IOException("Unsupported Quran audio pack schema");
        if(manifest.optBoolean("runtime_network_required",true))
            throw new IOException("Quran audio pack may not require runtime network access");
        packId=required(manifest,"pack_id");
        sourceName=required(manifest,"source_name");
        sourceVersion=required(manifest,"source_version");
        license=required(manifest,"license");
        style=required(manifest,"style");
        extension=required(manifest,"file_extension").toLowerCase(Locale.ROOT);
        assetRoot=required(manifest,"asset_root");
        wordCount=manifest.getInt("word_count");
        complete=manifest.optBoolean("coverage_complete",false);
        if(wordCount<1)throw new IOException("Invalid Quran audio word count");
        if(!assetRoot.startsWith("quran-audio/")||assetRoot.contains(".."))
            throw new IOException("Unsafe Quran audio asset root");
        if(!extension.matches("[a-z0-9]{2,6}"))
            throw new IOException("Unsafe Quran audio extension");
    }

    private static String required(JSONObject object,String key) throws IOException {
        String value=object.optString(key,"").trim();
        if(value.isEmpty())throw new IOException("Missing Quran audio manifest field: "+key);
        return value;
    }

    String assetPath(ContentStore.Word word) {
        if(word==null||word.position<1||word.id==null||!word.id.contains(":W:"))return null;
        String[] coordinate=word.ayahId.split(":");
        if(coordinate.length!=3||!"Q".equals(coordinate[0]))return null;
        try {
            int surah=Integer.parseInt(coordinate[1]),ayah=Integer.parseInt(coordinate[2]);
            if(surah<1||surah>114||ayah<1||word.position<1)return null;
            return String.format(Locale.ROOT,"%s/%03d/%03d_%03d_%03d.%s",
                assetRoot,surah,surah,ayah,word.position,extension);
        } catch(NumberFormatException invalid) {
            return null;
        }
    }

    boolean canAddress(ContentStore.Word word){return assetPath(word)!=null;}

    AssetFileDescriptor open(ContentStore.Word word) throws IOException {
        String path=assetPath(word);
        if(path==null)throw new FileNotFoundException("No canonical audio coordinate for word");
        return context.getAssets().openFd(path);
    }

    String attribution(){
        return sourceName+" · "+style+" · "+license+" · "+sourceVersion;
    }
}
