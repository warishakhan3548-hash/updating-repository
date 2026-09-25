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
    private BackgroundColorSpan selected,pressedHighlight;
    private final String source;
    private final int touchSlop;
    private ClickableSpan pressedSpan;
    private float downX,downY;
    private boolean longPressTriggered;
    private final Runnable longPress=()->{
        if(pressedSpan==null||!isPressed())return;
        longPressTriggered=performLongClick();
        if(longPressTriggered)clearPress();
    };
    QuranText(Context c,Typeface font,Ayah ayah,List<ContentStore.Word> words,float size,Listener listener) {
        super(c);source=ayah.arabic;touchSlop=ViewConfiguration.get(c).getScaledTouchSlop();setTypeface(font);setTextSize(size);
        setTextDirection(View.TEXT_DIRECTION_RTL);setLayoutDirection(View.LAYOUT_DIRECTION_RTL);
        setGravity(Gravity.RIGHT);setIncludeFontPadding(true);setLineSpacing(Glass.dp(c,10),1.08f);
        setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
        setPadding(Glass.dp(c,3),Glass.dp(c,6),Glass.dp(c,3),Glass.dp(c,8));
        String rendered=source;
        // Tanzil keeps the unnumbered opening Bismillah on the first ayah's source line.
        // Replace only the fourth separator space at render time. This is independent of word
        // gloss alignment (notably the distinct Bismillah diacritics at 95:1 and 97:1), so source
        // bytes, hashes and all source offsets remain unchanged.
        if(ayah.number==1&&ayah.surah!=1&&ayah.surah!=9){
            int split=-1;
            for(int word=0;word<4&&split<source.length();word++)split=source.indexOf(' ',split+1);
            if(split>=0){
                StringBuilder formatted=new StringBuilder(source);formatted.setCharAt(split,'\n');rendered=formatted.toString();
            }
        }
        SpannableString value=new SpannableString(rendered);
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
    private ClickableSpan spanAt(MotionEvent event){
        Layout layout=getLayout();CharSequence text=getText();
        if(layout==null||!(text instanceof Spanned)||text.length()==0)return null;
        float x=event.getX()-getTotalPaddingLeft()+getScrollX(),y=event.getY()-getTotalPaddingTop()+getScrollY();
        if(x<0||y<0||y>layout.getHeight())return null;
        int line=layout.getLineForVertical((int)y);
        float left=Math.min(layout.getLineLeft(line),layout.getLineRight(line));
        float right=Math.max(layout.getLineLeft(line),layout.getLineRight(line));
        if(x<left||x>right)return null;
        int offset=Math.min(text.length()-1,Math.max(0,layout.getOffsetForHorizontal(line,x)));
        ClickableSpan[] spans=((Spanned)text).getSpans(offset,offset+1,ClickableSpan.class);
        return spans.length==0?null:spans[0];
    }
    private void clearPress(){
        removeCallbacks(longPress);
        CharSequence value=getText();if(pressedHighlight!=null&&value instanceof Spannable)((Spannable)value).removeSpan(pressedHighlight);
        pressedHighlight=null;pressedSpan=null;setPressed(false);invalidate();
    }
    private void showPress(ClickableSpan span){
        CharSequence value=getText();if(span==null||!(value instanceof Spannable))return;
        Spannable text=(Spannable)value;int start=text.getSpanStart(span),end=text.getSpanEnd(span);
        if(start<0||end<=start)return;
        if(pressedHighlight!=null)text.removeSpan(pressedHighlight);
        pressedHighlight=new BackgroundColorSpan(Glass.WORD_HIGHLIGHT);
        text.setSpan(pressedHighlight,start,end,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);invalidate();
    }
    @Override public boolean onTouchEvent(MotionEvent event){
        switch(event.getActionMasked()){
            case MotionEvent.ACTION_DOWN:
                removeCallbacks(longPress);longPressTriggered=false;
                pressedSpan=spanAt(event);downX=event.getX();downY=event.getY();
                if(pressedSpan==null)return false;
                setPressed(true);showPress(pressedSpan);postDelayed(longPress,ViewConfiguration.getLongPressTimeout());return true;
            case MotionEvent.ACTION_MOVE:
                if(pressedSpan==null)return longPressTriggered;
                if(Math.abs(event.getX()-downX)>touchSlop||Math.abs(event.getY()-downY)>touchSlop){
                    clearPress();
                    ViewParent parent=getParent();if(parent!=null)parent.requestDisallowInterceptTouchEvent(false);
                }
                return true;
            case MotionEvent.ACTION_UP:
                boolean held=longPressTriggered;
                ClickableSpan tapped=held?null:pressedSpan;
                boolean within=tapped!=null&&Math.abs(event.getX()-downX)<=touchSlop&&Math.abs(event.getY()-downY)<=touchSlop;
                ClickableSpan released=within?spanAt(event):null;clearPress();longPressTriggered=false;
                if(held)return true;
                if(tapped!=null&&tapped==released){tapped.onClick(this);performClick();}
                return tapped!=null;
            case MotionEvent.ACTION_CANCEL:
                boolean hadPress=pressedSpan!=null||longPressTriggered;clearPress();longPressTriggered=false;return hadPress;
            default:
                return pressedSpan!=null||longPressTriggered;
        }
    }
    @Override public boolean performClick(){super.performClick();return true;}
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
