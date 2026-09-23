package com.aaris.quran.core;

import java.util.*;
import java.util.regex.*;

/** Rebuildable deterministic indexes. Matching text is not a religious conclusion. */
public final class SearchEngine {
    public static final String VERSION = "ranked-6";
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
        Result(Ayah ayah,Strength strength,List<String> reasons,double score,List<Integer> variants,double cost) {
            this(ayah,strength,reasons,score,variants,cost,TextMatch.exactReference());
        }
        Result(Ayah ayah,Strength strength,List<String> reasons,double score,List<Integer> variants,double cost,TextMatch match) {
            this.match=match;
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
    private final List<Document> docs;
    private final List<String> safe=new ArrayList<>();
    private final Map<String,Integer> coordinates=new HashMap<>();
    private final Index arabic=new Index(),gloss=new Index(),sound=new Index();
    private final Map<String,List<String>> glossVocabulary=new HashMap<>(),soundVocabulary=new HashMap<>();
    private final Map<String,List<String>> trigramVocabulary=new HashMap<>();
    private final FragmentSearch fragments;
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
            safe.add(Arabic.safe(doc.ayah.arabic));arabic.add(Arabic.tolerant(doc.ayah.arabic),d);gloss.add(TextMatch.normalize(doc.hints),d);
            List<String> sounds=TextMatch.phoneticTokens(doc.transliteration);sound.add(String.join(" ",sounds),d);
        }
        arabic.finish();gloss.finish();sound.finish();
        for(String word:sound.terms.keySet())for(String gram:Arabic.trigrams(word))soundVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
        for(String word:gloss.terms.keySet())for(String gram:Arabic.trigrams(word))glossVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
        List<String> vocabulary=new ArrayList<>(arabic.terms.keySet());Collections.sort(vocabulary);
        for(String word:vocabulary)for(String gram:Arabic.trigrams(word))trigramVocabulary.computeIfAbsent(gram,k->new ArrayList<>()).add(word);
        List<Ayah> sources=new ArrayList<>();for(Document document:docs)sources.add(document.ayah);fragments=new FragmentSearch(sources);
    }
    public Response search(String input,int limit) {
        String original=input==null?"":input;
        // Pasted line breaks are paragraph whitespace, not independent high-confidence queries.
        return searchQueries(original,Collections.singletonList(new Query(original.replaceAll("\\s+"," "),Origin.USER)),limit);
    }
    /** AI variants are explicitly tagged; more matching variants never verify an answer. */
    public Response search(String original,List<Query> queries,int limit) {
        List<Query> all=new ArrayList<>();
        for(String line:(original==null?"":original).split("\\R"))if(!line.trim().isEmpty())all.add(new Query(line,Origin.USER));
        all.addAll(queries);
        return searchQueries(original,all,limit);
    }
    private Response searchQueries(String original,List<Query> queries,int limit) {
        long started=System.nanoTime();List<Variant> variants=new ArrayList<>();Map<String,Integer> trace=new LinkedHashMap<>();
        String raw=original==null?"":original;
        if(raw.length()>16384||queries.size()>64)return new Response(raw,"QUERY_LIMIT",Collections.emptyList(),variants,trace,started);
        Map<String,Variant> distinct=new LinkedHashMap<>();
        for(Query q:queries) {
            cancelled();Variant v=new Variant(q);if(v.safe.isEmpty())continue;
            if(v.original.length()>16384||Arabic.tokens(v.tolerant).size()>2048)return new Response(raw,"QUERY_LIMIT",Collections.emptyList(),variants,trace,started);
            // Equivalent spelling variants get one vote, with user provenance preferred.
            Variant previous=distinct.get(v.tolerant);
            if(previous==null||(previous.origin==Origin.AI&&v.origin==Origin.USER))distinct.put(v.tolerant,v);
        }
        variants.addAll(distinct.values());
        if(variants.size()>8){variants.clear();variants.add(new Variant(new Query(raw.replaceAll("\\s+"," "),Origin.USER)));}
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
                    (r.strength==prev.strength&&r.score>prev.score))best.put(d,r);
                fused.merge(d,1.0/(60+rank+1),Double::sum);votes.computeIfAbsent(d,k->new ArrayList<>()).add(v);
            }
        }
        List<Result> results=new ArrayList<>();
        for(Map.Entry<Integer,Result> e:best.entrySet()) {
            Result r=e.getValue();List<String> reasons=new ArrayList<>(r.reasons);
            boolean userMatch=false;for(int v:votes.get(e.getKey()))if(variants.get(v).origin==Origin.USER)userMatch=true;
            if(!userMatch)reasons.add("Matched an AI search formulation, not the original wording");
            if(variants.size()>1)reasons.add(votes.get(e.getKey()).size()+"/"+variants.size()+" distinct formulations matched; not independent evidence");
            results.add(new Result(r.ayah,r.strength,reasons,r.score+fused.get(e.getKey())*.0001,votes.get(e.getKey()),r.transformationCost,r.match));
        }
        results.sort(Comparator.comparingDouble((Result r)->r.score).reversed()
            .thenComparingDouble(r->r.transformationCost).thenComparingInt(r->r.ayah.surah).thenComparingInt(r->r.ayah.number));
        trace.put("variants",variants.size());trace.put("candidates",candidates.size());trace.put("accepted",results.size());
        trace.put("rejected",Math.max(0,candidates.size()-results.size()));
        FragmentSearch.Report partial=null;
        if(variants.size()==1&&variants.get(0).origin==Origin.USER&&intent.equals("TEXT")&&
            (results.isEmpty()||results.get(0).strength!=Strength.STRONG_TEXT))partial=fragments.search(variants.get(0).original);
        if(partial!=null){trace.put("fragments",partial.fragments.size());trace.put("fragment_matched_words",partial.matchedTokens);trace.put("fragment_query_words",partial.totalTokens);}
        int count=Math.min(Math.max(1,Math.min(6236,limit)),results.size());
        return new Response(raw,intent,new ArrayList<>(results.subList(0,count)),variants,trace,started,partial);
    }
    private List<Result> retrieve(Variant variant,Set<Integer> allCandidates,Map<String,Integer> trace) {
        List<String> terms=Arabic.tokens(variant.tolerant),hints=TextMatch.tokens(variant.original),sounds=TextMatch.phoneticTokens(variant.original);
        if(variant.safe.codePointCount(0,variant.safe.length())<2)return Collections.emptyList();
        Map<Integer,Double> lexical=arabic.rank(terms),meanings=gloss.rank(hints),phonetic=sound.rank(sounds);
        Map<String,List<String>> arRepairs=new HashMap<>(),glossRepairs=new HashMap<>(),soundRepairs=new HashMap<>();
        Set<Integer> pool=new TreeSet<>(lexical.keySet());pool.addAll(meanings.keySet());pool.addAll(phonetic.keySet());
        for(String term:new LinkedHashSet<>(terms))if(Arabic.hasArabic(term)){List<String> alternatives=repairs(term,terms.size()>=3);arRepairs.put(term,alternatives);for(String w:alternatives)for(Posting p:arabic.terms.get(w))pool.add(p.doc);}
        for(String term:new LinkedHashSet<>(hints)){List<String> alternatives=glossRepairs(term);glossRepairs.put(term,alternatives);for(String w:alternatives)for(Posting p:gloss.terms.get(w))pool.add(p.doc);}
        if(sounds.size()>=3)for(String term:new LinkedHashSet<>(sounds)){List<String> alternatives=spellingAlternatives(term,soundVocabulary,3);soundRepairs.put(term,alternatives);for(String word:alternatives)for(Posting p:sound.terms.get(word))pool.add(p.doc);}
        allCandidates.addAll(pool);trace.merge("arabic_bm25",lexical.size(),Integer::sum);trace.merge("gloss_bm25",meanings.size(),Integer::sum);trace.merge("phonetic",phonetic.size(),Integer::sum);
        Map<String,Double> weights=weights(terms,arabic),hintWeights=weights(hints,gloss);List<Result> out=new ArrayList<>();
        for(int d:pool){cancelled();
            TextMatch ar=TextMatch.compare(terms,arabic.tokens.get(d),arRepairs,weights);
            TextMatch hint=TextMatch.compare(hints,gloss.tokens.get(d),glossRepairs,hintWeights);
            TextMatch phone=TextMatch.compare(sounds,sound.tokens.get(d),soundRepairs,Collections.emptyMap());
            boolean exact=Arabic.hasArabic(variant.original)&&phrase(safe.get(d),variant.safe);
            TextMatch chosen=ar;String reason="Arabic text overlap";double penalty=0;
            if(!ar.accepted||hint.accepted&&hint.score>ar.score){chosen=hint;reason="Translation / source word meaning";penalty=.005;}
            if(!hints.stream().anyMatch(TextMatch::negative)&&!sounds.isEmpty()&&sounds.size()>=Math.min(2,hints.size())&&sounds.size()>=hints.size()*.6&&phone.accepted&&phone.coverage>=.8&&phone.exact>=Math.min(2,sounds.size())&&(!chosen.accepted||phone.score-.08>chosen.score)){chosen=phone;reason="Similar pronunciation; check the original text";penalty=.08;}
            if(!chosen.accepted)continue;
            List<String> reasons=Arrays.asList(reason,chosen.matched+" / "+chosen.total+" query words matched", "Match level is text similarity, not authenticity");
            out.add(new Result(docs.get(d).ayah,exact?Strength.STRONG_TEXT:Strength.RELATED,reasons,chosen.score-penalty,Collections.emptyList(),penalty,chosen));
        }
        out.sort(Comparator.comparingDouble((Result r)->r.score).reversed().thenComparingInt(r->r.ayah.ordinal));return out;
    }
    private Map<String,Double> weights(List<String> query,Index index){Map<String,Double> weights=new HashMap<>();for(String term:query){List<Posting> posting=index.terms.get(term);weights.put(term,Math.max(.25,Math.log(1.+docs.size()/(1.+(posting==null?0:posting.size())))));}return weights;}
    private List<String> glossRepairs(String term){return spellingAlternatives(term,glossVocabulary,4);}
    private List<String> spellingAlternatives(String term,Map<String,List<String>> vocabulary,int min){
        if(term.length()<min||term.length()>128||TextMatch.negative(term))return Collections.emptyList();int max=term.length()>=8?2:1;Map<String,Integer> overlap=new HashMap<>();
        for(String gram:Arabic.trigrams(term))for(String w:vocabulary.getOrDefault(gram,Collections.emptyList()))if(!w.equals(term)&&Math.abs(w.length()-term.length())<=max)overlap.merge(w,1,Integer::sum);
        List<String> words=new ArrayList<>(overlap.keySet());words.sort(Comparator.comparingInt((String w)->overlap.get(w)).reversed().thenComparing(w->w));List<String> out=new ArrayList<>();
        for(int i=0;i<Math.min(160,words.size())&&out.size()<8;i++){String w=words.get(i);if(TextMatch.distance(term,w,max)<=max)out.add(w);}return out;
    }
    private Result result(int d,Strength strength,List<String> reasons,double score,double cost){return new Result(docs.get(d).ayah,strength,reasons,score,Collections.emptyList(),cost);}
    private static boolean phrase(String text,String phrase){return (" "+text+" ").contains(" "+phrase+" ");}
    private List<String> repairs(String term,boolean hasContext) {
        if(term.length()<(hasContext?3:4)||NEGATION.contains(term))return Collections.emptyList();
        int max=term.length()>=8?2:1;Map<String,Integer> overlap=new HashMap<>();
        for(String gram:Arabic.trigrams(term))for(String w:trigramVocabulary.getOrDefault(gram,Collections.emptyList()))
            if(!w.equals(term)&&Math.abs(w.length()-term.length())<=max&&!NEGATION.contains(w))overlap.merge(w,1,Integer::sum);
        Map<String,Integer> distances=new HashMap<>();
        for(String w:overlap.keySet()){cancelled();int distance=TextMatch.distance(term,w,max);if(distance<=max)distances.put(w,distance);}
        List<String> ranked=new ArrayList<>(distances.keySet());ranked.sort(Comparator.comparingInt((String w)->distances.get(w))
            .thenComparing(Comparator.comparingInt((String w)->overlap.get(w)).reversed()).thenComparing(w->w));
        // Uthmani small-alif spellings can share only one trigram with ordinary typed words.
        // Keep enough bounded alternatives for context scoring to resolve them (مالك / ملك).
        return new ArrayList<>(ranked.subList(0,Math.min(64,ranked.size())));
    }
    private static void cancelled(){if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();}
}
