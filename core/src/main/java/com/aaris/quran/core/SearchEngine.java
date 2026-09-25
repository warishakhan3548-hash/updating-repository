package com.aaris.quran.core;

import java.util.*;
import java.util.regex.*;

/** Rebuildable deterministic indexes. Matching text is not a religious conclusion. */
public final class SearchEngine {
    public static final String VERSION = "ranked-11-long-text";
    public enum Strength { STRONG_TEXT, RELATED }
    public enum Origin { USER, AI }
    public static final class Query {
        public final String text;
        public final Origin origin;
        public Query(String text, Origin origin) {
            this.text=Objects.requireNonNull(text); this.origin=Objects.requireNonNull(origin);
        }
    }
    /** Non-destructive query lattice. Original wording is never replaced by a repair. */
    public static final class Variant {
        public final String original, safe, tolerant;
        public final Origin origin;
        public final double normalizationCost;
        Variant(Query q) {
            original=q.text.trim(); origin=q.origin;
            safe=Arabic.safe(original); tolerant=Arabic.tolerant(original);
            normalizationCost=safe.equals(tolerant)?0:0.2;
        }
    }
    public static final class Document {
        public final Ayah ayah;
        public final String hints,transliteration;
        public Document(Ayah ayah,String hints) { this(ayah,hints,hints); }
        public Document(Ayah ayah,String hints,String transliteration) { this.ayah=Objects.requireNonNull(ayah); this.hints=hints==null?"":hints;this.transliteration=transliteration==null?"":transliteration; }
    }
    public static final class Result {
        public final Ayah ayah;
        public final Strength strength;
        public final List<String> reasons;
        public final double score;
        public final List<Integer> matchedVariants;
        public final double transformationCost;
        public final TextMatch match;
        public final boolean reference,meaning;
        Result(Ayah ayah,Strength strength,List<String> reasons,double score,List<Integer> variants,double cost) {
            this(ayah,strength,reasons,score,variants,cost,TextMatch.exactReference(),true,false);
        }
        Result(Ayah ayah,Strength strength,List<String> reasons,double score,List<Integer> variants,double cost,TextMatch match) {
            this(ayah,strength,reasons,score,variants,cost,match,false,false);
        }
        private Result(Ayah ayah,Strength strength,List<String> reasons,double score,List<Integer> variants,double cost,TextMatch match,boolean reference,boolean meaning) {
            this.match=match;this.reference=reference;this.meaning=meaning;
            this.ayah=ayah;this.strength=strength;this.reasons=Collections.unmodifiableList(new ArrayList<>(reasons));
            this.score=score;this.matchedVariants=Collections.unmodifiableList(new ArrayList<>(variants));transformationCost=cost;
        }
    }
    public static final class Response {
        public final List<Result> results;
        public final List<Variant> variants;
        public final Map<String,Integer> trace;
        public final String query,intent,gate;
        public final int candidates;
        public final long elapsedNanos;
        public final FragmentSearch.Report fragments;
        Response(String query,String intent,List<Result> results,List<Variant> variants,Map<String,Integer> trace,long started) {
            this(query,intent,results,variants,trace,started,null);
        }
        Response(String query,String intent,List<Result> results,List<Variant> variants,Map<String,Integer> trace,long started,FragmentSearch.Report fragments) {
            this.query=query;this.intent=intent;this.results=Collections.unmodifiableList(new ArrayList<>(results));
            this.variants=Collections.unmodifiableList(new ArrayList<>(variants));
            this.trace=Collections.unmodifiableMap(new LinkedHashMap<>(trace));
            candidates=trace.getOrDefault("candidates",0);elapsedNanos=System.nanoTime()-started;
            this.fragments=fragments;
            gate=fragments!=null&&(results.isEmpty()||results.get(0).match.coverage<1)?"FRAGMENTS_ONLY":results.isEmpty()?(fragments==null?"NO_RELIABLE_MATCH":"FRAGMENTS_ONLY"):results.get(0).strength==Strength.STRONG_TEXT?"STRONG_TEXT":"RELATED";
        }
    }
    private static final class Posting {
        final int doc,tf;
        Posting(int doc,int tf){this.doc=doc;this.tf=tf;}
    }
    private static final class Index {
        final Map<String,List<Posting>> terms=new HashMap<>();
        final List<List<String>> tokens=new ArrayList<>();
        double averageLength;
        void add(String value,int doc) {
            List<String> words=Arabic.tokens(value);tokens.add(words);averageLength+=words.size();
            Map<String,Integer> counts=new HashMap<>();for(String w:words)counts.merge(w,1,Integer::sum);
            for(Map.Entry<String,Integer> e:counts.entrySet())terms.computeIfAbsent(e.getKey(),k->new ArrayList<>()).add(new Posting(doc,e.getValue()));
        }
        void finish(){averageLength=Math.max(1,averageLength/Math.max(1,tokens.size()));}
        Map<Integer,Double> rank(List<String> query) {
            Map<Integer,Double> scores=new HashMap<>();
            for(String term:new LinkedHashSet<>(query)) {
                cancelled();List<Posting> found=terms.get(term);if(found==null)continue;
                double idf=Math.log(1+(tokens.size()-found.size()+0.5)/(found.size()+0.5));
                for(Posting p:found)scores.merge(p.doc,idf*(p.tf*2.2)/(p.tf+1.2*(.25+.75*tokens.get(p.doc).size()/averageLength)),Double::sum);
            }
            return scores;
        }
    }
    private final List<Document> docs;
    private final List<String> safe=new ArrayList<>();
    private final Map<String,Integer> coordinates=new HashMap<>();
    private final Index arabic=new Index(),gloss=new Index(),sound=new Index();
    private final Map<String,List<String>> glossVocabulary=new HashMap<>(),soundVocabulary=new HashMap<>();
    private final Map<String,List<String>> trigramVocabulary=new HashMap<>();
    private final Map<Integer,List<String>> arabicByLength=new HashMap<>(),glossByLength=new HashMap<>(),soundByLength=new HashMap<>();
    private static final int REPAIR_CACHE_LIMIT=256;
    private final Map<String,List<String>> arabicRepairCache=repairCache(),glossRepairCache=repairCache(),soundRepairCache=repairCache();
    private final FragmentSearch fragments;
    private static final Pattern COORDINATE=Pattern.compile("^(?:Q:)?([0-9]{1,3})\\s*[:：]\\s*([0-9]{1,3})$",Pattern.CASE_INSENSITIVE);
    private static final Set<String> NEGATION=new HashSet<>(Arrays.asList(
        "لا","لم","لن","ليس","ليست","غير","دون","نہیں","نهيں","نہ","مت","नहीं","नही","मत","बिना","nahi","nahin","no","not","never","without"));

