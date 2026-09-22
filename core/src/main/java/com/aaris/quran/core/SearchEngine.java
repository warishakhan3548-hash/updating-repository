package com.aaris.quran.core;

import java.util.*;
import java.util.regex.*;

/** Deterministic bounded retrieval. Scores describe text relevance, never religious authority. */
public final class SearchEngine {
    public static final String VERSION = "lexical-1";
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
    public SearchEngine(List<Document> documents) {
        docs=Collections.unmodifiableList(new ArrayList<>(documents));lengths=new int[docs.size()];
        long words=0;
        for(int d=0;d<docs.size();d++) {
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
    }
    public Response search(String input,int limit) {
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
            if(Thread.currentThread().isInterrupted()) return new Response(query,"CANCELLED",Collections.emptyList(),0,System.nanoTime()-start);
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
            for(String candidate:new TreeSet<>(postings.keySet())) {
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
        if(!arabic)for(int d=0;d<docs.size();d++) {
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
