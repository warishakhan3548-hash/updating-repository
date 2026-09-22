package com.aaris.quran;

import android.content.Context;
import android.graphics.Typeface;
import android.text.*;
import android.text.style.ClickableSpan;
import android.text.style.BackgroundColorSpan;
import android.text.method.LinkMovementMethod;
import android.view.*;
import android.widget.TextView;
import com.aaris.quran.core.Ayah;
import java.util.*;

/** Android's text layout owns shaping and wrapping; spans retain exact source word ranges. */
final class QuranText extends TextView {
    interface Listener { void onWord(ContentStore.Word word); }
    QuranText(Context c,Typeface font,Ayah ayah,List<ContentStore.Word> words,float size,Listener listener) {
        super(c);setTypeface(font);setTextSize(size);setTextColor(Glass.INK);
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
                @Override public void onClick(View widget){listener.onWord(w);}
                @Override public void updateDrawState(TextPaint ds){ds.setColor(Glass.INK);ds.setUnderlineText(false);}
            },start,end,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        setText(value);setMovementMethod(LinkMovementMethod.getInstance());setHighlightColor(0x445EDAC5);
        setContentDescription(ayah.arabic+". Ayah "+ayah.surah+":"+ayah.number);
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
    }
}
