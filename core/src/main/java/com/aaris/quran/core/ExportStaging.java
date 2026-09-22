package com.aaris.quran.core;

import java.io.*;
import java.security.MessageDigest;
import java.util.*;

/** Durable private handoff to a document picker. Only an opaque token enters saved UI state. */
public final class ExportStaging {
    public static final int MAX_BYTES=64*1024*1024;
    private final File folder;
    public ExportStaging(File folder){this.folder=Objects.requireNonNull(folder);}
    public synchronized String stage(byte[] bytes)throws IOException {
        if(bytes==null||bytes.length==0||bytes.length>MAX_BYTES)throw new IOException("Export size is unsupported");
        if(!folder.isDirectory()&&!folder.mkdirs())throw new IOException("Cannot prepare private export");
        String token=UUID.randomUUID()+"-"+digest(new ByteArrayInputStream(bytes));
        File temporary=new File(folder,token+".tmp"),destination=file(token);
        try {
            try(FileOutputStream out=new FileOutputStream(temporary)){out.write(bytes);out.getFD().sync();}
            if(!temporary.renameTo(destination))throw new IOException("Cannot finish private export");
        }finally{if(temporary.exists())temporary.delete();}
        // Expired abandoned handoffs only; learning and evidence databases are elsewhere.
        File[] old=folder.listFiles();if(old!=null)for(File f:old)if(f.isFile()&&f.lastModified()<System.currentTimeMillis()-7*Recall.DAY&&
            f.getName().matches("[0-9a-f-]{101}\\.(bin|tmp)"))f.delete();
        return token;
    }
    public synchronized void copyTo(String token,OutputStream destination)throws IOException {
        File source=file(token);
        if(!source.isFile()||source.length()==0||source.length()>MAX_BYTES)throw new IOException("Export expired; prepare it again");
        try(InputStream in=new FileInputStream(source)){
            if(!digest(in).equals(token.substring(37)))throw new IOException("Staged export checksum mismatch");
        }
        try(InputStream in=new FileInputStream(source)){
            byte[] buffer=new byte[32768];int read;while((read=in.read(buffer))!=-1)destination.write(buffer,0,read);
        }
    }
    public synchronized void discard(String token)throws IOException {File f=file(token);if(f.exists()&&!f.delete())throw new IOException("Cannot remove completed handoff");}
    public static boolean validToken(String token){return token!=null&&token.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-9a-f]{64}");}
    private File file(String token)throws IOException {if(!validToken(token))throw new IOException("Invalid export token");return new File(folder,token+".bin");}
    private static String digest(InputStream input)throws IOException {
        try {
            MessageDigest digest=MessageDigest.getInstance("SHA-256");byte[] b=new byte[32768];int n;
            while((n=input.read(b))!=-1)digest.update(b,0,n);
            StringBuilder out=new StringBuilder();for(byte value:digest.digest())out.append(String.format(Locale.ROOT,"%02x",value&255));return out.toString();
        }catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
}
