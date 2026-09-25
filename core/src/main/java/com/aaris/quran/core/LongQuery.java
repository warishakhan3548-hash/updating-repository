package com.aaris.quran.core;

import java.util.*;

/**
 * Bounded planner for pasted paragraphs and very long remembered text.
 *
 * The source string is never treated as one giant fuzzy query. Instead, deterministic overlapping
 * windows are sampled across the full span, compacted to meaning-bearing tokens, then the strongest
 * and coverage windows are returned for normal indexed retrieval. Memory and downstream SQL stay
 * bounded even when the pasted text is very large.
 */
public final class LongQuery {
    private LongQuery() {}

    public static final int SHORT_CHARS=2048;
    public static final int SHORT_TOKENS=64;
    private static final int WINDOW_CHARS=720;
    private static final int WINDOW_STEP=560;
    private static final int MAX_WINDOWS=8;
    private static final int MAX_WINDOW_TERMS=28;
    private static final int MAX_EVALUATED_WINDOWS=256;

    public static final class Plan {
        public final List<String> windows;
        public final boolean segmented;
        public final int sourceChars,sourceWindows;
        Plan(List<String> windows,boolean segmented,int sourceChars,int sourceWindows){
            this.windows=Collections.unmodifiableList(new ArrayList<>(windows));
            this.segmented=segmented;this.sourceChars=sourceChars;this.sourceWindows=sourceWindows;
        }
    }
    private static final class Scored {
        final int index,start,score;final String query;
        Scored(int index,int start,int score,String query){this.index=index;this.start=start;this.score=score;this.query=query;}
    }

    public static Plan plan(String input){
        String raw=input==null?"":input.trim();
        if(raw.isEmpty())return new Plan(Collections.emptyList(),false,0,0);
        if(raw.length()<=SHORT_CHARS){
            List<String> tokens=TextMatch.tokens(raw);
            if(tokens.size()<=SHORT_TOKENS)
                return new Plan(Collections.singletonList(raw.replaceAll("\\s+"," ").trim()),false,raw.length(),1);
        }

        int total=Math.max(1,1+(Math.max(0,raw.length()-1))/WINDOW_STEP);
        int evaluationStride=Math.max(1,(int)Math.ceil(total/(double)MAX_EVALUATED_WINDOWS));
        PriorityQueue<Scored> strongest=new PriorityQueue<>(
            Comparator.comparingInt((Scored s)->s.score).thenComparingInt(s->-s.index));
        Map<Integer,Scored> coverage=new LinkedHashMap<>();
        int[] targets={0,Math.max(0,total/3),Math.max(0,(total*2)/3),Math.max(0,total-1)};

        for(int index=0;index<total;index++){
            boolean coverageTarget=false;
            for(int target:targets)if(Math.abs(index-target)<=Math.max(1,evaluationStride/2)){coverageTarget=true;break;}
            if(index%evaluationStride!=0&&!coverageTarget)continue;
            int start=Math.min(raw.length()-1,index*WINDOW_STEP);
            int end=Math.min(raw.length(),start+WINDOW_CHARS);
            String chunk=raw.substring(start,end);
            Scored candidate=compact(index,start,chunk);
            if(candidate==null)continue;

            if(strongest.size()<MAX_WINDOWS)strongest.add(candidate);
            else if(compareStrength(candidate,strongest.peek())>0){strongest.poll();strongest.add(candidate);}

            for(int target:targets){
                Scored previous=coverage.get(target);
                if(previous==null||Math.abs(candidate.index-target)<Math.abs(previous.index-target)||
                    Math.abs(candidate.index-target)==Math.abs(previous.index-target)&&candidate.score>previous.score)
                    coverage.put(target,candidate);
            }
        }

        LinkedHashMap<String,Scored> chosen=new LinkedHashMap<>();
        List<Scored> ranked=new ArrayList<>(strongest);
        ranked.sort((a,b)->{
            int c=Integer.compare(b.score,a.score);return c!=0?c:Integer.compare(a.index,b.index);
        });
        // Reserve coverage first so a long paste cannot lose its beginning/middle/end entirely.
        for(Scored s:coverage.values())if(s!=null)chosen.putIfAbsent(s.query,s);
        for(Scored s:ranked)if(chosen.size()<MAX_WINDOWS)chosen.putIfAbsent(s.query,s);

        List<Scored> finalWindows=new ArrayList<>(chosen.values());
        finalWindows.sort(Comparator.comparingInt(s->s.index));
        List<String> out=new ArrayList<>();
        for(Scored s:finalWindows)if(!s.query.isEmpty())out.add(s.query);
        if(out.isEmpty()){
            String fallback=raw.substring(0,Math.min(raw.length(),SHORT_CHARS)).replaceAll("\\s+"," ").trim();
            if(!fallback.isEmpty())out.add(fallback);
        }
        return new Plan(out,true,raw.length(),total);
    }

    private static int compareStrength(Scored a,Scored b){
        int c=Integer.compare(a.score,b.score);return c!=0?c:Integer.compare(b.index,a.index);
    }

    private static Scored compact(int index,int start,String chunk){
        List<String> rawTokens=TextMatch.tokens(chunk);
        if(rawTokens.isEmpty())return null;
        List<String> focused=MeaningSearch.focusTokens(rawTokens);
        List<String> base=focused.size()>=2?focused:rawTokens;
        LinkedHashMap<String,Integer> first=new LinkedHashMap<>();
        for(int i=0;i<base.size();i++)first.putIfAbsent(base.get(i),i);
        List<String> unique=new ArrayList<>(first.keySet());
        unique.sort((a,b)->{
            int c=Integer.compare(importance(b),importance(a));
            return c!=0?c:Integer.compare(first.get(a),first.get(b));
        });
        if(unique.size()>MAX_WINDOW_TERMS)unique=new ArrayList<>(unique.subList(0,MAX_WINDOW_TERMS));
        unique.sort(Comparator.comparingInt(first::get));

        int score=0;
        for(String token:unique)score+=importance(token);
        score+=Math.min(20,unique.size());
        return new Scored(index,start,score,String.join(" ",unique));
    }

    private static int importance(String token){
        if(token==null||token.isEmpty())return 0;
        int score=1;
        if(TextMatch.negative(token))score+=8;
        if(!MeaningSearch.alternatives(token).isEmpty())score+=7;
        boolean digit=false;
        for(int i=0;i<token.length();i++)if(Character.isDigit(token.charAt(i))){digit=true;break;}
        if(digit)score+=5;
        int cp=token.codePointCount(0,token.length());
        if(cp>=7)score+=4;else if(cp>=5)score+=3;else if(cp>=3)score+=1;
        if(Arabic.hasArabic(token))score+=1;
        return score;
    }
}
