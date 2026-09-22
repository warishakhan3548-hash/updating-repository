package com.aaris.quran.core;

import java.util.*;
import java.util.regex.*;

/** Deterministic bounded retrieval. Scores describe text relevance, never religious authority. */
public final class SearchEngine {
    public static final String VERSION = "lexical-2";
    public enum Strength { STRONG_TEXT, RELATED }
    public static final class Document {
        public final Ayah ayah;
        public final String hints;
        public Document(Ayah ayah, String hints) { this.ayah=ayah;this.hints=hints==null?"":hints; }
    }
    public static final class Result {
        public final Ayah ayah;
        public final Strength strength;
        public final List<String> reasons;
        public final double score;
        Result(Ayah a,Strength strength,List<String> reasons,double score) {
            this.ayah=a;this.strength=strength;this.reasons=Collections.unmodifiableList(reasons);this.score=score;
        }
    }
    public static final class Response {
        public final List<Result> results;
        public final String query, intent;
        public final int candidates;
        public final long elapsedNanos;
        Response(String q,String intent,List<Result> r,int n,long elapsed) {
            query=q;this.intent=intent;results=Collections.unmodifiableList(r);candidates=n;elapsedNanos=elapsed;
        }
    }
    private static final class Posting { int doc,tf; Posting(int d,int t){doc=d;tf=t;} }
    private static final class Candidate {
        final int doc;
        double lexical,fused,coverage;
        boolean exact,tolerant,hint;
        final LinkedHashSet<String> reasons=new LinkedHashSet<>();
        Candidate(int d){doc=d;}
    }
    private final List<Document> docs;
    private final List<String> safe=new ArrayList<>(), tolerant=new ArrayList<>(), hints=new ArrayList<>();
    private final Map<String,List<Posting>> postings=new HashMap<>();
    private final Map<String,Integer> coordinates=new HashMap<>();
    private final int[] lengths;
    private final double averageLength;
    private final List<String> vocabulary;
    private static final Set<String> NEGATION = new HashSet<>(Arrays.asList(
        "لا", "لم", "لن", "ليس", "ليست", "غير", "دون", "نہیں", "نهيں", "نہ", "مت",
        "नहीं", "मत", "बिना", "no", "not", "never", "without"));
    public SearchEngine(List<Document> documents) {
        docs=Collections.unmodifiableList(new ArrayList<>(documents));lengths=new int[docs.size()];
        long words=0;
        for(int d=0;d<docs.size();d++) {
            cancelled();
            Document doc=docs.get(d);
            coordinates.put(doc.ayah.surah+":"+doc.ayah.number,d);
            String normalized=Arabic.tolerant(doc.ayah.arabic);
            safe.add(Arabic.safe(doc.ayah.arabic));tolerant.add(normalized);hints.add(Arabic.tolerant(doc.hints));
            Map<String,Integer> counts=new HashMap<>();
            for(String t:Arabic.tokens(normalized)) counts.merge(t,1,Integer::sum);
            lengths[d]=Arabic.tokens(normalized).size();words+=lengths[d];
            for(Map.Entry<String,Integer> e:counts.entrySet())
                postings.computeIfAbsent(e.getKey(),k->new ArrayList<>()).add(new Posting(d,e.getValue()));
        }
        averageLength=docs.isEmpty()?1:Math.max(1,(double)words/docs.size());
        vocabulary=new ArrayList<>(postings.keySet());Collections.sort(vocabulary);
    }
    public Response search(String input,int limit) {
        String query=input==null?"":input.trim();
        if(query.length()>4096)query=query.substring(0,4096);
        String[] lines=query.split("\\R");
        if(lines.length<2)return searchOne(query,limit);
        long started=System.nanoTime();
        Map<String,Result> best=new HashMap<>();Map<String,Double> scores=new HashMap<>();
        Map<String,Integer> matches=new HashMap<>();Set<String> variants=new LinkedHashSet<>();
        // Equivalent variants get one vote. AI paraphrases are retrieval hints, not witnesses.
        int candidates=0;
        for(String line:lines) {
            cancelled();line=line.trim();if(line.isEmpty())continue;
            if(!variants.add(Arabic.tolerant(line)))continue;
            Response response=searchOne(line,100);candidates+=response.candidates;
            int rank=0;
            for(Result result:response.results) {
                String id=result.ayah.id;Result previous=best.get(id);
                if(previous==null||result.strength==Strength.STRONG_TEXT)best.put(id,result);
                scores.merge(id,1.0/(60+(++rank)),Double::sum);matches.merge(id,1,Integer::sum);
            }
            if(variants.size()==8)break;
        }
        List<Result> merged=new ArrayList<>();
        for(Map.Entry<String,Result> entry:best.entrySet()) {
            Result result=entry.getValue();List<String> reasons=new ArrayList<>(result.reasons);
            reasons.add(matches.get(entry.getKey())+"/"+variants.size()+" distinct search lines matched");
            merged.add(new Result(result.ayah,result.strength,reasons,scores.get(entry.getKey())));
        }
        merged.sort(Comparator.comparingInt((Result r)->r.strength==Strength.STRONG_TEXT?0:1)
            .thenComparing(Comparator.comparingDouble((Result r)->r.score).reversed())
            .thenComparingInt(r->r.ayah.surah).thenComparingInt(r->r.ayah.number));
        int count=Math.min(Math.max(1,Math.min(limit,100)),merged.size());
        return new Response(query,"MULTI_QUERY",new ArrayList<>(merged.subList(0,count)),candidates,System.nanoTime()-started);
    }
    private static void cancelled() {
        if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
    }
    private Response searchOne(String input,int limit) {
        long start=System.nanoTime();
        String query=(input==null?"":input).trim();
        if(query.length()>512) query=query.substring(0,512);
        limit=Math.max(1,Math.min(limit,100));
        Matcher ref=Pattern.compile("^(?:Q:)?([0-9]{1,3})\\s*[:：]\\s*([0-9]{1,3})$",Pattern.CASE_INSENSITIVE).matcher(Arabic.asciiDigits(query));
        if(ref.matches()) {
            Integer i=coordinates.get(Integer.parseInt(ref.group(1))+":"+Integer.parseInt(ref.group(2)));
            List<Result> result=i==null?Collections.emptyList():Collections.singletonList(new Result(docs.get(i).ayah,Strength.STRONG_TEXT,Collections.singletonList("Ayah reference"),1));
            return new Response(query,"COORDINATE",result,result.size(),System.nanoTime()-start);
        }
        String sq=Arabic.safe(query),tq=Arabic.tolerant(query);
        if(sq.codePointCount(0,sq.length())<2 || docs.isEmpty()) return new Response(query,"EMPTY",Collections.emptyList(),0,System.nanoTime()-start);
        Map<Integer,Candidate> found=new HashMap<>();
        boolean arabic=Arabic.hasArabic(query);
        List<String> terms=new ArrayList<>(new LinkedHashSet<>(Arabic.tokens(tq)));
        if(terms.size()>16) terms=terms.subList(0,16);
        // First lane: verbatim-safe phrase, second: orthographic tolerance. Token boundaries matter.
        for(int d=0;d<docs.size();d++) {
            cancelled();
            boolean exact=arabic && (" "+safe.get(d)+" ").contains(" "+sq+" ");
            boolean relaxed=arabic && (" "+tolerant.get(d)+" ").contains(" "+tq+" ");
            if(exact||relaxed) {
                Candidate c=found.computeIfAbsent(d,Candidate::new);c.exact=exact;c.tolerant=relaxed;c.coverage=1;
                c.reasons.add(exact?"Arabic phrase (diacritics ignored)":"Arabic spelling variant");
            }
        }
        // BM25 candidates are retrieved only from the immutable local corpus.
        for(String term:terms) {
            List<Posting> list=postings.get(term);if(list==null)continue;
            double idf=Math.log(1+(docs.size()-list.size()+0.5)/(list.size()+0.5));
            for(Posting p:list) {
                Candidate c=found.computeIfAbsent(p.doc,Candidate::new);
                c.lexical+=idf*(p.tf*2.2)/(p.tf+1.2*(0.25+0.75*lengths[p.doc]/averageLength));
            }
        }
        // Bounded typo repair: only plausible token lengths; never root=meaning or fuzzy=exact.
        if(arabic) for(String term:terms) {
            if(term.length()<4 || postings.containsKey(term))continue;
            int maxEdits=term.length()>=8?2:1;
            List<String> repairs=new ArrayList<>();
            Set<String> grams=Arabic.trigrams(term);
            for(String candidate:vocabulary) {
                cancelled();
                if(Math.abs(term.length()-candidate.length())>maxEdits)continue;
                Set<String> other=Arabic.trigrams(candidate);int common=0;
                for(String g:grams)if(other.contains(g))common++;
                if(common==0 || Arabic.editDistance(term,candidate,maxEdits)>maxEdits)continue;
                repairs.add(candidate);if(repairs.size()>=8)break;
            }
            for(String candidate:repairs)for(Posting p:postings.get(candidate)) {
                Candidate c=found.computeIfAbsent(p.doc,Candidate::new);c.lexical+=0.35;c.reasons.add("Approximate Arabic spelling");
            }
        }
        // Cross-language lane searches source glosses and transliterations; always labelled related.
        // Urdu uses Arabic script too: script detection must not disable the gloss lane.
        for(int d=0;d<docs.size();d++) {
            cancelled();
            String h=" "+hints.get(d)+" ";int n=0;
            for(String term:terms)if(term.length()>=2 && h.contains(" "+term+" "))n++;
            if(n>0 && (double)n/Math.max(1,terms.size())>=0.75) {
                Candidate c=found.computeIfAbsent(d,Candidate::new);c.hint=true;c.coverage=(double)n/terms.size();c.lexical+=n*0.4;
                c.reasons.add("Source word meanings / transliteration");
            }
        }
        // Rank fusion: scales from lexical and phrase lanes are never naively added.
        List<Candidate> lexical=new ArrayList<>(found.values());
        lexical.sort(Comparator.comparingDouble((Candidate c)->c.lexical).reversed().thenComparingInt(c->c.doc));
        for(int i=0;i<lexical.size();i++)if(lexical.get(i).lexical>0)lexical.get(i).fused+=1.0/(60+i+1);
        int phraseRank=0;
        for(int d=0;d<docs.size();d++) {
            Candidate c=found.get(d);if(c!=null&&(c.exact||c.tolerant))c.fused+=1.0/(60+(++phraseRank));
        }
        List<Candidate> accepted=new ArrayList<>();
        for(Candidate c:found.values()) {
            cancelled();
            String matchText=" "+(c.hint?hints.get(c.doc):tolerant.get(c.doc))+" ";
            boolean lostNegation=false;
            for(String term:terms)if(NEGATION.contains(term)&&!matchText.contains(" "+term+" ")){lostNegation=true;break;}
            if(lostNegation)continue;
            if(!c.hint && !c.exact && !c.tolerant) {
                Set<String> words=new HashSet<>(Arabic.tokens(tolerant.get(c.doc)));int covered=0;
                for(String term:terms) {
                    if(words.contains(term)){covered++;continue;}
                    if(term.length()>=4)for(String w:words)if(Arabic.editDistance(term,w,term.length()>=8?2:1)<=(term.length()>=8?2:1)){covered++;break;}
                }
                c.coverage=(double)covered/Math.max(1,terms.size());
                if(c.coverage<0.75)continue;
                if(c.reasons.isEmpty())c.reasons.add("Arabic words in this ayah");
            }
            accepted.add(c);
        }
        accepted.sort(Comparator.comparingInt((Candidate c)->c.exact?0:c.tolerant?1:2)
            .thenComparing(Comparator.comparingDouble((Candidate c)->c.fused).reversed())
            .thenComparing(Comparator.comparingDouble((Candidate c)->c.lexical).reversed()).thenComparingInt(c->c.doc));
        List<Result> results=new ArrayList<>();
        for(Candidate c:accepted.subList(0,Math.min(limit,accepted.size())))
            results.add(new Result(docs.get(c.doc).ayah,c.exact?Strength.STRONG_TEXT:Strength.RELATED,new ArrayList<>(c.reasons),c.fused));
        return new Response(query,arabic?"ARABIC":"GLOSS_OR_TRANSLITERATION",results,found.size(),System.nanoTime()-start);
    }
}
