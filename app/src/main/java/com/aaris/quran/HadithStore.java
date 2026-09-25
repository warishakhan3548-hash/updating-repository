package com.aaris.quran;

import android.content.Context;
import com.aaris.quran.core.Arabic;
import com.aaris.quran.core.TextMatch;
import com.aaris.quran.core.HadithQuery;
import com.aaris.quran.core.HadithSearchPlan;
import com.aaris.quran.core.MeaningSearch;
import android.os.CancellationSignal;
import java.util.concurrent.CancellationException;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import org.json.JSONObject;
import org.json.JSONArray;
import java.io.*;
import java.util.*;

/** Verified APK-bundled Hadith content. Source records are read-only; user data lives elsewhere. */
final class HadithStore implements AutoCloseable {
    static final class CollectionInfo {
        final String id,group,nameEn,nameAr,edition; final int count;
        CollectionInfo(Cursor c){id=c.getString(0);group=c.getString(1);nameEn=c.getString(2);
            nameAr=c.getString(3);edition=c.getString(4);count=c.getInt(5);}
    }
    static final class BookInfo {
        final String id,collectionId,number,nameEn,nameAr; final int count;
        BookInfo(Cursor c){id=c.getString(0);collectionId=c.getString(1);number=c.getString(2);
            nameEn=c.getString(3);nameAr=c.getString(4);count=c.getInt(5);}
    }
    static final class ChapterInfo {
        final String id,collectionId,bookId,number,nameEn,nameAr; final int count;
        ChapterInfo(Cursor c){id=c.getString(0);collectionId=c.getString(1);bookId=c.getString(2);
            number=c.getString(3);nameEn=c.getString(4);nameAr=c.getString(5);count=c.getInt(6);}
    }
    static final class Record {
        final String id,collectionId,bookId,chapterId,number,arabic,english,urdu,bangla,
            narrator,isnadAr,isnadEn,matnAr,matnEn,sourceRef;
        Record(Cursor c){id=c.getString(0);collectionId=c.getString(1);bookId=c.getString(2);
            chapterId=c.getString(3);number=c.getString(4);arabic=c.getString(5);
            english=c.getString(6);urdu=c.getString(7);bangla=c.getString(8);
            narrator=c.getString(9);isnadAr=c.getString(10);isnadEn=c.getString(11);
            matnAr=c.getString(12);matnEn=c.getString(13);sourceRef=c.getString(14);}
    }
    static final class DisplayTranslation {
        final String language,text,provenance;
        DisplayTranslation(String language,String text,String provenance){
            this.language=language;this.text=text;this.provenance=provenance;
        }
    }

    private static final String RECORD_COLUMNS =
        "h.id,h.collection_id,h.book_id,h.chapter_id,h.record_number,h.arabic,h.english,"+
        "h.urdu,h.bangla,h.narrator_en,h.isnad_ar,h.isnad_en,h.matn_ar,h.matn_en,h.source_ref";
    private SQLiteDatabase db;
    private boolean hasEditorialTranslations;
    private final Map<String,String> collectionAliases=new LinkedHashMap<>();
    private static final int SPELLING_CACHE_LIMIT=256;
    private final Map<String,List<String>> spellingCache=Collections.synchronizedMap(new LinkedHashMap<String,List<String>>(64,.75f,true){
        @Override protected boolean removeEldestEntry(Map.Entry<String,List<String>> eldest){return size()>SPELLING_CACHE_LIMIT;}
    });
    private final List<CollectionInfo> collectionCache;
    private final Set<String> layeredHadithIds;
    final String packHash,packId,contentVersion,sourceName,sourceVersion,redistributionBasis;
    final long packBytes;
    final int recordCount,collectionCount;
    final Set<String> languageCoverage;

    static HadithStore openIfBundled(Context context) throws Exception {
        boolean manifest=false,database=false;
        String[] root=context.getAssets().list("");
        if(root!=null)for(String name:root){
            if("hadith-manifest.json".equals(name))manifest=true;
            if("hadith.sqlite".equals(name))database=true;
        }
        if(!manifest&&!database)return null;
        if(manifest!=database)throw new IOException("Incomplete bundled Hadith pack");
        return new HadithStore(context);
    }

