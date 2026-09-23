package com.aaris.quran.core;

import java.text.Normalizer;
import java.util.*;

/** Evidence of text overlap, not a probability of authenticity or a semantic verdict. */
public final class TextMatch {
    public enum Band { HIGH, MEDIUM, LOW }
    public final int matched,total,exact;
    public final double coverage,score;
    public final Band band;
    public final boolean accepted;
    private static final Set<String> NEGATION=new HashSet<>(Arrays.asList("لا","لم","لن","ليس","ليست","غير","دون","نہیں","نهيں","نہ","مت","नहीं","मत","बिना","no","not","never","without"));
    private static final Set<String> COMMON=new HashSet<>(Arrays.asList("wa","the","a","of","to","and","in","is","من","في","على","قال","و","عن","ان","هو","كي","में","के","है","का","और","से"));
    private TextMatch(int matched,int total,int exact,double weighted,double continuity,boolean allowed,boolean phrase){
        this.matched=matched;this.total=total;this.exact=exact;coverage=total==0?0:(double)matched/total;
        score=coverage*.65+weighted*.25+continuity*.06+(phrase?.04:0);
        band=coverage>=.85&&weighted>=.78?Band.HIGH:coverage>=.5&&weighted>=.4?Band.MEDIUM:Band.LOW;
        accepted=allowed&&matched>0&&(total==1||matched>=2&&coverage>=.18);
    }
    public static TextMatch exactReference(){return new TextMatch(1,1,1,1,1,true,true);}
    public static boolean negative(String term){return NEGATION.contains(term);}
    public static String normalize(String value){return Arabic.glossSearch(value==null?"":value.replace("’", "").replace("'", "").replaceAll("\\[\\d+\\]", " "));}
    public static List<String> tokens(String value){return Arabic.tokens(normalize(value));}
    public static TextMatch compare(List<String> query,List<String> words,Map<String,List<String>> alternatives,Map<String,Double> weights){
        Map<String,ArrayDeque<Integer>> positions=new HashMap<>();for(int i=0;i<words.size();i++)positions.computeIfAbsent(words.get(i),k->new ArrayDeque<>()).add(i);
        int[] match=new int[query.size()];boolean[] original=new boolean[query.size()];Arrays.fill(match,-1);int exact=0,count=0;double all=0,hit=0;boolean allowed=true;
        for(int q=0;q<query.size();q++){String term=query.get(q);all+=weight(term,weights);ArrayDeque<Integer> queue=positions.get(term);if(queue!=null&&!queue.isEmpty()){match[q]=queue.removeFirst();original[q]=true;exact++;}}
        for(int q=0;q<query.size();q++)if(match[q]<0&&!negative(query.get(q)))for(String candidate:alternatives.getOrDefault(query.get(q),Collections.emptyList())){ArrayDeque<Integer> queue=positions.get(candidate);if(queue!=null&&!queue.isEmpty()){match[q]=queue.removeFirst();break;}}
        int ordered=0,previous=-1;
        for(int q=0;q<query.size();q++){String term=query.get(q);if(match[q]>=0){count++;hit+=weight(term,weights)*(original[q]?1:.75);if(match[q]>previous)ordered++;previous=match[q];}else if(negative(term))allowed=false;}
        if(query.size()>1&&new HashSet<>(query).size()==1&&count<query.size())allowed=false;
        boolean phrase=!query.isEmpty()&&(" "+String.join(" ",words)+" ").contains(" "+String.join(" ",query)+" ");
        return new TextMatch(count,query.size(),exact,all==0?0:hit/all,phrase?1:count==0?0:(double)ordered/count,allowed,phrase);
    }
    private static double weight(String term,Map<String,Double> weights){return weights.getOrDefault(term,COMMON.contains(term)?.3:1.);}
    /** Adjacent transpositions, insertion/deletion and replacement; never repairs negation. */
    public static int distance(String a,String b,int limit){
        if(a.equals(b))return 0;if(negative(a)||negative(b)||Math.abs(a.length()-b.length())>limit)return limit+1;
        int[] prev=new int[b.length()+1],prev2=null;for(int j=0;j<=b.length();j++)prev[j]=j;
        for(int i=1;i<=a.length();i++){int[] next=new int[b.length()+1];next[0]=i;for(int j=1;j<=b.length();j++){
            next[j]=Math.min(Math.min(next[j-1]+1,prev[j]+1),prev[j-1]+(a.charAt(i-1)==b.charAt(j-1)?0:1));
            if(i>1&&j>1&&a.charAt(i-1)==b.charAt(j-2)&&a.charAt(i-2)==b.charAt(j-1))next[j]=Math.min(next[j],prev2[j-2]+1);
        }prev2=prev;prev=next;}return prev[b.length()];
    }
    /** A lossy retrieval shadow only; it is never displayed as translated scripture. */
    public static String phonetic(String value){
        String roman=devanagari(value);String s=Normalizer.normalize(roman,Normalizer.Form.NFD).replaceAll("\\p{M}+","").toLowerCase(Locale.ROOT);
        if(!s.matches("[a-z'’ -]+"))return "";
        return s.replace("kh","k").replace("gh","g").replace("dh","z").replace("th","s").replace("sh","s")
            .replace('q','k').replace('j','z').replace('w','v').replaceAll("[aeiou'’ -]","").replaceAll("(.)\\1+","$1");
    }
    public static List<String> phoneticTokens(String value){
        List<String> out=new ArrayList<>();for(String token:tokens(value)){
            if(token.startsWith("wa")&&token.length()>5)token=token.substring(2);
            String key=phonetic(token);if(key.length()>=2)out.add(key);
        }return out;
    }
    private static String devanagari(String value){
        StringBuilder out=new StringBuilder();String chars="कखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसहज़फ़क़ग़";
        String[] sounds={"k","kh","g","gh","n","ch","ch","j","j","n","t","t","d","d","n","t","th","d","dh","n","p","f","b","b","m","y","r","l","v","sh","sh","s","h"};
        for(int cp:value.codePoints().toArray()){int index=chars.indexOf(cp);if(index>=0&&index<sounds.length)out.append(sounds[index]);else if(cp>=0x900&&cp<=0x97f){if(cp==0x902||cp==0x903)out.append('n');}else out.appendCodePoint(cp);}
        return out.toString();
    }
}
