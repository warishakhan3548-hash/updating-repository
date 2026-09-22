package com.aaris.quran.core;

import java.util.*;

/** Search keys alongside exact, half-open Unicode code-point ranges in the original. */
public final class SourceText {
    public static final class Range {
        public final String text;
        public final int start,end;
        private Range(String original,int start,int end) {
            this.start=start;this.end=end;
            text=original.substring(original.offsetByCodePoints(0,start),original.offsetByCodePoints(0,end));
        }
    }
    public static final class Token {
        public final String key;
        public final int start,end;
        private Token(String key,int start,int end){this.key=key;this.start=start;this.end=end;}
    }
    public final String original;
    public final List<Token> tokens;
    public SourceText(String original) {
        this.original=Objects.requireNonNull(original);
        List<Token> out=new ArrayList<>();int start=-1,startCp=0,cpIndex=0;
        for(int offset=0;offset<=original.length();) {
            int cp=offset==original.length()?-1:original.codePointAt(offset);
            int type=cp<0?-1:Character.getType(cp);
            boolean part=cp>=0&&(Arabic.searchMark(cp)||Character.isLetterOrDigit(cp)||
                type==Character.NON_SPACING_MARK||type==Character.COMBINING_SPACING_MARK);
            if(part&&start<0){start=offset;startCp=cpIndex;}
            if(!part&&start>=0) {
                String key=Arabic.safe(original.substring(start,offset));
                if(!key.isEmpty())out.add(new Token(key,startCp,cpIndex));
                start=-1;
            }
            if(cp<0)break;
            offset+=Character.charCount(cp);cpIndex++;
        }
        tokens=Collections.unmodifiableList(out);
    }
    public Range range(int first,int endExclusive) {
        if(first<0||endExclusive>tokens.size()||first>=endExclusive)throw new IllegalArgumentException("Source token range");
        return new Range(original,tokens.get(first).start,tokens.get(endExclusive-1).end);
    }
}