    private static String verificationValue(String hash,long bytes,long modified){
        return hash+"\n"+bytes+"\n"+modified+"\n";
    }
    private static boolean verificationMarkerMatches(File marker,File target,String hash,long bytes){
        if(!marker.isFile()||!target.isFile()||target.length()!=bytes)return false;
        try(InputStream in=new FileInputStream(marker);ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] buffer=new byte[256];int n,total=0;
            while((n=in.read(buffer))!=-1){
                total+=n;if(total>512)return false;out.write(buffer,0,n);
            }
            return verificationValue(hash,bytes,target.lastModified()).equals(out.toString("UTF-8"));
        }catch(IOException ignored){return false;}
    }
    private static void writeVerificationMarker(File marker,File target,String hash,long bytes)throws IOException{
        File temp=new File(marker.getParentFile(),marker.getName()+".tmp");
        if(temp.exists()&&!temp.delete())throw new IOException("Cannot clear Hadith verification staging file");
        byte[] value=verificationValue(hash,bytes,target.lastModified()).getBytes("UTF-8");
        try(FileOutputStream out=new FileOutputStream(temp)){out.write(value);out.getFD().sync();}
        if(marker.exists()&&!marker.delete()){temp.delete();throw new IOException("Cannot replace Hadith verification marker");}
        if(!temp.renameTo(marker)){temp.delete();throw new IOException("Cannot install Hadith verification marker");}
    }
    private static void cleanupOldPacks(File folder,File keepDatabase,File keepMarker){
        File[] files=folder.listFiles();if(files==null)return;
        for(File file:files){
            String name=file.getName();
            if(file.equals(keepDatabase)||file.equals(keepMarker))continue;
            if((name.startsWith("hadith-")&&(name.endsWith(".sqlite")||name.endsWith(".sqlite.verified")))||
               name.equals("hadith-install.tmp"))file.delete(); // Best-effort cleanup after current pack verified.
        }
    }

    private HadithStore(Context context) throws Exception {
        JSONObject manifest=new JSONObject(ContentStore.asset(context,"hadith-manifest.json"));
        if(manifest.getInt("schema_version")!=2)throw new IOException("Unsupported Hadith pack schema");
        packHash=manifest.getString("sqlite_sha256");
        packBytes=manifest.getLong("sqlite_bytes");
        packId=manifest.getString("pack_id");
        contentVersion=manifest.getString("content_version");
        sourceName=manifest.getString("source_name");
        sourceVersion=manifest.getString("source_version");
        redistributionBasis=manifest.optString("redistribution_basis","Source license recorded in pack manifest");
        LinkedHashSet<String> languages=new LinkedHashSet<>();
        JSONArray languageArray=manifest.optJSONArray("language_coverage");
        if(languageArray!=null)for(int i=0;i<languageArray.length();i++){
            String code=languageArray.optString(i,"").trim().toLowerCase(Locale.ROOT);
            if(!code.isEmpty())languages.add(code);
        }
        if(languages.isEmpty())languages.add("ar");
        languageCoverage=Collections.unmodifiableSet(languages);
        recordCount=manifest.getInt("records");
        collectionCount=manifest.getInt("collections");
        if(!packHash.matches("[a-f0-9]{64}")||packId.trim().isEmpty()||contentVersion.trim().isEmpty()||
            sourceName.trim().isEmpty()||sourceVersion.trim().isEmpty()||packBytes<1||recordCount<1||collectionCount<1)
            throw new IOException("Invalid Hadith manifest");

        File folder=new File(context.getFilesDir(),"evidence");
        if(!folder.exists()&&!folder.mkdirs())throw new IOException("Cannot create evidence storage");
        File target=new File(folder,"hadith-"+packHash.substring(0,16)+".sqlite");
        File marker=new File(folder,target.getName()+".verified");
        boolean trustedInstalledFile=verificationMarkerMatches(marker,target,packHash,packBytes);
        boolean fullVerification=!trustedInstalledFile;
        if(fullVerification){
            boolean existingValid=target.isFile()&&target.length()==packBytes&&packHash.equals(ContentStore.hash(target));
            if(!existingValid){
                File staging=new File(folder,"hadith-install.tmp");
                if(staging.exists()&&!staging.delete())throw new IOException("Cannot clear Hadith staging file");
                try(InputStream in=context.getAssets().open("hadith.sqlite");FileOutputStream out=new FileOutputStream(staging)){
                    byte[] bytes=new byte[65536];int n;
                    while((n=in.read(bytes))!=-1)out.write(bytes,0,n);
                    out.getFD().sync();
                }
                if(staging.length()!=packBytes||!packHash.equals(ContentStore.hash(staging))){
                    staging.delete();throw new IOException("Hadith checksum mismatch");
                }
                if(target.exists()&&!target.delete()){staging.delete();throw new IOException("Cannot replace corrupt Hadith pack");}
                if(!staging.renameTo(target))throw new IOException("Hadith pack install failed");
            }
        }
        SQLiteDatabase opened=SQLiteDatabase.openDatabase(target.getAbsolutePath(),null,SQLiteDatabase.OPEN_READONLY);
        try{
            if(fullVerification)try(Cursor c=opened.rawQuery("PRAGMA quick_check",null)){
                if(!c.moveToFirst()||!"ok".equals(c.getString(0)))throw new IOException("Hadith integrity check failed");
            }
            try(Cursor c=opened.rawQuery("PRAGMA user_version",null)){
                if(!c.moveToFirst()||c.getInt(0)!=2)throw new IOException("Hadith schema mismatch");
            }
            try(Cursor c=opened.rawQuery("SELECT count(*) FROM hadith",null)){
                if(!c.moveToFirst()||c.getInt(0)!=recordCount)throw new IOException("Hadith record count mismatch");
            }
            try(Cursor c=opened.rawQuery("SELECT count(*) FROM collection",null)){
                if(!c.moveToFirst()||c.getInt(0)!=collectionCount)throw new IOException("Hadith collection count mismatch");
            }
            if(fullVerification)writeVerificationMarker(marker,target,packHash,packBytes);
            db=opened;
            collectionCache=Collections.unmodifiableList(loadCollections());
            for(CollectionInfo info:collectionCache){collectionAliases.put(info.id,info.id);collectionAliases.put(info.nameEn,info.id);collectionAliases.put(info.nameAr,info.id);}
            LinkedHashSet<String> layered=new LinkedHashSet<>();
            try(Cursor c=opened.rawQuery(
                "SELECT hadith_id FROM editorial_translation WHERE status IN ('released','reviewed') "+
                "UNION SELECT hadith_id FROM search_context",null)){
                while(c.moveToNext())layered.add(c.getString(0));
            }
            layeredHadithIds=Collections.unmodifiableSet(layered);
            try(Cursor c=opened.rawQuery("SELECT 1 FROM editorial_translation WHERE status IN ('released','reviewed') LIMIT 1",null)){hasEditorialTranslations=c.moveToFirst();}
            cleanupOldPacks(folder,target,marker);
        }catch(Exception invalid){
            db=null;opened.close();throw invalid;
        }
    }

    private List<CollectionInfo> loadCollections(){
        List<CollectionInfo> out=new ArrayList<>();
        if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT c.id,c.group_name,c.name_en,c.name_ar,c.edition,count(h.id) "+
            "FROM collection c LEFT JOIN hadith h ON h.collection_id=c.id GROUP BY c.id "+
            "ORDER BY c.group_name,c.name_en",null)){while(c.moveToNext())out.add(new CollectionInfo(c));}
        return out;
    }

    List<CollectionInfo> collections(){return new ArrayList<>(collectionCache);}

    CollectionInfo collection(String id){
        if(id==null)return null;
        for(CollectionInfo info:collectionCache)if(id.equals(info.id))return info;
        return null;
    }

    List<BookInfo> books(String collectionId){
        List<BookInfo> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT b.id,b.collection_id,b.number,b.name_en,b.name_ar,count(h.id) "+
            "FROM book b LEFT JOIN hadith h ON h.book_id=b.id WHERE b.collection_id=? "+
            "GROUP BY b.id ORDER BY CAST(b.number AS INTEGER),b.number",new String[]{collectionId})){
            while(c.moveToNext())out.add(new BookInfo(c));
        }
        return out;
    }

    List<ChapterInfo> chapters(String collectionId,String bookId){
        List<ChapterInfo> out=new ArrayList<>();if(db==null)return out;
        String sql="SELECT ch.id,ch.collection_id,ch.book_id,ch.number,ch.name_en,ch.name_ar,count(h.id) "+
            "FROM chapter ch LEFT JOIN hadith h ON h.chapter_id=ch.id WHERE ch.collection_id=? AND "+
            (bookId==null?"ch.book_id IS NULL":"ch.book_id=?")+
            " GROUP BY ch.id ORDER BY CAST(ch.number AS INTEGER),ch.number";
        String[] args=bookId==null?new String[]{collectionId}:new String[]{collectionId,bookId};
        try(Cursor c=db.rawQuery(sql,args)){while(c.moveToNext())out.add(new ChapterInfo(c));}
        return out;
    }

    List<Record> records(String collectionId,String bookId,String chapterId,int limit,int offset){
        List<Record> out=new ArrayList<>();if(db==null)return out;
        List<String> args=new ArrayList<>();StringBuilder where=new StringBuilder("h.collection_id=?");args.add(collectionId);
        if(bookId!=null){where.append(" AND h.book_id=?");args.add(bookId);}
        if(chapterId!=null){where.append(" AND h.chapter_id=?");args.add(chapterId);}
        args.add(""+Math.max(1,Math.min(200,limit)));args.add(""+Math.max(0,offset));
        try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE "+where+
            " ORDER BY h.rowid LIMIT ? OFFSET ?",args.toArray(new String[0]))){
            while(c.moveToNext())out.add(new Record(c));
        }
        return out;
    }

    Record record(String id){
        if(db==null)return null;
        try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE h.id=?",
            new String[]{id})){return c.moveToFirst()?new Record(c):null;}
    }

    static final class Hit {
        final Record record;final TextMatch match;final boolean reference,meaning;
        Hit(Record record,TextMatch match,boolean reference,boolean meaning){
            this.record=record;this.match=match;this.reference=reference;this.meaning=meaning;
        }
    }
    private static final class MatchChoice {
        final TextMatch match;final boolean meaning;
        MatchChoice(TextMatch match,boolean meaning){this.match=match;this.meaning=meaning;}
    }
    static final class SearchPage {
        final List<Hit> hits;final int total,offset,nextOffset;final String query;final boolean limited;
        SearchPage(String query,List<Hit> hits,int total,int offset){this(query,hits,total,offset,false,offset+hits.size());}
        SearchPage(String query,List<Hit> hits,int total,int offset,boolean limited){this(query,hits,total,offset,limited,offset+hits.size());}
        SearchPage(String query,List<Hit> hits,int total,int offset,boolean limited,int nextOffset){
            this.query=query;this.hits=hits;this.total=total;this.offset=offset;this.limited=limited;
            this.nextOffset=Math.max(offset,nextOffset);
        }
    }
    private static final Comparator<Hit> ORDER=(a,b)->{
        int c=Boolean.compare(b.reference,a.reference);if(c!=0)return c;
        c=TextMatch.compareHadith(a.match,a.record.collectionId,b.match,b.record.collectionId);if(c!=0)return c;
        c=Boolean.compare(a.meaning,b.meaning);if(c!=0)return c; // direct text wins an otherwise equal tie
        c=a.record.collectionId.compareTo(b.record.collectionId);if(c!=0)return c;
        return a.record.id.compareTo(b.record.id);
    };
    List<Record> search(String query,int limit){List<Record> out=new ArrayList<>();for(Hit hit:searchPage(query,limit,0).hits)out.add(hit.record);return out;}
    private volatile SearchPage cachedText;
    SearchPage searchPage(String query,int limit,int offset){return searchPage(query,limit,offset,new CancellationSignal());}
    SearchPage searchPage(String query,int limit,int offset,CancellationSignal signal){
        cancelSearch(signal);
        String raw=query==null?"":query.trim();int start=Math.max(0,offset),cap=Math.max(1,Math.min(200,limit));
        if(raw.isEmpty()||raw.length()>16384||db==null)return new SearchPage(raw,Collections.emptyList(),0,start);
        HadithQuery intent=HadithQuery.parse(raw,collectionAliases);
        if(intent.isReference()||raw.startsWith("H:")||intent.isCollectionBrowse())
            return referencePage(intent,cap,start,signal);
        List<String> terms=TextMatch.tokens(intent.text);
        if(terms.isEmpty())return new SearchPage(raw,Collections.emptyList(),0,start);
        SearchPage cached=cachedText;
        if(cached!=null&&cached.query.equals(raw))return slice(cached,cap,start);

        // A phrase lookup can return the first page immediately, even for very common words.
        // Count and pagination remain in SQLite; Java never materializes the entire match set.
        HadithSearchPlan phrase=HadithSearchPlan.phrase(intent);int exact;
        try(Cursor c=db.rawQuery("SELECT count(*) FROM hadith h WHERE "+phrase.where,phrase.args.toArray(new String[0]),signal)){
            c.moveToFirst();exact=c.getInt(0);
        }
        if(exact>0){
            List<String> args=new ArrayList<>(phrase.args);args.add(""+cap);args.add(""+start);
            List<Hit> hits=new ArrayList<>();
            try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE "+phrase.where+HadithSearchPlan.ORDER+" LIMIT ? OFFSET ?",args.toArray(new String[0]),signal)){
                while(c.moveToNext()){
                    cancelSearch(signal);Record record=new Record(c);
                    MatchChoice choice=bestMatch(record,terms,Collections.emptyMap(),Collections.emptyMap(),signal);
                    if(choice.match.accepted)hits.add(new Hit(record,choice.match,false,choice.meaning));
                }
            }
            int consumed=Math.min(cap,Math.max(0,exact-start));
            return new SearchPage(raw,hits,exact,start,false,start+consumed);
        }
        List<String> anchorTerms=MeaningSearch.focusTokens(terms);
        Map<String,List<String>> repairs=new HashMap<>();Map<String,Double> weights=new HashMap<>();
        for(String term:new LinkedHashSet<>(terms)){
            cancelSearch(signal);int df=0;
            try(Cursor c=db.rawQuery("SELECT df FROM search_vocabulary WHERE token=?",new String[]{term},signal)){if(c.moveToFirst())df=c.getInt(0);}
            weights.put(term,Math.max(.25,Math.log(1.+recordCount/(1.+df))));
        }
        List<String> ranked=new ArrayList<>(new LinkedHashSet<>(anchorTerms));
        ranked.sort(Comparator.comparingDouble((String t)->weights.getOrDefault(t,1.)).reversed().thenComparing(t->t));
        for(String term:ranked.subList(0,Math.min(HadithSearchPlan.MAX_ANCHORS,ranked.size())))
            repairs.put(term,mergeAlternatives(MeaningSearch.alternatives(term),spellingCandidates(term,anchorTerms.size()>1,signal)));
        HadithSearchPlan plan=HadithSearchPlan.candidates(intent,anchorTerms,repairs,weights);
        List<Hit> matches=new ArrayList<>();int scanned=0;
        try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE "+plan.where,plan.args.toArray(new String[0]),signal)){
            while(c.moveToNext()){
                cancelSearch(signal);scanned++;Record record=new Record(c);
                MatchChoice choice=bestMatch(record,terms,repairs,weights,signal);
                if(choice.match.accepted)matches.add(new Hit(record,choice.match,false,choice.meaning));
            }
        }
        cancelSearch(signal);matches.sort(ORDER);
        SearchPage complete=new SearchPage(raw,Collections.unmodifiableList(matches),matches.size(),0,scanned>HadithSearchPlan.CANDIDATE_LIMIT);
        cachedText=complete;return slice(complete,cap,start);
    }
    private static SearchPage slice(SearchPage page,int cap,int offset){
        int from=Math.min(offset,page.hits.size()),to=Math.min(from+cap,page.hits.size());
        return new SearchPage(page.query,new ArrayList<>(page.hits.subList(from,to)),page.total,offset,page.limited,to);
    }
    private MatchChoice bestMatch(Record record,List<String> terms,Map<String,List<String>> repairs,Map<String,Double> weights,CancellationSignal signal){
        List<String> focusedTerms=MeaningSearch.focusTokens(terms);
        TextMatch direct=TextMatch.compare(terms,TextMatch.tokens(record.arabic),repairs,weights);
        boolean directMeaning=false;
        for(String text:new String[]{record.english,record.urdu,record.bangla})if(text!=null){
            cancelSearch(signal);List<String> tokens=TextMatch.tokens(text);
            TextMatch m=TextMatch.compare(terms,tokens,repairs,weights);
            if(m.accepted&&(!direct.accepted||TextMatch.compareRank(m,direct)<0)){
                direct=m;directMeaning=MeaningSearch.usesConceptBridge(terms,tokens);
            }
        }

        TextMatch context=null;
        if(layeredHadithIds.contains(record.id))try(Cursor docs=db.rawQuery(
            "SELECT 0,text,'',language FROM editorial_translation WHERE hadith_id=? AND status IN ('released','reviewed') "+
            "UNION ALL SELECT 1,text,roman,language FROM search_context WHERE hadith_id=?",
            new String[]{record.id,record.id},signal)){
            while(docs.moveToNext()){
                cancelSearch(signal);boolean meaning=docs.getInt(0)==1;
                List<String> docTokens=TextMatch.tokens(docs.getString(1));
                TextMatch m=TextMatch.compare(terms,docTokens,repairs,weights);
                if(!meaning){
                    if("hi".equals(docs.getString(3))){
                        String translationRoman=MeaningSearch.romanizeHindi(docs.getString(1));
                        if(!translationRoman.isEmpty()){
                            TextMatch romanTranslation=TextMatch.compare(terms,TextMatch.tokens(translationRoman),repairs,weights);
                            if(romanTranslation.accepted&&(!m.accepted||TextMatch.compareRank(romanTranslation,m)<0))m=romanTranslation;
                        }
                    }
                    if(m.accepted&&(!direct.accepted||TextMatch.compareRank(m,direct)<0)){
                        direct=m;
                        directMeaning=MeaningSearch.usesConceptBridge(terms,docTokens)||
                            (!"hi".equals(docs.getString(3))?false:
                                MeaningSearch.usesConceptBridge(terms,TextMatch.tokens(MeaningSearch.romanizeHindi(docs.getString(1)))));
                    }
                    continue;
                }
                if(!focusedTerms.equals(terms)){
                    TextMatch f=TextMatch.compare(focusedTerms,docTokens,repairs,weights);
                    if(f.accepted&&(!m.accepted||f.band.ordinal()<m.band.ordinal()))m=f;
                }
                String roman=docs.getString(2);
                if(roman!=null&&!roman.isEmpty()){
                    List<String> romanTokens=TextMatch.tokens(roman);
                    TextMatch r=TextMatch.compare(terms,romanTokens,repairs,weights);
                    if(!focusedTerms.equals(terms)){
                        TextMatch rf=TextMatch.compare(focusedTerms,romanTokens,repairs,weights);
                        if(rf.accepted&&(!r.accepted||rf.band.ordinal()<r.band.ordinal()))r=rf;
                    }
                    if(r.accepted&&(!m.accepted||TextMatch.compareRank(r,m)<0))m=r;
                }
                if(m.accepted&&(context==null||TextMatch.compareRank(m,context)<0))context=m;
            }
        }
        // Search context is supporting evidence, not a quote. It may replace a direct result only
        // when it reaches a strictly stronger confidence band.
        if(context!=null&&(!direct.accepted||context.band.ordinal()<direct.band.ordinal()))
            return new MatchChoice(context,true);
        return new MatchChoice(direct,directMeaning);
    }
    private SearchPage referencePage(HadithQuery query,int cap,int offset,CancellationSignal signal){
        cancelSearch(signal);HadithQuery.Lookup lookup=query.lookup();
        List<String> args=new ArrayList<>(lookup.args);String predicate=lookup.where;
        int total;try(Cursor c=db.rawQuery("SELECT count(*) FROM hadith h WHERE "+predicate,args.toArray(new String[0]),signal)){c.moveToFirst();total=c.getInt(0);}
        args.add(""+cap);args.add(""+offset);List<Hit> hits=new ArrayList<>();
        try(Cursor c=db.rawQuery("SELECT "+RECORD_COLUMNS+" FROM hadith h WHERE "+predicate+HadithSearchPlan.ORDER+" LIMIT ? OFFSET ?",args.toArray(new String[0]),signal)){
            while(c.moveToNext()){cancelSearch(signal);hits.add(new Hit(new Record(c),TextMatch.exactReference(),query.isReference()||query.raw.startsWith("H:"),false));}
        }
        return new SearchPage(query.raw,hits,total,offset);
    }
    private List<String> spellingCandidates(String term,boolean hasContext,CancellationSignal signal){
        cancelSearch(signal);
        boolean arabicTerm=Arabic.hasArabic(term);
        if(term.length()<(arabicTerm&&hasContext?3:4)||term.length()>128||TextMatch.negative(term))return Collections.emptyList();
        List<String> cached=spellingCache.get(term);if(cached!=null)return cached;
        int max=term.length()>=8?2:1,maxFormExtra=arabicTerm?3:4;
        Map<String,Integer> distances=new HashMap<>(),overlap=new HashMap<>();Set<String> forms=new HashSet<>();
        List<String> grams=new ArrayList<>(Arabic.trigrams(term));
        if(!grams.isEmpty()){
            String marks=String.join(",",Collections.nCopies(grams.size(),"?"));
            try(Cursor c=db.rawQuery("SELECT token,count(*) AS hits FROM search_gram WHERE gram IN ("+marks+") GROUP BY token ORDER BY hits DESC,token LIMIT 120",grams.toArray(new String[0]),signal)){
                while(c.moveToNext()){
                    cancelSearch(signal);String word=c.getString(0);if(word.equals(term))continue;
                    boolean form=word.length()>=term.length()&&word.length()-term.length()<=maxFormExtra&&word.contains(term);
                    int distance=form?1:TextMatch.distance(term,word,max);
                    if(form||distance<=max){
                        distances.put(word,distance);overlap.put(word,c.getInt(1));if(form)forms.add(word);
                    }
                }
            }
        }
        if(distances.size()<5){
            List<String> seeds=spellingSeeds(term);
            if(!seeds.isEmpty()){
                String marks=String.join(",",Collections.nCopies(seeds.size(),"?"));
                try(Cursor c=db.rawQuery("SELECT token FROM search_vocabulary WHERE token IN ("+marks+") ORDER BY token",seeds.toArray(new String[0]),signal)){
                    while(c.moveToNext()){cancelSearch(signal);String word=c.getString(0);int distance=TextMatch.distance(term,word,max);if(distance<=max){distances.put(word,distance);overlap.putIfAbsent(word,0);}}
                }
            }
        }
        List<String> out=new ArrayList<>(distances.keySet());
        out.sort(Comparator.comparingInt((String w)->forms.contains(w)?0:1)
            .thenComparingInt(w->distances.get(w))
            .thenComparing(Comparator.comparingInt((String w)->overlap.getOrDefault(w,0)).reversed()).thenComparing(w->w));
        List<String> result=Collections.unmodifiableList(new ArrayList<>(out.subList(0,Math.min(8,out.size()))));spellingCache.put(term,result);return result;
    }
    private static List<String> mergeAlternatives(List<String> first,List<String> second){
        LinkedHashSet<String> merged=new LinkedHashSet<>();
        if(first!=null)merged.addAll(first);if(second!=null)merged.addAll(second);
        List<String> out=new ArrayList<>(merged);
        return out.size()<=12?out:new ArrayList<>(out.subList(0,12));
    }

    static List<String> spellingSeeds(String term){
        int[] codePoints=term.codePoints().toArray();
        if(codePoints.length<2||codePoints.length>12)return Collections.emptyList();
        LinkedHashSet<String> seeds=new LinkedHashSet<>();
        for(int i=0;i+1<codePoints.length;i++)if(codePoints[i]!=codePoints[i+1]){
            int swap=codePoints[i];codePoints[i]=codePoints[i+1];codePoints[i+1]=swap;
            seeds.add(new String(codePoints,0,codePoints.length));
            codePoints[i+1]=codePoints[i];codePoints[i]=swap;
        }
        if(codePoints.length>2)for(int skip=0;skip<codePoints.length;skip++){
            int[] shortened=new int[codePoints.length-1];int at=0;
            for(int i=0;i<codePoints.length;i++)if(i!=skip)shortened[at++]=codePoints[i];
            seeds.add(new String(shortened,0,shortened.length));
        }
        return new ArrayList<>(seeds);
    }
    private static void cancelSearch(CancellationSignal signal){if(Thread.currentThread().isInterrupted())throw new CancellationException();signal.throwIfCanceled();}

    List<String> grades(String id){
        List<String> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT grade,grader,source_version FROM grade_assertion "+
            "WHERE hadith_id=? ORDER BY id",new String[]{id})){
            while(c.moveToNext())out.add(c.getString(0)+" · "+c.getString(1)+" · "+c.getString(2));
        }
        return out;
    }

    List<String> references(String id){
        List<String> out=new ArrayList<>();if(db==null)return out;
        try(Cursor c=db.rawQuery("SELECT scheme,value FROM hadith_reference WHERE hadith_id=? ORDER BY id",
            new String[]{id})){while(c.moveToNext())out.add(c.getString(0)+": "+c.getString(1));}
        return out;
    }

    boolean hasLanguage(String code){
        return code!=null&&languageCoverage.contains(code.toLowerCase(Locale.ROOT));
    }

    String searchHint(){
        return "Arabic, Hindi, Hinglish, Urdu or English · remembered meaning also works";
    }

    DisplayTranslation translation(Record record,String preferredLanguage){
        if(record==null||db==null)return null;
        String preferred=preferredLanguage==null?"en":preferredLanguage.toLowerCase(Locale.ROOT);
        LinkedHashSet<String> candidates=new LinkedHashSet<>();
        if("hi".equals(preferred)){candidates.add("hi");candidates.add("en");}
        else if("ur".equals(preferred)){candidates.add("ur");candidates.add("en");}
        else if("bn".equals(preferred)){candidates.add("bn");candidates.add("en");}
        else{candidates.add(preferred);candidates.add("en");}

        for(String language:candidates){
            if(hasEditorialTranslations)try(Cursor cursor=db.rawQuery(
                "SELECT text,revision,status,source_ref FROM editorial_translation "+
                "WHERE hadith_id=? AND language=? AND status IN ('released','reviewed') "+
                "ORDER BY CASE status WHEN 'released' THEN 0 ELSE 1 END,rowid DESC LIMIT 1",
                new String[]{record.id,language})){
                if(cursor.moveToFirst()){
                    String revision=cursor.getString(1),status=cursor.getString(2),source=cursor.getString(3);
                    String provenance=(source==null||source.trim().isEmpty())
                        ?"Reviewed source translation · "+revision+" · "+status
                        :source+" · "+status;
                    return new DisplayTranslation(language,cursor.getString(0),provenance);
                }
            }
            String sourceText=null;
            if("en".equals(language))sourceText=record.english;
            else if("ur".equals(language))sourceText=record.urdu;
            else if("bn".equals(language))sourceText=record.bangla;
            if(sourceText!=null&&!sourceText.trim().isEmpty())
                return new DisplayTranslation(language,sourceText,"Imported source translation · "+sourceName);
        }
        return null;
    }

    @Override public void close(){cachedText=null;if(db!=null){db.close();db=null;}}
}
