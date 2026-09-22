package com.aaris.quran.core;

import java.util.*;
import java.util.regex.*;

/** Rebuildable deterministic indexes. Matching text is not a religious conclusion. */
public final class SearchEngine {
    public static final String VERSION = "lexical-3";
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
        public final String hints;
        public Document(Ayah ayah,String hints) { this.ayah=Objects.requireNonNull(ayah); this.hints=hints==null?"":hints; }
    }
    public static final class Result {
        public final Ayah ayah;
        public final Strength strength;
        public final List<String> reasons;
        public final double score;
        public final List<Integer> matchedVariants;
        public final double transformationCost;
        Result(Ayah ayah,Strength strength,List<String> reasons,double score,List<Integer> variants,double cost) {
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
        Response(String query,String intent,List<Result> results,List<Variant> variants,Map<String,Integer> trace,long started) {
            this.query=query;this.intent=intent;this.results=Collections.unmodifiableList(new ArrayList<>(results));
            this.variants=Collections.unmodifiableList(new ArrayList<>(variants));
            this.trace=Collections.unmodifiableMap(new LinkedHashMap<>(trace));
            candidates=trace.getOrDefault("candidates",0);elapsedNanos=System.nanoTime()-started;
            gate=results.isEmpty()?"NO_RELIABLE_MATCH":results.get(0).strength==Strength.STRONG_TEXT?"STRONG_TEXT":"RELATED";
        }
    }
    private static final class Posting {
        final int doc,tf;
        Posting(int doc,int tf){this.doc=doc;this.tf=tf;}
    }
    private static final class Index {
        final Map<String,List<Posting>> terms=new HashMap<>();
        final List<List<String>> tokens=new ArrayList<>();
        final List<String> text=new ArrayList<>();
        double averageLength;
        void add(String value,int doc) {
            text.add(value);List<String> words=Arabic.tokens(value);tokens.add(words);averageLength+=words.size();
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
    private static final class Match {
        final int doc;
        double fusion,cost;
        int window=Integer.MAX_VALUE;
        boolean exact,spelling,hint;
        List<String> reasons=new ArrayList<>();
        Match(int doc){this.doc=doc;}
    }
    private static final class Coverage {
        boolean complete;int edits,window;
    }
    private final List<Document> docs;
    private final List<String> safe=new ArrayList<>();
    private final Map<String,Integer> coordinates=new HashMap<>();
    private final Index arabic=new Index(),gloss=new Index();
    private final Map<String,List<String>> trigramVocabulary=new HashMap<>();
    private static final Pattern COORDINATE=Pattern.compile("^(?:Q:)?([0-9]{1,3})\\s*[:：]\\s*([0-9]{1,3})$",Pattern.CASE_INSENSITIVE);
    private static final Set<String> NEGATION=new HashSet<>(Arrays.asList(
        "لا","لم","لن","ليس","ليست","غير","دون","نہیں","نهيں","نہ","مت","नहीं","मत","बिना","no","not","never","without"));

    public SearchEngine(List<Document> documents) {
        List<Document> sorted=new ArrayList<>(documents);
        sorted.sort(Comparator.comparingInt((Document d)->d.ayah.surah).thenComparingInt(d->d.ayah.number));
        docs=Collections.unmodifiableList(sorted);
        for(int d=0;d<docs.size();d++) {
            cancelled();Document doc=docs.get(d);
            if(coordinates.put(doc.ayah.surah+":"+doc.ayah.number,d)!=null)throw new IllegalArgumentException("Duplicate source coordinate");
            safe.add(Arabic.safe(doc.ayah.arabic));arabic.add(Arabic.tolerant(doc.ayah.arabic),d);gloss.add(Arabic.glossSearch(doc.hints),d);
        }
        arabic.finish();gloss.finish();
        List<String> vocabulary=new ArrayList<>(arabic.terms.keySet());Collections.sort(vocabulary);
        for(String word:vocabulary)for(String gram:Arabic.trigrams(word))trigramVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
    }
    public Response search(String input,int limit) {
        String original=input==null?"":input;
        List<Query> queries=new ArrayList<>();for(String line:original.split("\\R"))if(!line.trim().isEmpty())queries.add(new Query(line,Origin.USER));
        return search(original,queries,limit);
    }
    /** AI variants are explicitly tagged; more matching variants never verify an answer. */
    public Response search(String original,List<Query> queries,int limit) {
        long started=System.nanoTime();List<Variant> variants=new ArrayList<>();Map<String,Integer> trace=new LinkedHashMap<>();
        String raw=original==null?"":original;
        if(raw.length()>4096||queries.size()>32)return new Response(raw,"QUERY_LIMIT",Collections.emptyList(),variants,trace,started);
        Map<String,Variant> distinct=new LinkedHashMap<>();
        List<Query> all=new ArrayList<>();
        for(String line:raw.split("\\R"))if(!line.trim().isEmpty())all.add(new Query(line,Origin.USER));
        all.addAll(queries);
        for(Query q:all) {
            cancelled();Variant v=new Variant(q);if(v.safe.isEmpty())continue;
            if(v.original.length()>512||Arabic.tokens(v.tolerant).size()>32)return new Response(raw,"QUERY_LIMIT",Collections.emptyList(),variants,trace,started);
            // Equivalent spelling variants get one vote, with user provenance preferred.
            Variant previous=distinct.get(v.tolerant);
            if(previous==null||(previous.origin==Origin.AI&&v.origin==Origin.USER))distinct.put(v.tolerant,v);
        }
        variants.addAll(distinct.values());
        if(variants.size()>8)return new Response(raw,"QUERY_LIMIT",Collections.emptyList(),variants,trace,started);
        Map<Integer,Result> best=new HashMap<>();Map<Integer,Double> fused=new HashMap<>();Map<Integer,List<Integer>> votes=new HashMap<>();
        Set<Integer> candidates=new HashSet<>();String intent=variants.isEmpty()?"EMPTY":variants.size()>1?"MULTI_QUERY":"TEXT";
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
                if(prev==null||r.strength.ordinal()<prev.strength.ordinal()||
                    (r.strength==prev.strength&&r.transformationCost<prev.transformationCost))best.put(d,r);
                fused.merge(d,1.0/(60+rank+1),Double::sum);votes.computeIfAbsent(d,k->new ArrayList<>()).add(v);
            }
        }
        List<Result> results=new ArrayList<>();
        for(Map.Entry<Integer,Result> e:best.entrySet()) {
            Result r=e.getValue();List<String> reasons=new ArrayList<>(r.reasons);
            boolean userMatch=false;for(int v:votes.get(e.getKey()))if(variants.get(v).origin==Origin.USER)userMatch=true;
            if(!userMatch)reasons.add("Matched an AI search formulation, not the original wording");
            if(variants.size()>1)reasons.add(votes.get(e.getKey()).size()+"/"+variants.size()+" distinct formulations matched; not independent evidence");
            results.add(new Result(r.ayah,r.strength,reasons,fused.get(e.getKey()),votes.get(e.getKey()),r.transformationCost));
        }
        results.sort(Comparator.comparingInt((Result r)->r.strength.ordinal()).thenComparingDouble(r->r.transformationCost)
            .thenComparing(Comparator.comparingDouble((Result r)->r.score).reversed())
            .thenComparingInt(r->r.ayah.surah).thenComparingInt(r->r.ayah.number));
        trace.put("variants",variants.size());trace.put("candidates",candidates.size());trace.put("accepted",results.size());
        trace.put("rejected",Math.max(0,candidates.size()-results.size()));
        int count=Math.min(Math.max(1,Math.min(100,limit)),results.size());
        return new Response(raw,intent,new ArrayList<>(results.subList(0,count)),variants,trace,started);
    }
    private List<Result> retrieve(Variant variant,Set<Integer> allCandidates,Map<String,Integer> trace) {
        List<String> terms=Arabic.tokens(variant.tolerant),hintTerms=Arabic.tokens(Arabic.glossSearch(variant.original));
        if(variant.safe.codePointCount(0,variant.safe.length())<2)return Collections.emptyList();
        Map<Integer,Double> lexical=arabic.rank(terms),meanings=gloss.rank(hintTerms),fuzzy=new HashMap<>();
        Map<String,List<String>> repairs=new HashMap<>();
        if(Arabic.hasArabic(variant.original))for(String term:new LinkedHashSet<>(terms)) {
            List<String> alternatives=repairs(term,terms.size()>=3);repairs.put(term,alternatives);
            for(String alternative:alternatives)for(Posting p:arabic.terms.get(alternative))fuzzy.merge(p.doc,1.0/(1+Arabic.editDistance(term,alternative,2)),Double::sum);
        }
        Set<Integer> pool=new TreeSet<>(lexical.keySet());pool.addAll(meanings.keySet());pool.addAll(fuzzy.keySet());allCandidates.addAll(pool);
        trace.merge("arabic_bm25",lexical.size(),Integer::sum);trace.merge("gloss_bm25",meanings.size(),Integer::sum);trace.merge("spelling",fuzzy.size(),Integer::sum);
        Map<Integer,Match> accepted=new HashMap<>();Map<Integer,Double> phrases=new HashMap<>();
        for(int d:pool) {
            cancelled();Match m=new Match(d);
            m.exact=Arabic.hasArabic(variant.original)&&phrase(safe.get(d),variant.safe);
            m.spelling=Arabic.hasArabic(variant.original)&&phrase(arabic.text.get(d),variant.tolerant);
            Coverage text=coverage(terms,arabic.tokens.get(d),repairs),hints=coverage(hintTerms,gloss.tokens.get(d),Collections.emptyMap());
            m.hint=hints.complete;
            if(m.exact){m.cost=0;m.reasons.add("Arabic phrase; reading marks ignored");phrases.put(d,3.0);}
            else if(m.spelling){m.cost=variant.normalizationCost;m.reasons.add("Arabic orthographic variation");phrases.put(d,2.0);}
            else if(text.complete){m.cost=variant.normalizationCost+text.edits*.25;m.window=text.window;
                m.reasons.add(text.edits==0?"All Arabic query words occur in this ayah":"Approximate Arabic spelling; all query words accounted for");
                m.reasons.add("Word span: "+text.window);}
            else if(m.hint){m.cost=1;m.window=hints.window;m.reasons.add("Source word meanings / transliteration; related, not a quotation");}
            else continue;
            accepted.put(d,m);
        }
        fuse(accepted,lexical);fuse(accepted,meanings);fuse(accepted,fuzzy);fuse(accepted,phrases);
        List<Match> ordered=new ArrayList<>(accepted.values());
        ordered.sort(Comparator.comparingInt((Match m)->m.exact?0:m.spelling?1:2).thenComparingDouble(m->m.cost)
            .thenComparingInt(m->m.window).thenComparing(Comparator.comparingDouble((Match m)->m.fusion).reversed()).thenComparingInt(m->m.doc));
        List<Result> out=new ArrayList<>();for(Match m:ordered)out.add(result(m.doc,m.exact?Strength.STRONG_TEXT:Strength.RELATED,m.reasons,m.fusion,m.cost));
        trace.merge("phrase",phrases.size(),Integer::sum);return out;
    }
    private Result result(int d,Strength strength,List<String> reasons,double score,double cost){return new Result(docs.get(d).ayah,strength,reasons,score,Collections.emptyList(),cost);}
    private static boolean phrase(String text,String phrase){return (" "+text+" ").contains(" "+phrase+" ");}
    private static void fuse(Map<Integer,Match> accepted,Map<Integer,Double> lane) {
        List<Integer> ids=new ArrayList<>(lane.keySet());
        ids.sort(Comparator.comparingDouble((Integer d)->lane.get(d)).reversed().thenComparingInt(d->d));
        for(int i=0;i<ids.size();i++){Match m=accepted.get(ids.get(i));if(m!=null)m.fusion+=1.0/(60+i+1);}
    }
    private List<String> repairs(String term,boolean hasContext) {
        if(term.length()<(hasContext?3:4)||NEGATION.contains(term))return Collections.emptyList();
        int max=term.length()>=8?2:1;Map<String,Integer> overlap=new HashMap<>();
        for(String gram:Arabic.trigrams(term))for(String w:trigramVocabulary.getOrDefault(gram,Collections.emptyList()))
            if(!w.equals(term)&&Math.abs(w.length()-term.length())<=max&&!NEGATION.contains(w))overlap.merge(w,1,Integer::sum);
        Map<String,Integer> distances=new HashMap<>();
        for(String w:overlap.keySet()){cancelled();int distance=Arabic.editDistance(term,w,max);if(distance<=max)distances.put(w,distance);}
        List<String> ranked=new ArrayList<>(distances.keySet());ranked.sort(Comparator.comparingInt((String w)->distances.get(w))
            .thenComparing(Comparator.comparingInt((String w)->overlap.get(w)).reversed()).thenComparing(w->w));
        return new ArrayList<>(ranked.subList(0,Math.min(8,ranked.size())));
    }
    /** Injective token matching: one source word cannot satisfy two query words. Negation is exact. */
    private static Coverage coverage(List<String> query,List<String> words,Map<String,List<String>> repairs) {
        Coverage result=new Coverage();if(query.isEmpty()||query.size()>words.size())return result;
        int[] owner=new int[words.size()];Arrays.fill(owner,-1);
        for(int q=0;q<query.size();q++)if(!assign(q,query,words,repairs,owner,new boolean[words.size()]))return result;
        int first=words.size(),last=-1;
        for(int w=0;w<owner.length;w++)if(owner[w]>=0){first=Math.min(first,w);last=Math.max(last,w);
            if(!query.get(owner[w]).equals(words.get(w)))result.edits+=Arabic.editDistance(query.get(owner[w]),words.get(w),2);}
        result.complete=true;result.window=last-first+1;return result;
    }
    private static boolean assign(int q,List<String> query,List<String> words,Map<String,List<String>> repairs,int[] owner,boolean[] seen) {
        String term=query.get(q);
        for(int pass=0;pass<2;pass++)for(int w=0;w<words.size();w++) {
            boolean exact=term.equals(words.get(w));
            if(seen[w]||(pass==0?!exact:exact)||(!exact&&(NEGATION.contains(term)||!repairs.getOrDefault(term,Collections.emptyList()).contains(words.get(w)))))continue;
            seen[w]=true;
            if(owner[w]<0||assign(owner[w],query,words,repairs,owner,seen)){owner[w]=q;return true;}
        }
        return false;
    }
    private static void cancelled(){if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();}
}
