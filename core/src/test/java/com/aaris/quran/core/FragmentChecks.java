package com.aaris.quran.core;

import java.util.*;
import java.util.concurrent.CancellationException;

/** Synthetic retrieval adversaries; none of this fixture text is bundled as Quran content. */
final class FragmentChecks {
    private static int checks;
    private static void check(boolean value,String message){checks++;if(!value)throw new AssertionError(message);}
    private static SearchEngine.Document doc(int number,String text){return new SearchEngine.Document(new Ayah(1,number,text,References.sha256(text),number),"");}
    static int run(){
        List<SearchEngine.Document> docs=Arrays.asList(doc(1,"شاهد النص الأول في السطر"),doc(2,"شاهد النص الثاني في الصفحة"),doc(3,"شاهد النص الأول في الموضع"));
        SearchEngine search=new SearchEngine(docs);String query="شاهد النص الأول شاهد النص الثاني";
        SearchEngine.Response response=search.search(query,10);FragmentSearch.Report report=response.fragments;
        check(response.results.isEmpty()&&response.gate.equals("FRAGMENTS_ONLY"),"Fragments cannot be promoted to full-query matches");
        check(report!=null&&report.fragments.size()==2&&report.matchedTokens==6&&report.unmatched.isEmpty(),"Both independently cited fragments are recoverable");
        check(report.fragments.get(0).totalOccurrences==2&&report.fragments.get(0).alternatives.size()==2,"Ambiguous origins stay separate");
        check(report.fragments.get(0).alternatives.get(0).ayah.id.equals("Q:1:1")&&report.fragments.get(1).alternatives.get(0).ayah.id.equals("Q:1:2"),"Each fragment retains its own citation");
        report=search.search("لا "+query,10).fragments;
        check(report!=null&&report.unmatched.size()==1&&report.unmatched.get(0).text.equals("لا"),"Unmatched negation is disclosed, not silently removed");
        report=search.search("😀 "+query,10).fragments;
        check(report!=null&&report.fragments.get(0).query.start==2,"Query spans use code points, not UTF-16 indexes");
        check(search.search("شاهد النص الأول",10).fragments==null,"Whole exact match suppresses fragment fallback");
        check(search.search("شاهد النص الاول",10).fragments==null,"Fragment matches do not silently fold hamza");
        check(search.search("شاهد النص",10).fragments==null,"Two common words do not trigger fragmentation");
        check(search.search("شاهد النص الأول إضافات مختلقة بعيدة جدا أخرى",10).fragments==null,"Mostly unsupported queries abstain from fragment suggestions");
        check(search.search("خبر غير موجود",Collections.singletonList(new SearchEngine.Query(query,SearchEngine.Origin.AI)),10).fragments==null,"AI expansion cannot be relabelled as an original-user fragment");
        check(search.search(query+"\nخبر آخر",10).fragments==null,"Explicit multi-query lines are not stitched together");
        SearchEngine overlap=new SearchEngine(Arrays.asList(doc(1,"أول ثاني ثالث رابع"),doc(2,"رابع خامس سادس")));
        report=overlap.search("أول ثاني ثالث رابع خامس سادس",10).fragments;
        check(report!=null&&report.matchedTokens==6&&report.fragments.size()==2,"Global segmentation avoids greedy overlap losing a recoverable fragment");
        check(report.fragments.get(0).query.end<=report.fragments.get(1).query.start,"Query tokens are never counted twice");
        List<SearchEngine.Document> shuffled=new ArrayList<>(docs);Collections.reverse(shuffled);
        FragmentSearch.Report reordered=new SearchEngine(shuffled).search(query,10).fragments;
        check(reordered.fragments.get(0).alternatives.get(0).ayah.id.equals("Q:1:1"),"Source order is deterministic across importer order");
        List<Ayah> repeated=new ArrayList<>();for(int i=1;i<=12;i++)repeated.add(doc(i,"شاهد النص الأول").ayah);
        report=new FragmentSearch(repeated).search("شاهد النص الأول مفقود");
        check(report!=null&&report.fragments.get(0).totalOccurrences==12&&report.fragments.get(0).alternatives.size()==4,"Repeated phrases retain total ambiguity while bounding visible alternatives");
        check(new FragmentSearch(repeated).search("شاهد ".repeat(33))==null,"Fragment work respects token budget");
        boolean cancelled=false;Thread.currentThread().interrupt();
        try{search.search(query,10);}catch(CancellationException expected){cancelled=true;}finally{Thread.interrupted();}
        check(cancelled,"Cancelled query stops before publishing fragment results");
        for(FragmentSearch.Fragment fragment:response.fragments.fragments)for(FragmentSearch.Hit hit:fragment.alternatives){
            String original=hit.ayah.arabic;
            check(original.substring(original.offsetByCodePoints(0,hit.source.start),original.offsetByCodePoints(0,hit.source.end)).equals(hit.source.text),"Evidence fragment is an exact original-source range");
        }
        return checks;
    }
}
