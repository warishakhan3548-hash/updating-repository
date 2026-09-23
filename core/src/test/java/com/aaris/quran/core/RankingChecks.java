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
        return 10;
    }
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
}
