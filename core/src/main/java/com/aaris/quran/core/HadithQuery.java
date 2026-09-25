package com.aaris.quran.core;

import java.util.*;

/** Collection intent and edition-aware reference lookup, independent of UI and SQLite. */
public final class HadithQuery {
    private static final Map<String,String> ALIASES=new LinkedHashMap<>();
    private static final Set<String> AMBIGUOUS_PREFIX_COLLECTIONS=
        new HashSet<>(Arrays.asList("muslim","malik","ahmad"));
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
        aliases("malik","muwatta malik","muwatta imam malik","muwatta","موطا مالك","موطأ مالك","موطا","مالك","मुवत्ता मालिक","मालिक");
        aliases("ahmad","musnad ahmad","musnad ahmed","ahmad","مسند احمد","مسند أحمد","मुस्नद अहमद");
        aliases("darimi","sunan ad darimi","sunan darimi","darimi","سنن الدارمي","الدارمي","سنن دارمی","दारिमी");
    }
    public final String raw,collectionId,text,number;
    public final boolean corrected,sahihCollections;
    private HadithQuery(String raw,String collection,String text,String number){
        this(raw,collection,text,number,false,false);
    }
    private HadithQuery(String raw,String collection,String text,String number,boolean corrected,boolean sahih){
        this.raw=raw;collectionId=collection;this.text=text;this.number=number;this.corrected=corrected;sahihCollections=sahih;
    }
    private static void aliases(String id,String... names){
        ALIASES.put(TextMatch.normalize(id),id);
        for(String name:names)ALIASES.put(TextMatch.normalize(name),id);
    }
    public static HadithQuery parse(String value){return parse(value,Collections.emptyMap());}
    /** Installed names supplement known multilingual aliases, so new packs remain searchable. */
    public static HadithQuery parse(String value,Map<String,String> installedAliases){
        String raw=value==null?"":value.trim();if(raw.length()>2&&(raw.charAt(0)=='h'||raw.charAt(0)=='H')&&raw.charAt(1)==':')raw="H:"+raw.substring(2);String query=TextMatch.normalize(raw);
        // Keyboard input often joins the title and number: Bukhari556 / बुखारी५५६.
        query=query.replaceAll("(?<=[\\p{L}\\p{M}])(?=[0-9])", " ");
        Map<String,String> aliases=new LinkedHashMap<>(ALIASES);
        for(Map.Entry<String,String> entry:installedAliases.entrySet())
            aliases.put(TextMatch.normalize(entry.getKey()),entry.getValue());
        String best=null,id=null;
        for(Map.Entry<String,String> entry:aliases.entrySet()){
            String alias=entry.getKey();if(alias.isEmpty())continue;
            boolean prefix=query.startsWith(alias+" ");
            String remainder=prefix?query.substring(alias.length()).trim():"";
            boolean ambiguousProsePrefix=prefix&&AMBIGUOUS_PREFIX_COLLECTIONS.contains(entry.getValue())&&
                alias.indexOf(' ')<0&&reference(remainder)==null;
            if(query.equals(alias)||prefix&&!ambiguousProsePrefix||
                query.endsWith(" "+alias)&&reference(query.substring(0,query.length()-alias.length()).trim())!=null){
                if(best==null||alias.length()>best.length()){best=alias;id=entry.getValue();}
            }
        }
        if(best!=null)query=query.equals(best)?"":query.startsWith(best+" ")?
            query.substring(best.length()).trim():query.substring(0,query.length()-best.length()).trim();
        boolean corrected=false,sahih=false;
        if(id==null){
            String[] words=query.split(" ");
            // Fuzzy titles are accepted only as a standalone book or next to a valid number.
            // A narrator's name inside Arabic prose must not silently become a book filter.
            int bestDistance=Integer.MAX_VALUE,bestLength=0;String fuzzyId=null,remainder=null;boolean ambiguous=false;
            for(int n=1;n<=Math.min(5,words.length);n++)for(boolean prefix:new boolean[]{true,false}){
                String label=String.join(" ",Arrays.copyOfRange(words,prefix?0:words.length-n,prefix?n:words.length));
                String rest=String.join(" ",Arrays.copyOfRange(words,prefix?n:0,prefix?words.length:words.length-n));
                if(!rest.isEmpty()&&reference(rest)==null)continue;
                String key=titleKey(label);if(key.length()<4)continue;
                int limit=key.length()>=8?2:1;
                for(Map.Entry<String,String> entry:aliases.entrySet()){
                    String target=titleKey(entry.getKey());
                    int distance=TextMatch.distance(key,target,limit);
                    if(distance>limit||distance>Math.max(key.length(),target.length())*.25)continue;
                    if(distance<bestDistance||distance==bestDistance&&n>bestLength){
                        bestDistance=distance;bestLength=n;fuzzyId=entry.getValue();remainder=rest;ambiguous=false;
                    }else if(distance==bestDistance&&n==bestLength&&!entry.getValue().equals(fuzzyId))ambiguous=true;
                }
            }
            if(fuzzyId!=null&&!ambiguous){id=fuzzyId;query=remainder;corrected=true;}
            else {
                String title=query.split(" ",2)[0];
                if(titleKey(title).equals("sahih")){
                    String rest=query.length()==title.length()?"":query.substring(title.length()).trim();
                    if(rest.isEmpty()||reference(rest)!=null){sahih=true;query=rest;}
                }
            }
        }
        String number=reference(query);
        return new HadithQuery(raw,id,number==null?query:"",number,corrected,sahih);
    }
    private static String titleKey(String value){
        // Title-only aliases permit mixed-script prefixes and common transliterations.
        return value.replaceAll("^(?:sahih|sahi|saheeh|sahihh|सहीह|सही|साहिह|صحیح|صحيح)(?: |$)","sahih ")
            .replace("भुखारी","बुखारी").replace("bukharee","bukhari").replace("bhukhari","bukhari")
            .replace("bhukari","bukhari").replace("bukhary","bukhari").replace("़","").replace(" ","");
    }
    private static String reference(String value){
        String q=value.replaceFirst("^(?:(?:hadith|hadees|hadeeth|हदीस|हदीथ|حديث|حدیث)\\s+)?(?:(?:number|no|नंबर|नम्बर|نمبر|رقم)\\s+)?","");
        if(q.matches("[0-9](?:\\s+[0-9]){1,7}"))q=q.replace(" ","");
        if(!q.matches("[0-9]{1,8}[a-z]?"))return null;
        return q.replaceFirst("^0+(?!$|[a-z]$)","");
    }
    public boolean isReference(){return number!=null;}
    public boolean isHadithIntent(){return collectionId!=null||sahihCollections||number!=null||raw.startsWith("H:");}
    public boolean isCollectionBrowse(){return (collectionId!=null||sahihCollections)&&text.isEmpty()&&number==null;}
    /** Bare 556 includes 556a/556b; an explicit 556a remains exact. Never includes 5560. */
    public List<String> referenceValues(){
        if(number==null)return Collections.emptyList();
        List<String> values=new ArrayList<>();values.add(number);
        if(number.matches("[0-9]+"))for(char c='a';c<='z';c++)values.add(number+c);
        return values;
    }
    public String scopeLabel(){return sahihCollections?"Sahih al-Bukhari & Sahih Muslim":collectionId==null?"All Hadith collections":collectionId;}
    public String scopeSql(){return collectionId!=null?" AND h.collection_id=?":sahihCollections?" AND h.collection_id IN ('bukhari','muslim')":"";}
    public void addScopeArgs(List<String> args){if(collectionId!=null)args.add(collectionId);}
    /** A bound SQLite predicate shared by the runtime and real-pack regression checks. */
    public static final class Lookup {
        public final String where;
        public final List<String> args;
        private Lookup(String where,List<String> args){this.where=where;this.args=Collections.unmodifiableList(args);}
    }
    public Lookup lookup(){
        List<String> args=new ArrayList<>();String where;
        if(number!=null){
            List<String> values=referenceValues();args.addAll(values);args.add(raw);args.addAll(values);
            List<String> refs=new ArrayList<>();
            if(collectionId!=null)for(String value:values)refs.add(collectionId+":"+value);
            args.addAll(refs);
            where="(h.record_number IN ("+marks(values.size())+") OR h.id IN (SELECT hadith_id FROM hadith_reference WHERE scheme NOT LIKE '%urn%' AND value IN ("+
                marks(1+values.size()+refs.size())+")))";
        }else if(raw.startsWith("H:")){where="h.id=?";args.add(raw);}
        else if(isCollectionBrowse())where="1";
        else throw new IllegalStateException("Text query is not a reference lookup");
        where+=scopeSql();addScopeArgs(args);
        return new Lookup(where,args);
    }
    private static String marks(int n){return String.join(",",Collections.nCopies(n,"?"));}
}
