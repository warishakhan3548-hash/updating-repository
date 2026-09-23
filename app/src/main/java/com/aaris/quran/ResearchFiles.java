package com.aaris.quran;

import android.content.*;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.*;
import java.util.UUID;

/** Read-only, URI-granted PDF sharing. No access to learning databases or arbitrary files. */
public final class ResearchFiles extends ContentProvider {
    static Uri write(Context context,byte[] bytes)throws IOException{
        File folder=new File(context.getCacheDir(),"research-pdf");if(!folder.isDirectory()&&!folder.mkdirs())throw new IOException("Cannot create export folder");
        File[] existing=folder.listFiles();if(existing!=null)for(File file:existing)if(file.lastModified()<System.currentTimeMillis()-7L*86400000)file.delete();
        String name=UUID.randomUUID()+".pdf";File target=new File(folder,name),temp=new File(folder,name+".tmp");
        try(FileOutputStream out=new FileOutputStream(temp)){out.write(bytes);out.getFD().sync();}
        if(!temp.renameTo(target))throw new IOException("Could not finish PDF");
        return new Uri.Builder().scheme("content").authority(context.getPackageName()+".research").appendPath(name).build();
    }
    private File file(Uri uri)throws FileNotFoundException{
        if(!"content".equals(uri.getScheme())||!(getContext().getPackageName()+".research").equals(uri.getAuthority())||uri.getPathSegments().size()!=1)throw new FileNotFoundException();
        String name=uri.getLastPathSegment();if(name==null||!name.matches("[a-f0-9-]{36}\\.pdf"))throw new FileNotFoundException();
        File file=new File(new File(getContext().getCacheDir(),"research-pdf"),name);if(!file.isFile())throw new FileNotFoundException();return file;
    }
    @Override public boolean onCreate(){return true;}
    @Override public String getType(Uri uri){return "application/pdf";}
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort){
        try{File file=file(uri);String[] columns=projection==null?new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;
            MatrixCursor result=new MatrixCursor(columns);Object[] values=new Object[columns.length];for(int i=0;i<columns.length;i++){if(OpenableColumns.DISPLAY_NAME.equals(columns[i]))values[i]="Aaris-research.pdf";else if(OpenableColumns.SIZE.equals(columns[i]))values[i]=file.length();}result.addRow(values);return result;
        }catch(FileNotFoundException e){return null;}
    }
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{if(!"r".equals(mode))throw new FileNotFoundException("Read only");return ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.MODE_READ_ONLY);}
    @Override public Uri insert(Uri u,ContentValues v){throw new UnsupportedOperationException();}
    @Override public int update(Uri u,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}
    @Override public int delete(Uri u,String s,String[] a){throw new UnsupportedOperationException();}
}
