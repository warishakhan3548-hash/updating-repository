package com.aaris.quran.core;

import java.util.*;
import java.util.concurrent.CancellationException;

/** Bounded exact fragment retrieval. A set of excerpts never verifies a combined quotation. */
public final class FragmentSearch {
    public static final int MIN_WORDS=3,MAX_WORDS=32,MAX_FRAGMENTS=4,MAX_ALTERNATIVES=4;
    public static final class Hit {
        public final Ayah ayah;
        public final SourceText.Range source;
        private Hit(Ayah ayah,SourceText.Range source){this.ayah=ayah;this.source=source;}
    }
    public static final class Fragment {
        public final SourceText.Range query;
        public final List<Hit> alternatives;
        public final int totalOccurrences;
        private Fragment(SourceText query,Bucket b) {
            this.query=query.range(b.start,b.end);alternatives=Collections.unmodifiableList(new ArrayList<>(b.hits));
            totalOccurrences=b.occurrences;
        }
    }
    public static final class Report {
        public final String query;
        public final List<Fragment> fragments;
        public final List<SourceText.Range> unmatched;
        public final int matchedTokens,totalTokens;
        private Report(SourceText query,Plan plan) {
            this.query=query.original;totalTokens=query.tokens.size();matchedTokens=plan.covered;
            List<Fragment> fragments=new ArrayList<>();List<SourceText.Range> gaps=new ArrayList<>();int next=0;
            for(Bucket b:plan.parts){if(next<b.start)gaps.add(query.range(next,b.start));fragments.add(new Fragment(query,b));next=b.end;}
            if(next<totalTokens)gaps.add(query.range(next,totalTokens));
            this.fragments=Collections.unmodifiableList(fragments);unmatched=Collections.unmodifiableList(gaps);
        }
    }
    private static final class Position {
        final int doc,word;
        Position(int doc,int word){this.doc=doc;this.word=word;}
    }
    private static final class Bucket {
        final int start,end;
        int occurrences;
        final List<Hit> hits=new ArrayList<>();
        Bucket(int start,int end){this.start=start;this.end=end;}
    }
    private static final class Plan {
        final int covered;
        final double ambiguity;
        final List<Bucket> parts;
        Plan(){covered=0;ambiguity=0;parts=Collections.emptyList();}
        Plan(Bucket first,Plan tail){
            covered=first.end-first.start+tail.covered;ambiguity=Math.log1p(first.occurrences)+tail.ambiguity;
            parts=new ArrayList<>();parts.add(first);parts.addAll(tail.parts);
        }
        boolean betterThan(Plan other){
            if(covered!=other.covered)return covered>other.covered;
            if(parts.size()!=other.parts.size())return parts.size()<other.parts.size();
            return ambiguity<other.ambiguity;
        }
    }
    private final List<Ayah> ayahs;
    private final List<SourceText> texts=new ArrayList<>();
    private final Map<String,List<Position>> postings=new HashMap<>();
    public FragmentSearch(List<Ayah> ayahs) {
        List<Ayah> sorted=new ArrayList<>(ayahs);sorted.sort(Comparator.comparingInt((Ayah a)->a.surah).thenComparingInt(a->a.number));
        this.ayahs=Collections.unmodifiableList(sorted);
        for(int d=0;d<sorted.size();d++){
            cancelled();SourceText text=new SourceText(sorted.get(d).arabic);texts.add(text);
            for(int w=0;w<text.tokens.size();w++)postings.computeIfAbsent(text.tokens.get(w).key,k->new ArrayList<>()).add(new Position(d,w));
        }
    }
    /** Single original Arabic query only; no inferred corrections, glosses or AI variants. */
    public Report search(String original) {
        if(original==null||original.length()>512)return null;
        SourceText query=new SourceText(original);int n=query.tokens.size();
        if(n<MIN_WORDS||n>MAX_WORDS)return null;
        for(SourceText.Token token:query.tokens)if(!Arabic.hasArabic(token.key))return null;
        Bucket[][] buckets=new Bucket[n][n+1];
        for(int start=0;start<=n-MIN_WORDS;start++){
            for(Position at:postings.getOrDefault(query.tokens.get(start).key,Collections.emptyList())){
                cancelled();SourceText source=texts.get(at.doc);int length=0;
                while(start+length<n&&at.word+length<source.tokens.size()&&
                    query.tokens.get(start+length).key.equals(source.tokens.get(at.word+length).key))length++;
                for(int count=MIN_WORDS;count<=length;count++){
                    int end=start+count;Bucket bucket=buckets[start][end];
                    if(bucket==null)buckets[start][end]=bucket=new Bucket(start,end);
                    bucket.occurrences++;
                    if(bucket.hits.size()<MAX_ALTERNATIVES)bucket.hits.add(new Hit(ayahs.get(at.doc),source.range(at.word,at.word+count)));
                }
            }
        }
        // Optimize nonoverlapping coverage, then fewer excerpts, then less ambiguity.
        // Skipped words stay visible; the planner cannot drop them to make a quote pass.
        Plan[][] plans=new Plan[n+1][MAX_FRAGMENTS+1];
        for(int budget=0;budget<=MAX_FRAGMENTS;budget++)plans[n][budget]=new Plan();
        for(int start=n-1;start>=0;start--){
            plans[start][0]=new Plan();
            for(int budget=1;budget<=MAX_FRAGMENTS;budget++){
                Plan best=plans[start+1][budget];
                for(int end=n;end>=start+MIN_WORDS;end--)if(buckets[start][end]!=null){
                    Plan candidate=new Plan(buckets[start][end],plans[end][budget-1]);
                    if(candidate.betterThan(best))best=candidate;
                }
                plans[start][budget]=best;
            }
        }
        Plan best=plans[0][MAX_FRAGMENTS];
        // A few common words in a mostly unrelated paragraph should not trigger this aid.
        return best.covered>=MIN_WORDS&&best.covered*2>=n?new Report(query,best):null;
    }
    private static void cancelled(){if(Thread.currentThread().isInterrupted())throw new CancellationException();}
}
