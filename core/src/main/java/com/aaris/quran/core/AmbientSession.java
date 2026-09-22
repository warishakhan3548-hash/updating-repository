package com.aaris.quran.core;

import java.util.*;

/** A single, monotonic, visible-screen timer. It never writes learning events. */
public final class AmbientSession {
    public enum Action { NONE, SHOW, HIDE }
    private long interval, remaining, last;
    private boolean running, eligible, showing;
    private final Map<String,Long> presented=new HashMap<>();
    private long sequence;

    public void start(long now,long interval,long firstDelay) {
        if(now<0||interval<Recall.MINUTE||interval>120*Recall.MINUTE||firstDelay<1||firstDelay>interval)
            throw new IllegalArgumentException("Invalid ambient interval");
        this.interval=interval;remaining=firstDelay;last=now;
        running=true;eligible=false;showing=false;presented.clear();sequence=0;
    }
    /** Call when eligibility changes as well as when the timer expires. */
    public Action advance(long now,boolean allowed) {
        if(!running)return Action.NONE;
        if(now<last)throw new IllegalArgumentException("Use a monotonic clock");
        if(eligible&&!showing)remaining=Math.max(0,remaining-(now-last));
        last=now;eligible=allowed;
        if(showing&&!allowed){dismiss(now);return Action.HIDE;}
        if(!showing&&allowed&&remaining==0){showing=true;return Action.SHOW;}
        return Action.NONE;
    }
    public void dismiss(long now) {
        if(!running||!showing)return;
        if(now<last)throw new IllegalArgumentException("Use a monotonic clock");
        showing=false;remaining=interval;last=now;
    }
    public void stop(){running=false;showing=false;eligible=false;remaining=0;presented.clear();}
    public long remaining(){return remaining;}
    public boolean showing(){return showing;}
    public boolean running(){return running;}

    /** Due work first; rotate within that pool so dismissing cannot starve other items.
     *  Optional extra practice uses only explicitly enrolled, source-validated targets. */
    public String choose(Collection<Recall.State> sourceValidated,long wallTime,boolean dueOnly) {
        List<Recall.State> active=new ArrayList<>(),due=new ArrayList<>();
        for(Recall.State s:sourceValidated)if(s.active){active.add(s);if(s.due<=wallTime)due.add(s);}
        List<Recall.State> pool=due.isEmpty()?(dueOnly?Collections.emptyList():active):due;
        return pool.stream().min(Comparator
            .comparingLong((Recall.State s)->presented.getOrDefault(s.target,0L))
            .thenComparing(Comparator.comparingDouble((Recall.State s)->Recall.priority(s,wallTime)).reversed())
            .thenComparing(s->s.target)).map(s->s.target).orElse(null);
    }
    public void presented(String target){presented.put(Objects.requireNonNull(target),++sequence);}
}
