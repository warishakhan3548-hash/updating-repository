package com.aaris.quran.core;

import java.util.*;

/**
 * Search-only multilingual bridges. Nothing returned by this class is scripture or a display
 * translation: aliases and roman shadows are retrieval hints that must always resolve back to
 * immutable source evidence.
 */
public final class MeaningSearch {
    private MeaningSearch() {}

    private static final Map<String,List<String>> ALIASES;
    private static final Set<String> FILLER=new HashSet<>(Arrays.asList(
        "के","की","का","को","ने","से","में","पर","कि","था","थे","थी","है","हैं","हो","रहे","रही","रहा",
        "aur","ke","ki","ka","ko","ne","se","me","mein","par","tha","the","thi","hai","hain","ho","rahe","rahi","raha",
        "the","a","an","of","to","and","in","is","was","were","that","who","he","she","they","it","his","her","their",
        "ये","यह","कहाँ","लिखा","लिखी","लिखे","बताओ","बताइए","बताये","बताएं","कौन","मुझे",
        "ye","yeh","kahan","likha","likhi","likhe","batao","bataiye","bataye","kaun","mujhe",
        "where","written","mentioned","show","find","please","tell","me","which"
    ));
    static {
        Map<String,LinkedHashSet<String>> map=new HashMap<>();
        group(map,"नबी","nabi","prophet","رسول","نبي","रसूल","rasul","messenger");
        group(map,"सहाबी","sahabi","companion","صحابي");
        group(map,"वुज़ू","वुजू","वजू","wudu","wuzu","wudhu","vuzu","wazoo","vazoo","ablution","وضوء");
        group(map,"नमाज़","नमाज","namaz","salah","salat","prayer","صلاة","الصلاة");
        group(map,"फ़र्ज़","फर्ज","farz","fard","obligatory","obligation","فرض");
        group(map,"रकात","रकअत","rakat","rakah","rakaa","ركعة","ركعتين");
        group(map,"सुन्नत","sunnat","sunnah","سنة");
        group(map,"दुआ","dua","supplication","دعاء");
        group(map,"रोज़ा","रोजा","roza","fasting","fast","صوم","صيام");
        group(map,"ज़कात","जकात","zakat","almsgiving","زكاة");
        group(map,"हज","hajj","pilgrimage","حج");
        group(map,"ईमान","iman","faith","belief","إيمان","ايمان");
        group(map,"जन्नत","jannat","paradise","جنة");
        group(map,"जहन्नम","jahannam","hell","جهنم");
        group(map,"मस्जिद","masjid","mosque","مسجد");
        group(map,"अज़ान","अजान","azan","adhan","أذان","اذان");
        group(map,"क़िबला","किबला","qibla","قبلة");
        group(map,"काबा","kaaba","kaba","كعبة");
        group(map,"नहीं","नही","nahin","nahi","نہیں","نهيں","not","no");
        Map<String,List<String>> frozen=new HashMap<>();
        for(Map.Entry<String,LinkedHashSet<String>> e:map.entrySet())
            frozen.put(e.getKey(),Collections.unmodifiableList(new ArrayList<>(e.getValue())));
        ALIASES=Collections.unmodifiableMap(frozen);
    }

    private static String normalizeAlias(String value){
        return Arabic.glossSearch(value==null?"":value.replace("’","").replace("'","")).trim();
    }
    private static void group(Map<String,LinkedHashSet<String>> map,String... raw){
        LinkedHashSet<String> normalized=new LinkedHashSet<>();
        for(String value:raw){
            String n=normalizeAlias(value);
            if(!n.isEmpty())normalized.add(n);
        }
        for(String value:normalized){
            LinkedHashSet<String> alternatives=map.computeIfAbsent(value,k->new LinkedHashSet<>());
            for(String other:normalized)if(!other.equals(value))alternatives.add(other);
        }
    }

    /**
     * Remove only low-information grammar tokens for a secondary meaning lane.
     * Negation, numbers, time/order words and religious/content words are deliberately retained.
     */
    public static List<String> focusTokens(List<String> normalizedTokens){
        if(normalizedTokens==null||normalizedTokens.isEmpty())return Collections.emptyList();
        LinkedHashSet<String> focused=new LinkedHashSet<>();
        for(String token:normalizedTokens){
            if(token==null||token.isEmpty())continue;
            if(TextMatch.negative(token)||!FILLER.contains(token))focused.add(token);
        }
        // The meaning lane is concept-oriented: conversational repetition must not demand
        // duplicate source occurrences. The direct text lane still preserves every token.
        if(focused.size()>=2)return new ArrayList<>(focused);
        return new ArrayList<>(normalizedTokens);
    }

    /** High-confidence, domain-specific aliases only; never generic free-form synonym expansion. */
    public static List<String> alternatives(String normalizedTerm){
        if(normalizedTerm==null)return Collections.emptyList();
        List<String> found=ALIASES.get(normalizedTerm);
        return found==null?Collections.emptyList():found;
    }

