package com.aaris.quran.core;

import java.util.*;

/** Indexed retrieval shared by Android and real-SQLite regression checks. */
public final class HadithSearchPlan {
    public static final int CANDIDATE_LIMIT=1200,MAX_ANCHORS=32;
    public static final String ORDER=" ORDER BY CASE h.collection_id WHEN 'bukhari' THEN 0 WHEN 'muslim' THEN 1 ELSE 2 END,h.collection_id,CAST(h.record_number AS INTEGER),h.record_number,h.id";
    public final String where;
    public final List<String> args;
    private HadithSearchPlan(String where,List<String> args){this.where=where;this.args=Collections.unmodifiableList(args);}
    public static HadithSearchPlan phrase(HadithQuery intent){
        List<String> terms=TextMatch.tokens(intent.text),args=new ArrayList<>();
        // FTS syntax never comes from the raw user input. Search-normalized tokens are quoted.
        args.add("\""+String.join(" ",terms).replace("\"","\"\"")+"\"");
        String where="h.id IN (SELECT hadith_id FROM hadith_fts WHERE hadith_fts MATCH ?)"+intent.scopeSql();
        intent.addScopeArgs(args);return new HadithSearchPlan(where,args);
    }
    public static HadithSearchPlan candidates(HadithQuery intent,Map<String,List<String>> repairs,Map<String,Double> weights){
        List<String> ranked=new ArrayList<>(new LinkedHashSet<>(TextMatch.tokens(intent.text)));
        ranked.sort(Comparator.comparingDouble((String t)->weights.getOrDefault(t,1.)).reversed().thenComparing(t->t));
        ranked=ranked.subList(0,Math.min(MAX_ANCHORS,ranked.size()));
        List<String> args=new ArrayList<>();Map<String,Double> anchors=new LinkedHashMap<>();
        for(String term:ranked){
            double weight=weights.getOrDefault(term,1.);anchors.merge(term,weight,Math::max);
            for(String repair:repairs.getOrDefault(term,Collections.emptyList()))anchors.merge(repair,weight*.65,Math::max);
        }
        StringBuilder score=new StringBuilder("CASE st.token");
        for(Map.Entry<String,Double> entry:anchors.entrySet()){
            score.append(" WHEN ? THEN ?");args.add(entry.getKey());args.add(Double.toString(entry.getValue()));
        }
        score.append(" ELSE 0 END");
        args.addAll(anchors.keySet());String marks=String.join(",",Collections.nCopies(anchors.size(),"?"));
        String scope=intent.scopeSql();intent.addScopeArgs(args);
        // Rank the compact inverted index first. Never read all 62k full narrations to rank them.
        String ids="SELECT st.hadith_rowid FROM search_token st JOIN hadith h ON h.rowid=st.hadith_rowid WHERE st.token IN ("+marks+")"+scope+
            " GROUP BY st.hadith_rowid ORDER BY sum("+score+") DESC,count(*) DESC,st.hadith_rowid LIMIT "+(CANDIDATE_LIMIT+1);
        // Placeholders occur in WHERE before ORDER BY.
        int scoreArgs=anchors.size()*2;
        List<String> ordered=new ArrayList<>(args.subList(scoreArgs,args.size()));ordered.addAll(args.subList(0,scoreArgs));
        return new HadithSearchPlan("h.rowid IN ("+ids+")",ordered);
    }
}
