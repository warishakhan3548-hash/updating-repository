package com.aaris.quran;
import android.content.Context;
import android.database.sqlite.SQLiteDatabase;
import android.os.*;
import com.aaris.quran.core.*;
import java.io.File;
import java.util.*;
import java.util.concurrent.*;

/** Actual app search/store code + actual corpus/SQLite; host timing is not a phone benchmark. */
public final class HadithRuntimeChecks {
    static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        Context context=new Context(new File(args[0]),new File(args[1]));
        try(HadithStore store=HadithStore.openIfBundled(context)){
            check(store!=null&&store.recordCount==62169,"Full source pack must open");
            String[] references={"sahih bhukhari 556","bukahri556","सही भुखारी ५५६","सहीह बुखारि ५५६","صحيح البخري ٥٥٦","صحیح بخری ۵۵۶"};
            for(String query:references){
                HadithStore.SearchPage page=store.searchPage(query,50,0);
                check(page.total==1&&page.hits.get(0).record.collectionId.equals("bukhari")&&page.hits.get(0).record.number.equals("556"),"Typo reference: "+query);
            }
            check(store.searchPage("muslem 5556",50,0).total==0,"Missing reference must stay missing");
            check(store.searchPage("sahih 556",50,0).total==2,"Ambiguous Sahih number should search both books");
            check(store.searchPage("sahih",50,0).total==12370,"Sahih title browsing");
            String marked="حَدَّثَنَا قُتَيْبَةُ بْنُ سَعِيدٍ حَدَّثَنَا",plain="حدثنا قتيبة بن سعيد حدثنا";
            List<String> previous=null;
            for(String query:new String[]{marked,plain}){
                SQLiteDatabase.fullRecordsRead.set(0);long start=System.nanoTime();
                HadithStore.SearchPage page=store.searchPage(query,50,0);
                int reads=SQLiteDatabase.fullRecordsRead.get();
                check(page.total==643&&page.hits.size()==50,"Screenshot phrase must complete with a page");
                check(reads==50,"Phrase search materialized "+reads+" full records");
                List<String> ids=new ArrayList<>();for(HadithStore.Hit hit:page.hits){
                    ids.add(hit.record.id);check(TextMatch.normalize(hit.record.arabic).contains(plain),"Phrase result not exact");
                }
                if(previous!=null)check(previous.equals(ids),"Harakat changed results");previous=ids;
                System.out.printf(Locale.ROOT,"Screenshot phrase: %d matches, %d full records read, %.3fs host%n",page.total,reads,(System.nanoTime()-start)/1e9);
            }
            HadithStore.SearchPage next=store.searchPage(plain,50,50);
            for(HadithStore.Hit hit:next.hits)check(!previous.contains(hit.record.id),"Pagination repeated a record");
            HadithStore.SearchPage scoped=store.searchPage("Tirmidhi "+plain,50,0);
            check(scoped.hits.stream().anyMatch(h->h.record.number.equals("1")),"Tirmidhi 1 lost");
            SQLiteDatabase.fullRecordsRead.set(0);
            HadithStore.SearchPage common=store.searchPage("حدثنا",50,0);
            check(common.total==57358&&SQLiteDatabase.fullRecordsRead.get()==50,"Common word became a full scan");
            SQLiteDatabase.fullRecordsRead.set(0);long start=System.nanoTime();
            HadithStore.SearchPage fuzzy=store.searchPage("Tirmidhi حدثنا قتيبه بن سعيد حدثنا",50,0);
            int scanned=SQLiteDatabase.fullRecordsRead.get();
            check(scanned<=HadithSearchPlan.CANDIDATE_LIMIT+1,"Fuzzy full-record budget exceeded");
            check(fuzzy.hits.stream().anyMatch(h->h.record.number.equals("1")),"Actual spelling repair failed to find Tirmidhi 1");
            System.out.printf(Locale.ROOT,"Arabic typo: %d matches, %d full records read, %.3fs host%n",fuzzy.total,scanned,(System.nanoTime()-start)/1e9);
            SQLiteDatabase.fullRecordsRead.set(0);store.searchPage("Tirmidhi حدثنا قتيبه بن سعيد حدثنا",50,50);
            check(SQLiteDatabase.fullRecordsRead.get()==0,"Paging reran fuzzy scoring");
            check(store.searchPage("zzzzunfindable999xyz",50,0).total==0,"Nonsense must not produce a false result");
            CancellationSignal canceled=new CancellationSignal();canceled.cancel();
            try{store.searchPage(marked,50,0,canceled);throw new AssertionError("Canceled request continued");}catch(OperationCanceledException expected){}
            ExecutorService worker=Executors.newSingleThreadExecutor();
            try{
                Future<?> old=worker.submit(()->{Thread.currentThread().interrupt();try{store.searchPage(plain,50,0);throw new AssertionError("Interrupted request continued");}catch(CancellationException expected){}});old.get(5,TimeUnit.SECONDS);
                check(worker.submit(()->store.searchPage("bhukhari556",50,0).total).get(5,TimeUnit.SECONDS)==1,"Canceled search blocked next request");
            }finally{worker.shutdownNow();}
            check(SQLiteDatabase.cancellableQueries.get()>0,"Runtime searches did not pass SQLite cancellation signals");
            System.out.println("Production HadithStore: screenshot phrase, spelling repairs, four-script references, pagination, cancellation/recovery: PASS");
        }
    }
}