    public SearchEngine(List<Document> documents) {
        List<Document> sorted=new ArrayList<>(documents);
        sorted.sort(Comparator.comparingInt((Document d)->d.ayah.surah).thenComparingInt(d->d.ayah.number));
        List<Document> compact=new ArrayList<>(sorted.size());
        for(int d=0;d<sorted.size();d++) {
            cancelled();Document doc=sorted.get(d);
            if(coordinates.put(doc.ayah.surah+":"+doc.ayah.number,d)!=null)throw new IllegalArgumentException("Duplicate source coordinate");
            safe.add(Arabic.safe(doc.ayah.arabic));arabic.add(Arabic.tolerant(doc.ayah.arabic),d);gloss.add(TextMatch.normalize(doc.hints),d);
            List<String> sounds=TextMatch.phoneticTokens(doc.transliteration);sound.add(String.join(" ",sounds),d);
            // Hints/transliteration are fully indexed above; retaining the large combined strings
            // would duplicate translation memory on low-RAM devices. Result identity only needs Ayah.
            compact.add(new Document(doc.ayah,"",""));
        }
        docs=Collections.unmodifiableList(compact);
        arabic.finish();gloss.finish();sound.finish();
        indexByLength(arabic.terms.keySet(),arabicByLength);indexByLength(gloss.terms.keySet(),glossByLength);indexByLength(sound.terms.keySet(),soundByLength);
        for(String word:sound.terms.keySet())for(String gram:Arabic.trigrams(word))soundVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
        for(String word:gloss.terms.keySet())for(String gram:Arabic.trigrams(word))glossVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
        List<String> vocabulary=new ArrayList<>(arabic.terms.keySet());Collections.sort(vocabulary);
        for(String word:vocabulary)for(String gram:Arabic.trigrams(word))trigramVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
        List<Ayah> sources=new ArrayList<>();for(Document document:docs)sources.add(document.ayah);fragments=new FragmentSearch(sources);
    }
    public Response search(String input,int limit) {
        String raw=input==null?"":input;
        LongQuery.Plan userPlan=LongQuery.plan(raw);
        List<Query> all=new ArrayList<>();
        for(String window:userPlan.windows)all.add(new Query(window,Origin.USER));
        return searchQueries(raw,all,limit,userPlan.segmented,userPlan.sourceWindows);
    }
    /** AI variants are explicitly tagged; more matching variants never verify an answer. */
    public Response search(String original,List<Query> queries,int limit) {
        String raw=original==null?"":original;
        LongQuery.Plan userPlan=LongQuery.plan(raw);
        List<Query> all=new ArrayList<>();
        if(userPlan.segmented){
            for(String window:userPlan.windows)all.add(new Query(window,Origin.USER));
        }else{
            // Preserve the historical explicit multi-formulation API: callers using this
            // overload may intentionally place independent user formulations on separate lines.
            for(String line:raw.split("\\R"))if(!line.trim().isEmpty())
                all.add(new Query(line.trim(),Origin.USER));
            if(all.isEmpty())for(String window:userPlan.windows)all.add(new Query(window,Origin.USER));
        }

        // External variants are also bounded through the same planner. Never reject a useful
        // pasted query merely because one formulation is long.
        if(queries!=null)for(Query query:queries){
            if(query==null||query.text==null||query.text.trim().isEmpty())continue;
            LongQuery.Plan planned=LongQuery.plan(query.text);
            for(String window:planned.windows){
                all.add(new Query(window,query.origin));
                if(all.size()>=24)break;
            }
            if(all.size()>=24)break;
        }
        return searchQueries(raw,all,limit,userPlan.segmented,userPlan.sourceWindows);
    }
    private Response searchQueries(String original,List<Query> queries,int limit,boolean longUser,int sourceWindows) {
        long started=System.nanoTime();List<Variant> variants=new ArrayList<>();Map<String,Integer> trace=new LinkedHashMap<>();
        String raw=original==null?"":original;
        Map<String,Variant> distinct=new LinkedHashMap<>();
        for(Query q:queries) {
            cancelled();Variant v=new Variant(q);if(v.safe.isEmpty())continue;
            // LongQuery already keeps each retrieval window bounded. This is a defensive fallback
            // for callers constructing Query objects directly.
            if(v.original.length()>LongQuery.SHORT_CHARS||Arabic.tokens(v.tolerant).size()>LongQuery.SHORT_TOKENS){
                LongQuery.Plan nested=LongQuery.plan(v.original);
                for(String window:nested.windows){
                    Variant piece=new Variant(new Query(window,v.origin));
                    Variant previous=distinct.get(piece.tolerant);
                    if(previous==null||(previous.origin==Origin.AI&&piece.origin==Origin.USER))distinct.put(piece.tolerant,piece);
                    if(distinct.size()>=24)break;
                }
                if(distinct.size()>=24)break;
                continue;
            }
            Variant previous=distinct.get(v.tolerant);
            if(previous==null||(previous.origin==Origin.AI&&v.origin==Origin.USER))distinct.put(v.tolerant,v);
            if(distinct.size()>=24)break;
        }
        variants.addAll(distinct.values());
        Map<Integer,Result> best=new HashMap<>();Map<Integer,Double> fused=new HashMap<>();Map<Integer,List<Integer>> votes=new HashMap<>();
        Set<Integer> candidates=new HashSet<>();String intent=variants.isEmpty()?"EMPTY":longUser?"LONG_TEXT":variants.size()>1?"MULTI_QUERY":"TEXT";
        for(int v=0;v<variants.size();v++) {
            Variant variant=variants.get(v);
            Matcher coordinate=COORDINATE.matcher(Arabic.asciiDigits(variant.original));
            List<Result> lane;
            if(coordinate.matches()) {
                if(variants.size()==1)intent="COORDINATE";
                Integer d=coordinates.get(Integer.parseInt(coordinate.group(1))+":"+Integer.parseInt(coordinate.group(2)));
                lane=new ArrayList<>();if(d!=null){candidates.add(d);lane.add(result(d,Strength.STRONG_TEXT,Collections.singletonList("Ayah reference"),1,0));}
            }else lane=retrieve(variant,candidates,trace);
            for(int rank=0;rank<lane.size();rank++) {
                Result r=lane.get(rank);int d=coordinates.get(r.ayah.surah+":"+r.ayah.number);
                Result prev=best.get(d);
                if(prev==null||RESULT_ORDER.compare(r,prev)<0)best.put(d,r);
                fused.merge(d,1.0/(60+rank+1),Double::sum);votes.computeIfAbsent(d,k->new ArrayList<>()).add(v);
            }
        }
        List<Result> results=new ArrayList<>();
        for(Map.Entry<Integer,Result> e:best.entrySet()) {
            Result r=e.getValue();List<String> reasons=new ArrayList<>(r.reasons);
            boolean userMatch=false;for(int v:votes.get(e.getKey()))if(variants.get(v).origin==Origin.USER)userMatch=true;
            if(!userMatch)reasons.add("Matched an AI search formulation, not the original wording");
            if(longUser)reasons.add(votes.get(e.getKey()).size()+"/"+variants.size()+" remembered-text windows matched");
            else if(variants.size()>1)reasons.add(votes.get(e.getKey()).size()+"/"+variants.size()+" distinct formulations matched; not independent evidence");
            results.add(new Result(r.ayah,r.strength,reasons,r.score+fused.get(e.getKey())*.0001,votes.get(e.getKey()),r.transformationCost,r.match,r.reference,r.meaning));
        }
        results.sort(RESULT_ORDER);
        trace.put("variants",variants.size());trace.put("candidates",candidates.size());trace.put("accepted",results.size());
        trace.put("rejected",Math.max(0,candidates.size()-results.size()));
        if(longUser){trace.put("long_query",1);trace.put("source_windows",sourceWindows);}
        FragmentSearch.Report partial=null;
        if(!longUser&&variants.size()==1&&variants.get(0).origin==Origin.USER&&intent.equals("TEXT")&&
            (results.isEmpty()||results.get(0).strength!=Strength.STRONG_TEXT))partial=fragments.search(variants.get(0).original);
        if(partial!=null){trace.put("fragments",partial.fragments.size());trace.put("fragment_matched_words",partial.matchedTokens);trace.put("fragment_query_words",partial.totalTokens);}
        int count=Math.min(Math.max(1,Math.min(6236,limit)),results.size());
        return new Response(raw,intent,new ArrayList<>(results.subList(0,count)),variants,trace,started,partial);
    }
    private List<Result> retrieve(Variant variant,Set<Integer> allCandidates,Map<String,Integer> trace) {
        List<String> terms=Arabic.tokens(variant.tolerant),hints=TextMatch.tokens(variant.original),focusedHints=MeaningSearch.focusTokens(hints),sounds=TextMatch.phoneticTokens(variant.original);
        if(variant.safe.codePointCount(0,variant.safe.length())<2)return Collections.emptyList();
        Map<Integer,Double> lexical=arabic.rank(terms),meanings=gloss.rank(hints),phonetic=sound.rank(sounds);
        Map<String,List<String>> arRepairs=new HashMap<>(),glossRepairs=new HashMap<>(),soundRepairs=new HashMap<>();
        Set<Integer> pool=new TreeSet<>(lexical.keySet());pool.addAll(meanings.keySet());pool.addAll(phonetic.keySet());
        for(String term:new LinkedHashSet<>(terms))if(Arabic.hasArabic(term)){
            List<String> alternatives=mergeAlternatives(wordFormAlternatives(term,trigramVocabulary,terms.size()>1),repairs(term,terms.size()>=3));
            arRepairs.put(term,alternatives);for(String w:alternatives)for(Posting p:arabic.terms.get(w))pool.add(p.doc);
        }
        for(String term:new LinkedHashSet<>(hints)){
            List<String> alternatives=mergeAlternatives(
                MeaningSearch.alternatives(term),
                mergeAlternatives(wordFormAlternatives(term,glossVocabulary,hints.size()>1),glossRepairs(term)));
            glossRepairs.put(term,alternatives);for(String w:alternatives){List<Posting> postings=gloss.terms.get(w);if(postings!=null)for(Posting p:postings)pool.add(p.doc);}
        }
        if(sounds.size()>=3)for(String term:new LinkedHashSet<>(sounds)){List<String> alternatives=spellingAlternatives(term,soundVocabulary,soundByLength,3,soundRepairCache);soundRepairs.put(term,alternatives);for(String word:alternatives)for(Posting p:sound.terms.get(word))pool.add(p.doc);}
        allCandidates.addAll(pool);trace.merge("arabic_bm25",lexical.size(),Integer::sum);trace.merge("gloss_bm25",meanings.size(),Integer::sum);trace.merge("phonetic",phonetic.size(),Integer::sum);
        Map<String,Double> weights=weights(terms,arabic),hintWeights=weights(hints,gloss);List<Result> out=new ArrayList<>();
        for(int d:pool){cancelled();
            TextMatch ar=TextMatch.compare(terms,arabic.tokens.get(d),arRepairs,weights);
            TextMatch hint=TextMatch.compare(hints,gloss.tokens.get(d),glossRepairs,hintWeights);
            TextMatch focused=focusedHints.equals(hints)?hint:TextMatch.compare(focusedHints,gloss.tokens.get(d),glossRepairs,hintWeights);
            TextMatch phone=TextMatch.compare(sounds,sound.tokens.get(d),soundRepairs,Collections.emptyMap());
            boolean exact=Arabic.hasArabic(variant.original)&&phrase(safe.get(d),variant.safe);
            TextMatch chosen=ar;String reason="Arabic text overlap";double penalty=0;boolean meaning=false;
            if(!ar.accepted||hint.accepted&&TextMatch.compareRank(hint,ar)<0){
                chosen=hint;reason="Translation / source word meaning";penalty=.005;
                meaning=MeaningSearch.usesConceptBridge(hints,gloss.tokens.get(d));
            }
            if(focused!=hint&&focused.accepted&&(!chosen.accepted||focused.band.ordinal()<chosen.band.ordinal())){
                chosen=focused;reason="Remembered meaning / translation concepts";penalty=.02;meaning=true;
            }
            if(!hints.stream().anyMatch(TextMatch::negative)&&!sounds.isEmpty()&&sounds.size()>=Math.min(2,hints.size())&&sounds.size()>=hints.size()*.6&&phone.accepted&&phone.coverage>=.8&&phone.exact>=Math.min(2,sounds.size())&&(!chosen.accepted||TextMatch.compareRank(phone,chosen)<0&&phone.score-.08>chosen.score)){
                chosen=phone;reason="Similar pronunciation; check the original text";penalty=.08;meaning=false;
            }
            if(!chosen.accepted)continue;
            List<String> reasons=Arrays.asList(reason,chosen.explanation(), "Match level is text similarity, not authenticity");
            out.add(new Result(docs.get(d).ayah,exact?Strength.STRONG_TEXT:Strength.RELATED,reasons,chosen.score-penalty,Collections.emptyList(),penalty,chosen,false,meaning));
        }
        out.sort(RESULT_ORDER);return out;
    }
    private Map<String,Double> weights(List<String> query,Index index){Map<String,Double> weights=new HashMap<>();for(String term:query){List<Posting> posting=index.terms.get(term);weights.put(term,Math.max(.25,Math.log(1.+docs.size()/(1.+(posting==null?0:posting.size())))));}return weights;}
    /**
     * Exact contiguous word-form lane for attached prefixes/suffixes (for example قال -> فقال
     * or رحمن -> والرحمن). It is deliberately not arbitrary substring search: short queries,
     * negation, large affix gaps and unbounded vocabulary scans are rejected.
     */
    private static List<String> wordFormAlternatives(String term,Map<String,List<String>> vocabulary,boolean hasContext){
        if(term==null||term.length()>128||TextMatch.negative(term))return Collections.emptyList();
        boolean arabicTerm=Arabic.hasArabic(term);int minimum=arabicTerm&&hasContext?3:4,maxExtra=arabicTerm?3:4;
        if(term.length()<minimum)return Collections.emptyList();
        Map<String,Integer> overlap=new HashMap<>();
        for(String gram:Arabic.trigrams(term))for(String word:vocabulary.getOrDefault(gram,Collections.emptyList())){
            cancelled();if(word.equals(term)||word.length()<term.length()||word.length()-term.length()>maxExtra||!word.contains(term))continue;
            overlap.merge(word,1,Integer::sum);
        }
        List<String> out=new ArrayList<>(overlap.keySet());
        out.sort(Comparator.comparingInt((String word)->word.length()-term.length())
            .thenComparing(Comparator.comparingInt((String word)->overlap.get(word)).reversed()).thenComparing(word->word));
        return Collections.unmodifiableList(new ArrayList<>(out.subList(0,Math.min(16,out.size()))));
    }
    private static List<String> mergeAlternatives(List<String> preferred,List<String> fallback){
        if(preferred.isEmpty())return fallback;if(fallback.isEmpty())return preferred;
        LinkedHashSet<String> merged=new LinkedHashSet<>(preferred);merged.addAll(fallback);
        return Collections.unmodifiableList(new ArrayList<>(merged));
    }
    private List<String> glossRepairs(String term){return spellingAlternatives(term,glossVocabulary,glossByLength,4,glossRepairCache);}
    private static Map<String,List<String>> repairCache(){
        return Collections.synchronizedMap(new LinkedHashMap<String,List<String>>(64,.75f,true){
            @Override protected boolean removeEldestEntry(Map.Entry<String,List<String>> eldest){return size()>REPAIR_CACHE_LIMIT;}
        });
    }
    private static void indexByLength(Set<String> words,Map<Integer,List<String>> index){
        for(String word:words)index.computeIfAbsent(word.length(),k->new ArrayList<>()).add(word);
        for(List<String> bucket:index.values())Collections.sort(bucket);
    }
    private static void addShortRepairs(String term,int max,Map<Integer,List<String>> byLength,Map<String,Integer> overlap,Map<String,Integer> distances){
        if(term.length()<4||term.length()>6)return;
        for(int length=Math.max(1,term.length()-max);length<=term.length()+max;length++)for(String word:byLength.getOrDefault(length,Collections.emptyList())){
            cancelled();if(word.equals(term)||distances.containsKey(word))continue;
            int distance=TextMatch.distance(term,word,max);if(distance<=max){distances.put(word,distance);overlap.putIfAbsent(word,0);}
        }
    }
    private List<String> spellingAlternatives(String term,Map<String,List<String>> vocabulary,Map<Integer,List<String>> byLength,int min,Map<String,List<String>> cache){
        if(term.length()<min||term.length()>128||TextMatch.negative(term))return Collections.emptyList();
        List<String> cached=cache.get(term);if(cached!=null)return cached;
        int max=term.length()>=8?2:1;Map<String,Integer> overlap=new HashMap<>();
        for(String gram:Arabic.trigrams(term))for(String w:vocabulary.getOrDefault(gram,Collections.emptyList()))if(!w.equals(term)&&Math.abs(w.length()-term.length())<=max)overlap.merge(w,1,Integer::sum);
        List<String> words=new ArrayList<>(overlap.keySet());words.sort(Comparator.comparingInt((String w)->overlap.get(w)).reversed().thenComparing(w->w));Map<String,Integer> distances=new HashMap<>();
        for(int i=0;i<Math.min(160,words.size());i++){String w=words.get(i);int distance=TextMatch.distance(term,w,max);if(distance<=max)distances.put(w,distance);}
        addShortRepairs(term,max,byLength,overlap,distances);
        List<String> out=new ArrayList<>(distances.keySet());out.sort(Comparator.comparingInt((String w)->distances.get(w)).thenComparing(Comparator.comparingInt((String w)->overlap.getOrDefault(w,0)).reversed()).thenComparing(w->w));
        List<String> result=Collections.unmodifiableList(new ArrayList<>(out.subList(0,Math.min(8,out.size()))));cache.put(term,result);return result;
    }
    private static final Comparator<Result> RESULT_ORDER=(a,b)->{
        int c=TextMatch.compareRank(a.match,b.match);if(c!=0)return c;
        c=Double.compare(a.transformationCost,b.transformationCost);if(c!=0)return c;
        c=Double.compare(b.score,a.score);if(c!=0)return c;
        return Integer.compare(a.ayah.ordinal,b.ayah.ordinal);
    };
    private Result result(int d,Strength strength,List<String> reasons,double score,double cost){return new Result(docs.get(d).ayah,strength,reasons,score,Collections.emptyList(),cost);}
    private static boolean phrase(String text,String phrase){return (" "+text+" ").contains(" "+phrase+" ");}
    private List<String> repairs(String term,boolean hasContext) {
        if(term.length()<(hasContext?3:4)||NEGATION.contains(term))return Collections.emptyList();
        List<String> cached=arabicRepairCache.get(term);if(cached!=null)return cached;
        int max=term.length()>=8?2:1;Map<String,Integer> overlap=new HashMap<>();
        for(String gram:Arabic.trigrams(term))for(String w:trigramVocabulary.getOrDefault(gram,Collections.emptyList()))
            if(!w.equals(term)&&Math.abs(w.length()-term.length())<=max&&!NEGATION.contains(w))overlap.merge(w,1,Integer::sum);
        Map<String,Integer> distances=new HashMap<>();
        for(String w:overlap.keySet()){cancelled();int distance=TextMatch.distance(term,w,max);if(distance<=max)distances.put(w,distance);}
        addShortRepairs(term,max,arabicByLength,overlap,distances);
        List<String> ranked=new ArrayList<>(distances.keySet());ranked.sort(Comparator.comparingInt((String w)->distances.get(w))
            .thenComparing(Comparator.comparingInt((String w)->overlap.get(w)).reversed()).thenComparing(w->w));
        // Uthmani small-alif spellings can share only one trigram with ordinary typed words.
        // Keep enough bounded alternatives for context scoring to resolve them (مالك / ملك).
        List<String> result=Collections.unmodifiableList(new ArrayList<>(ranked.subList(0,Math.min(64,ranked.size()))));arabicRepairCache.put(term,result);return result;
    }
    private static void cancelled(){if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();}
}
