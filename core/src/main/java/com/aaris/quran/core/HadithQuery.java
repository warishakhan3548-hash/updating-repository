package com.aaris.quran.core;

import java.util.*;

/** Collection intent and edition-aware reference lookup, independent of UI and SQLite. */
public final class HadithQuery {
    private static final Map<String,String> ALIASES=new LinkedHashMap<>();
    static {
        aliases("bukhari","sahih al bukhari","sahih bukhari","sahi bukhari","bukhari",
            "صحيح البخاري","صحيح بخاري","صحیح بخاری","البخاري","بخاري",
            "सहीह बुखारी","सही बुखारी","साहिह बुखारी","बुखारी");
        aliases("muslim","sahih muslim","sahi muslim","muslim","صحيح مسلم","صحیح مسلم",
            "مسلم","सहीह मुस्लिम","सही मुस्लिम","साहिह मुस्लिम","मुस्लिम");
        aliases("tirmidhi","jami at tirmidhi","jami tirmidhi","tirmidhi","tirmizi",
            "جامع الترمذي","سنن الترمذي","الترمذي","ترمذي","ترمذی","तिर्मिजी","तिर्मिधि");
        aliases("abudawud","sunan abi dawud","sunan abu dawud","abu dawud","abu dawood","abudawud",
            "سنن ابي داود","ابي داود","ابو داود","अबू दाऊद","अबू दाउद");
        aliases("nasai","sunan an nasai","sunan nasai","an nasai","nasai",
            "سنن النسائي","النسائي","نسائي","نسائی","नसाई","नसाइ");
        aliases("ibnmajah","sunan ibn majah","ibn majah","ibn maja","ibnmajah",
            "سنن ابن ماجه","ابن ماجه","ابن ماجہ","इब्न माजा","इब्न माजह");
        aliases("malik","muwatta malik","muwatta imam malik","muwatta","موطا مالك","موطأ مالك","موطا","मुवत्ता मालिक");
        aliases("ahmad","musnad ahmad","musnad ahmed","ahmad","مسند احمد","مسند أحمد","मुस्नद अहमद");
        aliases("darimi","sunan ad darimi","sunan darimi","darimi","سنن الدارمي","الدارمي","سنن دارمی","दारिमी");
    }
    public final String raw,collectionId,text,number;
    private HadithQuery(String raw,String collection,String text,String number){
        this.raw=raw;collectionId=collection;this.text=text;this.number=number;
    }
    private static void aliases(String id,String... names){
        for(String name:names)ALIASES.put(TextMatch.normalize(name),id);
    }
    public static HadithQuery parse(String value){return parse(value,Collections.emptyMap());}
    /** Installed names supplement known multilingual aliases, so new packs remain searchable. */
    public static HadithQuery parse(String value,Map<String,String> installedAliases){
        String raw=value==null?"":value.trim(),query=TextMatch.normalize(raw);
        Map<String,String> aliases=new LinkedHashMap<>(ALIASES);
        for(Map.Entry<String,String> entry:installedAliases.entrySet())
            aliases.put(TextMatch.normalize(entry.getKey()),entry.getValue());
        String best=null,id=null;
        for(Map.Entry<String,String> entry:aliases.entrySet()){
            String alias=entry.getKey();if(alias.isEmpty())continue;
            if(query.equals(alias)||query.startsWith(alias+" ")||
                query.endsWith(" "+alias)&&reference(query.substring(0,query.length()-alias.length()).trim())!=null){
                if(best==null||alias.length()>best.length()){best=alias;id=entry.getValue();}
            }
        }
        if(best!=null)query=query.equals(best)?"":query.startsWith(best+" ")?
            query.substring(best.length()).trim():query.substring(0,query.length()-best.length()).trim();
        String number=reference(query);
        return new HadithQuery(raw,id,number==null?query:"",number);
    }
    private static String reference(String value){
        String q=value.replaceFirst("^(?:(?:hadith|hadees|hadeeth|हदीस|हदीथ|حديث|حدیث)\\s+)?(?:(?:number|no|नंबर|नम्बर|نمبر|رقم)\\s+)?","");
        if(q.matches("[0-9](?:\\s+[0-9]){1,7}"))q=q.replace(" ","");
        if(!q.matches("[0-9]{1,8}[a-z]?"))return null;
        return q.replaceFirst("^0+(?!$|[a-z]$)","");
    }
    public boolean isReference(){return number!=null;}
    public boolean isHadithIntent(){return collectionId!=null||number!=null||raw.startsWith("H:");}
    /** Bare 556 includes 556a/556b; an explicit 556a remains exact. Never includes 5560. */
    public List<String> referenceValues(){
        if(number==null)return Collections.emptyList();
        List<String> values=new ArrayList<>();values.add(number);
        if(number.matches("[0-9]+"))for(char c='a';c<='z';c++)values.add(number+c);
        return values;
    }
    public String scopeLabel(){return collectionId==null?"All Hadith collections":collectionId;}
}