    /** True only when a documented concept alias bridges a query term absent verbatim. */
    public static boolean usesConceptBridge(List<String> query,List<String> document){
        if(query==null||document==null||query.isEmpty()||document.isEmpty())return false;
        Set<String> words=new HashSet<>(document);
        for(String term:query){
            if(term==null||term.isEmpty()||words.contains(term))continue;
            for(String alternative:alternatives(term))if(words.contains(alternative))return true;
        }
        return false;
    }

    /**
     * Deterministic Devanagari -> simple Hinglish retrieval shadow.
     * This is intentionally not a display transliteration and may be lossy.
     */
    public static String romanizeHindi(String input){
        if(input==null||input.isEmpty())return "";
        StringBuilder out=new StringBuilder();
        boolean consonant=false;
        int[] cps=input.codePoints().toArray();
        for(int cp:cps){
            String c=consonant(cp);
            if(c!=null){
                out.append(c).append('a');consonant=true;continue;
            }
            String vowel=independentVowel(cp);
            if(vowel!=null){out.append(vowel);consonant=false;continue;}
            String matra=matra(cp);
            if(matra!=null){
                if(consonant&&out.length()>0&&out.charAt(out.length()-1)=='a')out.setLength(out.length()-1);
                out.append(matra);consonant=false;continue;
            }
            if(cp==0x94d){ // virama
                if(consonant&&out.length()>0&&out.charAt(out.length()-1)=='a')out.setLength(out.length()-1);
                consonant=false;continue;
            }
            if(cp==0x93c){ // nukta; convert the most common search spellings.
                if(ends(out,"ja"))replaceEnd(out,"ja","za");
                else if(ends(out,"pha"))replaceEnd(out,"pha","fa");
                else if(ends(out,"ka"))replaceEnd(out,"ka","qa");
                consonant=true;continue;
            }
            if(cp==0x902||cp==0x901){out.append('n');consonant=false;continue;}
            if(cp==0x903){out.append('h');consonant=false;continue;}
            int digit=Character.digit(cp,10);
            if(digit>=0){finishWord(out,consonant);out.append((char)('0'+digit));consonant=false;continue;}
            if(Character.isLetterOrDigit(cp)){
                finishWord(out,consonant);out.appendCodePoint(Character.toLowerCase(cp));consonant=false;
            }else{
                finishWord(out,consonant);if(out.length()>0&&out.charAt(out.length()-1)!=' ')out.append(' ');consonant=false;
            }
        }
        finishWord(out,consonant);
        return out.toString().trim().replaceAll("\\s+"," ");
    }

    private static void finishWord(StringBuilder out,boolean consonant){
        if(consonant&&out.length()>0&&out.charAt(out.length()-1)=='a')out.setLength(out.length()-1);
    }
    private static boolean ends(StringBuilder b,String suffix){
        if(b.length()<suffix.length())return false;
        for(int i=0;i<suffix.length();i++)if(b.charAt(b.length()-suffix.length()+i)!=suffix.charAt(i))return false;
        return true;
    }
    private static void replaceEnd(StringBuilder b,String suffix,String replacement){
        b.setLength(b.length()-suffix.length());b.append(replacement);
    }
    private static String consonant(int cp){
        switch(cp){
            case 0x915:return "k"; case 0x916:return "kh"; case 0x917:return "g"; case 0x918:return "gh"; case 0x919:return "ng";
            case 0x91a:return "ch";case 0x91b:return "chh";case 0x91c:return "j";case 0x91d:return "jh";case 0x91e:return "ny";
            case 0x91f:return "t";case 0x920:return "th";case 0x921:return "d";case 0x922:return "dh";case 0x923:return "n";
            case 0x924:return "t";case 0x925:return "th";case 0x926:return "d";case 0x927:return "dh";case 0x928:return "n";
            case 0x92a:return "p";case 0x92b:return "ph";case 0x92c:return "b";case 0x92d:return "bh";case 0x92e:return "m";
            case 0x92f:return "y";case 0x930:return "r";case 0x932:return "l";case 0x933:return "l";case 0x935:return "v";
            case 0x936:return "sh";case 0x937:return "sh";case 0x938:return "s";case 0x939:return "h";
            case 0x958:return "q";case 0x959:return "kh";case 0x95a:return "gh";case 0x95b:return "z";case 0x95c:return "d";
            case 0x95d:return "dh";case 0x95e:return "f";case 0x95f:return "y";
            default:return null;
        }
    }
    private static String independentVowel(int cp){
        switch(cp){
            case 0x905:return "a";case 0x906:return "a";case 0x907:return "i";case 0x908:return "i";
            case 0x909:return "u";case 0x90a:return "u";case 0x90b:return "ri";case 0x90f:return "e";
            case 0x910:return "ai";case 0x913:return "o";case 0x914:return "au";
            default:return null;
        }
    }
    private static String matra(int cp){
        switch(cp){
            case 0x93e:return "a";case 0x93f:return "i";case 0x940:return "i";case 0x941:return "u";case 0x942:return "u";
            case 0x943:return "ri";case 0x947:return "e";case 0x948:return "ai";case 0x94b:return "o";case 0x94c:return "au";
            default:return null;
        }
    }
}
