package com.aaris.quran.core;

import java.util.*;

/** Regression queries for requested full-over-partial ranking and typo tolerance. */
final class RankingChecks {
    static int run(){
        List<SearchEngine.Document> documents=new ArrayList<>();
        String[] sources={"الذين يؤمنون بالغيب ويقيمون الصلاة","الذين يؤمنون بالغيب","الذين يؤمنون"};
        for(int i=0;i<sources.length;i++)documents.add(new SearchEngine.Document(new Ayah(2,i+1,sources[i],References.sha256(sources[i]),i+1),i==0?"actions depend on intentions alladhina yuminuna bilghaybi wayuqimuna alsalata":""));
        SearchEngine search=new SearchEngine(documents);
        List<SearchEngine.Result> results=search.search(sources[0],10).results;
        require(results.size()==3,"Partial matches remain visible");
        require(results.get(0).ayah.number==1&&results.get(1).ayah.number==2&&results.get(2).ayah.number==3,"More matching query words rank first");
        require(results.get(0).match.band==TextMatch.Band.HIGH,"Complete phrase is high text match");
        require(search.search("actions depend on intensions",10).results.get(0).ayah.number==1,"Translation typo retrieves original record");
        require(TextMatch.distance("word","wrod",1)==1,"Adjacent keyboard transposition");
        require(!TextMatch.compare(TextMatch.tokens("not present here"),TextMatch.tokens("present here"),Collections.emptyMap(),Collections.emptyMap()).accepted,"Unmatched negation does not disappear");
        String paragraph="distinctive ".repeat(90)+"anchor";
        SearchEngine longSearch=new SearchEngine(Arrays.asList(new SearchEngine.Document(new Ayah(1,1,"اختبار","x",1),paragraph)));
        require(!longSearch.search(paragraph,10).results.isEmpty(),"Paragraph over the old 512-character limit is searched whole");
        require(longSearch.search("x".repeat(16385),10).intent.equals("QUERY_LIMIT"),"Oversized input is explicitly refused");
        TextMatch one=TextMatch.compare(TextMatch.tokens("word word"),TextMatch.tokens("word"),Collections.emptyMap(),Collections.emptyMap());
        require(!one.accepted,"One source occurrence cannot satisfy repeated query words");
        SearchEngine paragraphs=new SearchEngine(Arrays.asList(
            new SearchEngine.Document(new Ayah(1,1,"الأول","a",1),"bright morning"),
            new SearchEngine.Document(new Ayah(1,2,"الثاني","b",2),"bright morning silver moon")));
        SearchEngine.Response pasted=paragraphs.search("bright morning\nsilver moon",10);
        require(pasted.variants.size()==1&&pasted.results.get(0).ayah.number==2&&pasted.results.get(0).match.total==4,"Pasted paragraph ranks by all lines together");
        List<String> query=new ArrayList<>();Map<String,Double> weights=new HashMap<>();
        for(int i=1;i<=10;i++){String w="w"+i;query.add(w);weights.put(w,i<=2?1.:i==10?20.:78./7);}
        List<String> reverseNine=new ArrayList<>(query.subList(0,9));Collections.reverse(reverseNine);
        TextMatch high=TextMatch.compare(query,reverseNine,Collections.emptyMap(),weights);
        TextMatch medium=TextMatch.compare(query,query.subList(2,10),Collections.emptyMap(),weights);
        require(high.band==TextMatch.Band.HIGH&&medium.band==TextMatch.Band.MEDIUM&&medium.score>high.score,
            "Regression fixture has a higher numeric MEDIUM score");
        require(TextMatch.compareRank(high,medium)<0,"HIGH always outranks MEDIUM, regardless of raw score");
        TextMatch low=TextMatch.compare(query,query.subList(2,5),Collections.emptyMap(),weights);
        require(low.band==TextMatch.Band.LOW&&TextMatch.compareRank(medium,low)<0,"MEDIUM always outranks LOW");
        List<String> reordered=new ArrayList<>(query);Collections.swap(reordered,0,1);
        List<String> spaced=new ArrayList<>(query);spaced.add(1,"spacer");
        TextMatch nearA=TextMatch.compare(query,reordered,Collections.emptyMap(),Collections.emptyMap());
        TextMatch nearB=TextMatch.compare(query,spaced,Collections.emptyMap(),Collections.emptyMap());
        require(nearA.score!=nearB.score&&TextMatch.compareHadith(nearA,"bukhari",nearB,"muslim")<0,
            "Bukhari preference works for comparable unequal scores");
        require(TextMatch.compareHadith(nearA,"muslim",nearB,"nasai")<0,"Muslim precedes other sources at comparable relevance");
        require(TextMatch.compareHadith(medium,"bukhari",high,"muslim")>0,"Source preference never crosses bands");
        require(TextMatch.compareHadith(low,"bukhari",nearA,"ibnmajah")>0,"Weak Bukhari overlap cannot outrank stronger evidence");
        List<TextMatch> matches=Arrays.asList(high,medium,low,nearA,nearB);
        String[] sourcesForRank={"bukhari","muslim","nasai"};
        for(TextMatch x:matches)for(TextMatch y:matches)for(TextMatch z:matches)
            for(String sx:sourcesForRank)for(String sy:sourcesForRank)for(String sz:sourcesForRank){
                int xy=TextMatch.compareHadith(x,sx,y,sy),yz=TextMatch.compareHadith(y,sy,z,sz);
                if(xy<=0&&yz<=0)require(TextMatch.compareHadith(x,sx,z,sz)<=0,"Near-equal source order remains transitive");
            }
        require(nearA.explanation().contains("spelling repairs"),"Match explanations expose transformations");
        return 19;
    }
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
}
