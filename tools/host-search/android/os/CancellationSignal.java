package android.os;
/** Host adapter only. Android supplies the real implementation in the app. */
public final class CancellationSignal {
    private volatile boolean canceled;
    private Runnable listener;
    public boolean isCanceled(){return canceled;}
    public void throwIfCanceled(){if(canceled)throw new OperationCanceledException();}
    public void cancel(){Runnable notify;synchronized(this){canceled=true;notify=listener;}if(notify!=null)notify.run();}
    public void setOnCancelListener(Runnable value){boolean call;synchronized(this){listener=value;call=canceled;}if(call&&value!=null)value.run();}
}
