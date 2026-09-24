package android.database.sqlite;
import android.database.Cursor;
import android.os.CancellationSignal;
import java.sql.*;
import java.util.concurrent.atomic.AtomicInteger;
/** Runs unchanged HadithStore SQL on real host SQLite. This is not an Android emulator. */
public final class SQLiteDatabase implements AutoCloseable {
    public static final int OPEN_READONLY=1;
    public static final AtomicInteger fullRecordsRead=new AtomicInteger(),cancellableQueries=new AtomicInteger();
    private final Connection connection;
    private SQLiteDatabase(String path)throws SQLException{
        connection=DriverManager.getConnection("jdbc:sqlite:file:"+path+"?mode=ro");
    }
    public static SQLiteDatabase openDatabase(String path,Object factory,int flags){
        try{return new SQLiteDatabase(path);}catch(SQLException e){throw new IllegalStateException(e);}
    }
    public Cursor rawQuery(String sql,String[] args){return rawQuery(sql,args,null);}
    public Cursor rawQuery(String sql,String[] args,CancellationSignal signal){
        try {
            if(signal!=null){signal.throwIfCanceled();cancellableQueries.incrementAndGet();}
            PreparedStatement statement=connection.prepareStatement(sql);
            if(args!=null)for(int i=0;i<args.length;i++)statement.setString(i+1,args[i]);
            if(signal!=null)signal.setOnCancelListener(()->{try{statement.cancel();}catch(SQLException ignored){}});
            try{
                if(signal!=null)signal.throwIfCanceled();
                return new Cursor(statement,statement.executeQuery(),signal,sql.contains("h.arabic,h.english"));
            }catch(Exception e){statement.close();if(signal!=null)signal.setOnCancelListener(null);throw e;}
        }catch(SQLException e){if(signal!=null)signal.throwIfCanceled();throw new IllegalStateException(e);}
    }
    public void close(){try{connection.close();}catch(SQLException e){throw new IllegalStateException(e);}}
}
