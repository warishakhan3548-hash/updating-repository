package com.aaris.quran.core;

import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** Reference intent, normalization interoperability and actual-corpus text ranking checks. */
public final class SearchIntentChecks {
    private static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
    private static String encode(String s){return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));}
    private static String decode(String s){return new String(Base64.getDecoder().decode(s),StandardCharsets.UTF_8);}
    public static void main(String[] args)throws Exception{
        if(args.length>0&&args[0].equals("lookup")){
            HadithQuery.Lookup lookup=HadithQuery.parse(args[1]).lookup();
            System.out.println(encode(lookup.where));for(String value:lookup.args)System.out.println(encode(value));
            return;
        }
        if(args.length>0&&args[0].equals("phrase")){
            HadithSearchPlan plan=HadithSearchPlan.phrase(HadithQuery.parse(args[1]));
            System.out.println(encode(plan.where));for(String value:plan.args)System.out.println(encode(value));return;
        }
        if(args.length>0&&args[0].equals("candidates")){
            List<String> lines=Files.readAllLines(Paths.get(args[1]),StandardCharsets.UTF_8);
            HadithQuery intent=HadithQuery.parse(decode(lines.get(0)));Map<String,Double> weights=new LinkedHashMap<>();Map<String,List<String>> repairs=new LinkedHashMap<>();
            for(String line:lines.subList(1,lines.size())){
                String[] row=line.split("\\t");String term=decode(row[0]);weights.put(term,Double.parseDouble(row[1]));
                repairs.put(term,row.length>2?Arrays.asList(decode(row[2]).split(" ")):Collections.emptyList());
            }
            HadithSearchPlan plan=HadithSearchPlan.candidates(intent,repairs,weights);
            System.out.println(encode(plan.where));for(String value:plan.args)System.out.println(encode(value));return;
        }
        if(args.length>0&&args[0].equals("tokens")){
            for(String line:Files.readAllLines(Paths.get(args[1]),StandardCharsets.UTF_8))
                System.out.println(encode(String.join(" ",TextMatch.tokens(decode(line)))));
            return;
        }
        if(args.length>0&&args[0].equals("rank")){
            List<String> lines=Files.readAllLines(Paths.get(args[1]),StandardCharsets.UTF_8);
            String[] heading=lines.get(0).split("\t");List<String> query=TextMatch.tokens(decode(heading[0]));
            String wanted=heading[1];List<String> ids=new ArrayList<>();Map<String,TextMatch> matches=new HashMap<>();
            for(String line:lines.subList(1,lines.size())){
                String[] row=line.split("\t");TextMatch match=TextMatch.compare(query,TextMatch.tokens(decode(row[1])),Collections.emptyMap(),Collections.emptyMap());
                if(match.accepted){ids.add(row[0]);matches.put(row[0],match);}
            }
            ids.sort((a,b)->{int c=TextMatch.compareRank(matches.get(a),matches.get(b));return c!=0?c:a.compareTo(b);});
            check(ids.contains(wanted),"Known Arabic hadith absent from candidates/ranking");
            check(matches.get(wanted).band==TextMatch.Band.HIGH,"Exact text must be a high match");
            check(ids.indexOf(wanted)<10,"Known source should rank in top ten: "+ids.indexOf(wanted));
            System.out.println("Arabic corpus query: PASS; expected rank="+(ids.indexOf(wanted)+1)+", candidates="+(lines.size()-1));
            return;
        }
        String[][] cases={
            {"Sahih Bukhari 556","bukhari","556"},{"sahih al-Bukhari hadith number 556","bukhari","556"},
            {"सही बुखारी ५५६","bukhari","556"},{"صَحِيح الْبُخَارِي ٥٥٦","bukhari","556"},
            {"صحیح بخاری ۵۵۶","bukhari","556"},{"Sahih Muslim hadith no. 5556","muslim","5556"},
            {"सही मुस्लिम 5 5 5 6","muslim","5556"},{"556 Sahih Muslim","muslim","556"},
            {"Bukhari:556a","bukhari","556a"},{"५ ५ ६","","556"},{"556","","556"},
            {"Sunan Abu Dawud 00556","abudawud","556"},{"Jami at-Tirmidhi 1","tirmidhi","1"}
            ,{"sahih bhukhari 556","bukhari","556"},{"bukahri556","bukhari","556"},
            {"muslem 556","muslim","556"},{"सही भुखारी ५५६","bukhari","556"},
            {"सहीह बुखारि ५५६","bukhari","556"},{"सही bhukhari 556","bukhari","556"},
            {"صحيح البخري ٥٥٦","bukhari","556"},{"صحیح بخری ۵۵۶","bukhari","556"},
            {"556 bukahri","bukhari","556"},{"abu dawod 556","abudawud","556"}
        };
        for(String[] c:cases){HadithQuery q=HadithQuery.parse(c[0]);check(Objects.equals(q.collectionId,c[1].isEmpty()?null:c[1])&&c[2].equals(q.number),"Reference intent: "+c[0]);}
        HadithQuery q=HadithQuery.parse("Bukhari إنما الأعمال بالنيات");
        check(q.collectionId.equals("bukhari")&&q.number==null&&q.text.equals("انما الاعمال بالنيات"),"Collection text intent");
        check(HadithQuery.parse("55 6").number==null,"Do not concatenate ambiguous groups of numbers");
        check(HadithQuery.parse("556").referenceValues().contains("556a"),"Reference suffix family");
        check(!HadithQuery.parse("556").referenceValues().contains("5560"),"Number family boundary");
        check(HadithQuery.parse("556a").referenceValues().size()==1,"Explicit suffix stays exact");
        check(HadithQuery.parse("2:255").number==null,"Quran coordinate is not a Hadith number");
        check(HadithQuery.parse("bhukhari").isCollectionBrowse(),"Typo book browsing");
        for(String value:new String[]{"sahih","sahi","صحيح","सही"}){
            HadithQuery title=HadithQuery.parse(value);check(title.sahihCollections&&title.isCollectionBrowse(),"Sahih title browsing: "+value);
            check(!UnifiedQuery.parse(value,UnifiedQuery.ALL).quran,"Collection titles must not turn into Quran pronunciation guesses");
        }
        check(HadithQuery.parse("sahih 556").sahihCollections,"Ambiguous Sahih reference searches both collections");
        check(!HadithQuery.parse("حدثنا قتيبة بن سعيد حدثنا").isHadithIntent(),"Narration text is not a fuzzy collection title");
        check(!HadithQuery.parse("قال مسلم حدثنا").isHadithIntent(),"Names within prose do not change the scope");
        for(String value:new String[]{"2:255","٢:٢٥٥","Quran 2:255","कुरान २:२५५"}){
            UnifiedQuery u=UnifiedQuery.parse(value,UnifiedQuery.ALL);check(u.quran&&!u.hadith,"Quran routing: "+value);
        }
        for(String value:new String[]{"556","Sahih Muslim 5556","صحيح البخاري 1","h:bukhari:1:1"}){
            UnifiedQuery u=UnifiedQuery.parse(value,UnifiedQuery.ALL);check(!u.quran&&u.hadith,"Hadith routing: "+value);
        }
        UnifiedQuery both=UnifiedQuery.parse("إِنَّمَا الْأَعْمَالُ",UnifiedQuery.ALL);
        check(both.quran&&both.hadith,"Arabic text searches both corpora");
        check(!UnifiedQuery.parse("الاعمال",UnifiedQuery.HADITH).quran,"Explicit Hadith filter");
        check(TextMatch.normalize("إِنَّمَا الأَعْمَالُ بِالنِّيَّاتِ").equals("انما الاعمال بالنيات"),"Harakat normalization");
        check(TextMatch.normalize("ﻻ\u200f تَقْبَلُ").equals("لا تقبل"),"Copied shaping and bidi controls");
        check(TextMatch.normalize("٥۵५").equals("555"),"Unicode digits");
        check(!TextMatch.normalize("की").equals(TextMatch.normalize("क")),"Preserve Hindi vowel signs");
        check(RecitationAddress.globalNumber(new Ayah(1,1,"","",0))==1,"First ayah audio");
        check(RecitationAddress.globalNumber(new Ayah(1,3,"","",2))==3,"Third ayah audio");
        check(RecitationAddress.globalNumber(new Ayah(2,1,"","",7))==8,"Surah boundary audio");
        check(RecitationAddress.globalNumber(new Ayah(114,6,"","",6235))==6236,"Last ayah audio");
        boolean rejected=false;try{RecitationAddress.globalNumber(new Ayah(1,3,"","",1));}catch(IllegalArgumentException expected){rejected=true;}
        check(rejected,"Mismatched identity must fail, not play another ayah");
        System.out.println("Reference, corpus routing, normalization and audio boundary regressions: PASS");
    }
}
