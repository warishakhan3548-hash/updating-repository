package android.database;
import java.sql.*;
import android.os.CancellationSignal;
import android.database.sqlite.SQLiteDatabase;
public final class Cursor implements AutoCloseable {
    private final PreparedStatement statement;private final ResultSet result;
    private final CancellationSignal signal;private final boolean narration;
    public Cursor(PreparedStatement statement,ResultSet result,CancellationSignal signal,boolean narration){
        this.statement=statement;this.result=result;this.signal=signal;this.narration=narration;
    }
    public boolean moveToFirst(){return moveToNext();}
    public boolean moveToNext(){try{
        if(signal!=null)signal.throwIfCanceled();boolean more=result.next();
        if(more&&narration)SQLiteDatabase.fullRecordsRead.incrementAndGet();return more;
    }catch(SQLException e){throw new IllegalStateException(e);}}
    public String getString(int column){try{return result.getString(column+1);}catch(SQLException e){throw new IllegalStateException(e);}}
    public int getInt(int column){try{return result.getInt(column+1);}catch(SQLException e){throw new IllegalStateException(e);}}
    public void close(){try{result.close();statement.close();}catch(SQLException e){throw new IllegalStateException(e);}finally{if(signal!=null)signal.setOnCancelListener(null);}}
}
