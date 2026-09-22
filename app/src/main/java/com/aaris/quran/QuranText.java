package com.aaris.quran;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.Rect;
import android.text.*;
import android.text.style.ClickableSpan;
import android.text.style.BackgroundColorSpan;
import android.text.method.LinkMovementMethod;
import android.view.*;
import com.aaris.quran.core.Ayah;
import java.util.*;

/** Android's text layout owns shaping and wrapping; spans retain exact source word ranges. */
final class QuranText extends ArabicText {
    interface Listener { void onWord(ContentStore.Word word,QuranText owner); }
    private BackgroundColorSpan selected;
    private final String source;
    QuranText(Context c,Typeface font,Ayah ayah,List<ContentStore.Word> words,float size,Listener listener) {
        super(c);source=ayah.arabic;setTypeface(font);setTextSize(size);
        setTextDirection(View.TEXT_DIRECTION_RTL);setLayoutDirection(View.LAYOUT_DIRECTION_RTL);
        setGravity(Gravity.RIGHT);setIncludeFontPadding(true);setLineSpacing(Glass.dp(c,10),1.08f);
        setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
        setPadding(Glass.dp(c,3),Glass.dp(c,6),Glass.dp(c,3),Glass.dp(c,8));
        SpannableString value=new SpannableString(ayah.arabic);
        for(ContentStore.Word w:words) {
            // Pack stores Unicode code-point offsets; Android spans require UTF-16 offsets.
            int start=ayah.arabic.offsetByCodePoints(0,w.start),end=ayah.arabic.offsetByCodePoints(0,w.end);
            if(!ayah.arabic.substring(start,end).equals(w.arabic))throw new IllegalArgumentException("Word offset/source mismatch");
            value.setSpan(new ClickableSpan(){
                @Override public void onClick(View widget){listener.onWord(w,QuranText.this);}
                @Override public void updateDrawState(TextPaint ds){ds.setColor(getCurrentTextColor());ds.setUnderlineText(false);}
            },start,end,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        setText(value,BufferType.SPANNABLE);setMovementMethod(LinkMovementMethod.getInstance());setHighlightColor(Glass.WORD_HIGHLIGHT);
        setContentDescription(ayah.arabic+". Ayah "+ayah.surah+":"+ayah.number);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
    }
    void select(ContentStore.Word word) {
        Spannable value=(Spannable)getText();if(selected!=null)value.removeSpan(selected);selected=null;
        Selection.removeSelection(value);
        setWordHighlighted(word!=null);
        if(word!=null){selected=new BackgroundColorSpan(Glass.WORD_HIGHLIGHT);value.setSpan(selected,
            source.offsetByCodePoints(0,word.start),source.offsetByCodePoints(0,word.end),Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);}
    }
    /** Full tapped line bounds in window coordinates; no glyph layout or scroll changes. */
    Rect wordLines(ContentStore.Word word) {
        Layout layout=getLayout();if(layout==null)return null;int[] at=new int[2];getLocationInWindow(at);
        int start=source.offsetByCodePoints(0,word.start),end=source.offsetByCodePoints(0,word.end);
        return new Rect(at[0],at[1]+getTotalPaddingTop()+layout.getLineTop(layout.getLineForOffset(start))-getScrollY(),
            at[0]+getWidth(),at[1]+getTotalPaddingTop()+layout.getLineBottom(layout.getLineForOffset(Math.max(start,end-1)))-getScrollY());
    }
}
