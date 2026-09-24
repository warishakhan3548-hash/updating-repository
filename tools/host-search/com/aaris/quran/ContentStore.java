package com.aaris.quran;
import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
/** Asset access only; the production HadithStore constructor/installer is exercised unchanged. */
final class ContentStore {
    static String asset(Context context,String name)throws IOException{
        try(InputStream in=context.getAssets().open(name)){return new String(in.readAllBytes(),StandardCharsets.UTF_8);}
    }
    static String hash(File file)throws Exception{
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        try(InputStream in=new FileInputStream(file)){byte[] chunk=new byte[65536];int n;while((n=in.read(chunk))!=-1)digest.update(chunk,0,n);}
        return java.util.HexFormat.of().formatHex(digest.digest());
    }
}
