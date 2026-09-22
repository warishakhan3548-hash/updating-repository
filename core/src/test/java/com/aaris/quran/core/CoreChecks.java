package com.aaris.quran.core;

import java.util.*;

/** Dependency-free behavioral regressions. Synthetic text is never shipped as evidence. */
public final class CoreChecks {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++; if (!value) throw new AssertionError(message);
    }
    private static SearchEngine.Document doc(int n, String arabic, String hints) {
        return new SearchEngine.Document(new Ayah(1,n,arabic,References.sha256(arabic),n),hints);
    }
    private static Recall.Event event(String id,Recall.Kind kind,long at) {
        return new Recall.Event(id,"Q:1:1:W:1",kind,at,"session","Q:1:1");
    }
    public static void main(String[] args) {
        SearchEngine search=new SearchEngine(Arrays.asList(
            doc(1,"لا يعمل الرجل","work नहीं"),doc(2,"يعمل الرجل","work"),
            doc(3,"الكلمة الصحيحة","correct सही درست")));
        check(search.search("١:٢",10).results.get(0).ayah.number==2,"Unicode coordinate");
        check(search.search("1:9",10).results.isEmpty(),"Unknown coordinate must abstain");
        check(search.search("الكلمة الصحيحة",10).results.get(0).strength==SearchEngine.Strength.STRONG_TEXT,"Exact text lane");
        check(search.search("لا يعمل",10).results.stream().noneMatch(r->r.ayah.number==2),"Arabic negation preserved");
        check(search.search("work नहीं",10).results.stream().noneMatch(r->r.ayah.number==2),"Hindi negation preserved");
        check(!search.search("درست",10).results.isEmpty(),"Urdu must reach gloss lane");
        check(search.search("unicorn telescope",10).results.isEmpty(),"Unsupported query abstains");
        check(search.search("درست\nدرست",10).results.size()==search.search("درست",10).results.size(),"Duplicate variants do not create evidence");
        check(Arabic.safe("أَ").equals("أ"),"Safe lane preserves hamza");
        check(!Arabic.tolerant("نية").equals(Arabic.tolerant("نيه")),"Ta marbuta is not ha");
        List<Recall.Event> events=new ArrayList<>();
        events.add(event("enroll",Recall.Kind.ENROLL,100));
        events.add(event("seen",Recall.Kind.SEEN,200));
        events.add(event("peek",Recall.Kind.PEEK,300));
        events.add(event("reveal",Recall.Kind.REVEAL,400));
        Recall.State state=Recall.replay(events,new Recall.ConservativeScheduler()).get("Q:1:1:W:1");
        check(state.reviews==0 && state.successes==0,"Exposure/peek/reveal never prove recall");
        events.add(event("rating",Recall.Kind.GOOD,500));events.add(event("rating",Recall.Kind.GOOD,500));
        state=Recall.replay(events,new Recall.ConservativeScheduler()).get("Q:1:1:W:1");
        check(state.reviews==1,"Duplicate review ID is idempotent");
        check(Recall.rescueNeed(false,1,0,1)==0,"Rarity cannot enroll untouched items");
        check(Recall.queue(Collections.singleton(state),Collections.emptyList(),state.due,1).size()==1,"Due item offered");
        Map<String,String> snapshot=Collections.singletonMap("Q:1:1","exact source");
        check(References.verify("\"exact source\" [Q:1:1]",snapshot).passed(),"Exact quote validates");
        check(!References.verify("\"invented\" [Q:1:1]",snapshot).passed(),"Wrong quote rejected");
        check(!References.verify("[Q:2:2]",snapshot).passed(),"Citation outside snapshot rejected");
        check(!References.verify("No evidence here",snapshot).passed(),"No citations cannot pass");
        check(References.verify("\"exact source\" [Q:1:1]",snapshot).checkedQuotes==1,"Report actual checked quote count");
        System.out.println("Core checks: "+checks+" passed");
    }
}
