package com.aaris.quran.core;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

final class ExportChecks {
    private static int checks;
    private static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    static int run(){
        Path folder=null;
        try{
            folder=Files.createTempDirectory("aaris-export-check-");ExportStaging first=new ExportStaging(folder.toFile());
            byte[] original="Private backup \u0000 हिंदी العربية".getBytes(StandardCharsets.UTF_8);String token=first.stage(original);
            ExportStaging recreated=new ExportStaging(folder.toFile());ByteArrayOutputStream out=new ByteArrayOutputStream();recreated.copyTo(token,out);
            check(Arrays.equals(original,out.toByteArray()),"File picker handoff survives loss of the Activity/store instance");
            boolean failed=false;try{recreated.copyTo(token,new OutputStream(){public void write(int value)throws IOException{throw new IOException("Provider failed");}});}catch(IOException expected){failed=true;}
            out.reset();recreated.copyTo(token,out);check(failed&&Arrays.equals(original,out.toByteArray()),"Failed destination write leaves the staged source retryable");
            boolean rejected=false;try{recreated.copyTo("../learning.sqlite",out);}catch(IOException expected){rejected=true;}
            check(rejected,"Export tokens cannot address learning or source files");
            Files.write(folder.resolve(token+".bin"),"corrupted".getBytes(StandardCharsets.UTF_8));out.reset();rejected=false;
            try{recreated.copyTo(token,out);}catch(IOException expected){rejected=true;}
            check(rejected&&out.size()==0,"Corrupt staged payload is rejected before writing destination bytes");
            recreated.discard(token);check(!Files.exists(folder.resolve(token+".bin")),"Completed/cancelled export removes only its own payload");
            check(!ExportStaging.validToken(null)&&!ExportStaging.validToken(token+"/suffix"),"Malformed restored export tokens fail closed");
        }catch(IOException e){throw new AssertionError(e);}
        finally{if(folder!=null)try(java.util.stream.Stream<Path> files=Files.walk(folder)){files.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(IOException e){throw new UncheckedIOException(e);}});}catch(IOException e){throw new AssertionError(e);}}
        return checks;
    }
}
