package com.aaris.quran.core;

import java.util.*;

/** Algorithm-neutral ledger projection. Conservative scheduler v1, deliberately not advertised as FSRS. */
public final class Recall {
    private Recall() {}
    public static final String VERSION="conservative-1";
    public static final long MINUTE=60_000L, DAY=86_400_000L;
    public enum Kind { SEEN, PEEK, DEEP, ENROLL, REVEAL, AGAIN, HARD, GOOD, EASY, PAUSE, RESUME }
    public static final class Event {
        public final String id,target,session,context;
        public final Kind kind;
        public final long at;
        public Event(String id,String target,Kind kind,long at,String session,String context) {
            this.id=Objects.requireNonNull(id);this.target=Objects.requireNonNull(target);this.kind=kind;this.at=at;
            this.session=session;this.context=context;
        }
    }
    public static final class State {
        public final String target;
        public long due,lastReview,interval;
        public int successes,lapses,reviews,peeks,peeksSinceReview;
        public long lastExposure;
        public boolean active;
        public final Set<String> successfulContexts=new HashSet<>();
        public State(String target){this.target=target;}
        public String label(){return reviews==0?"Shuruaat":successes>=4&&successfulContexts.size()>=2?"Mazboot":lapses>successes?"Dobara dekhein":"Seekh rahe hain";}
    }
    public interface Scheduler { long nextInterval(State before,Kind rating); String version(); }
    public static final class ConservativeScheduler implements Scheduler {
        @Override public String version(){return VERSION;}
        @Override public long nextInterval(State s,Kind rating) {
            switch(rating) {
                case AGAIN:return 10*MINUTE;
                case HARD:return Math.max(4*60*MINUTE,Math.min(30*DAY,(long)(Math.max(DAY,s.interval)*1.15)));
                case GOOD:return Math.min(180*DAY,Math.max(DAY,(long)(s.interval*2.2)));
                case EASY:return Math.min(365*DAY,Math.max(3*DAY,(long)(s.interval*3.0)));
                default:throw new IllegalArgumentException("Only explicit ratings may schedule a review");
            }
        }
    }
    public static boolean rating(Kind k){return k==Kind.AGAIN||k==Kind.HARD||k==Kind.GOOD||k==Kind.EASY;}
    public static Map<String,State> replay(List<Event> ledger,Scheduler scheduler) {
        List<Event> events=new ArrayList<>(ledger);
        // Stable sequence for identical timestamps. SQLite row sequence is preserved by stable sort.
        events.sort(Comparator.comparingLong(e->e.at));
        Map<String,State> states=new LinkedHashMap<>();Map<String,Event> seen=new HashMap<>();Set<String> peeks=new HashSet<>();
        for(Event e:events) {
            Event previous=seen.putIfAbsent(e.id,e);
            if(previous!=null) {
                if(!previous.target.equals(e.target)||previous.kind!=e.kind||previous.at!=e.at||
                    !Objects.equals(previous.session,e.session)||!Objects.equals(previous.context,e.context))
                    throw new IllegalArgumentException("Conflicting event ID");
                continue;
            }
            State s=states.computeIfAbsent(e.target,State::new);
            if(e.kind==Kind.SEEN)s.lastExposure=e.at;
            if(e.kind==Kind.PEEK && peeks.add(e.target+"|"+e.session+"|"+s.reviews)){s.peeks++;s.peeksSinceReview++;}
            if(e.kind==Kind.ENROLL) {if(!s.active&&s.reviews==0)s.due=e.at;s.active=true;}
            if(e.kind==Kind.PAUSE)s.active=false;
            if(e.kind==Kind.RESUME){s.active=true;if(s.due==0)s.due=e.at;}
            if(rating(e.kind)&&s.active) {
                // Duplicate event IDs are ignored, but exposures/reveals never become ratings.
                s.interval=scheduler.nextInterval(s,e.kind);s.due=e.at+s.interval;s.lastReview=e.at;s.reviews++;s.peeksSinceReview=0;
                if(e.kind==Kind.AGAIN){s.lapses++;s.successes=0;}
                else {s.successes++;if(e.context!=null)s.successfulContexts.add(e.context);}
            }
        }
        return states;
    }
    public static final class Opportunity {
        public final String target; public final int distanceAyahs; public final boolean sameReviewedSense;
        public Opportunity(String target,int distance,boolean sameSense){this.target=target;distanceAyahs=distance;sameReviewedSense=sameSense;}
    }
    public static List<State> queue(Collection<State> states,List<Opportunity> upcoming,long now,int maximum) {
        Map<String,Opportunity> opportunities=new HashMap<>();
        for(Opportunity o:upcoming)if(o.sameReviewedSense&&o.distanceAyahs>=0&&o.distanceAyahs<=10)opportunities.put(o.target,o);
        List<State> due=new ArrayList<>();
        for(State s:states) {
            if(!s.active||s.due>now)continue;
            // Deferral is bounded to 24h. A missed reading session cannot starve an item forever.
            if(opportunities.containsKey(s.target)&&now-s.due<DAY&&s.successes>0&&s.peeksSinceReview==0)continue;
            due.add(s);
        }
        due.sort(Comparator.comparingDouble((State s)->priority(s,now)).reversed().thenComparing(s->s.target));
        return new ArrayList<>(due.subList(0,Math.min(Math.max(0,maximum),due.size())));
    }
    public static double priority(State s,long now) {
        double late=Math.min(14,Math.max(0,(double)(now-s.due)/DAY));
        return 1+late+Math.min(3,s.lapses)*1.5+Math.min(3,s.peeksSinceReview)*0.2;
    }
    /** A guess of rarity is never permission to enroll an untouched word. */
    public static double rescueNeed(boolean relevant,double forgettingRisk,int futureOccurrences,double difficulty) {
        if(!relevant||!Double.isFinite(forgettingRisk)||!Double.isFinite(difficulty))return 0;
        return Math.max(0,Math.min(1,forgettingRisk))*1.0/(1+Math.max(0,futureOccurrences))*Math.max(0,Math.min(1,difficulty));
    }
}
