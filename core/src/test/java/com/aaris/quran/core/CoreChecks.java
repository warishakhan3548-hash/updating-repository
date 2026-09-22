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
        SearchEngine repeated=new SearchEngine(Arrays.asList(doc(1,"كلمة واحدة","one"),doc(2,"كلمة كلمة واحدة","two")));
        check(repeated.search("كلمة كلمة",10).results.stream().noneMatch(r->r.ayah.number==1),"One token cannot satisfy repeated query words");
        check(search.search("درست",10).trace.get("gloss_bm25")>0,"Trace accounts for Urdu gloss candidates");
        check(search.search("x".repeat(4097),10).intent.equals("QUERY_LIMIT"),"Oversized queries are not silently truncated");
        SearchEngine.Response expanded=search.search("1:2",Collections.singletonList(new SearchEngine.Query("1:3",SearchEngine.Origin.AI)),10);
        check(expanded.results.stream().anyMatch(r->r.ayah.number==2),"Original query retained alongside AI expansions");
        check(expanded.variants.stream().anyMatch(v->v.origin==SearchEngine.Origin.AI),"AI query provenance is retained");
        check(Arabic.glossSearch("raḥmān").equals("rahman"),"Latin accents searchable");
        check(!Arabic.glossSearch("की").equals(Arabic.glossSearch("क")),"Hindi signs must not be stripped");
        check(Arabic.safe("أَ").equals("أ"),"Safe lane preserves hamza");
        check(!Arabic.tolerant("نية").equals(Arabic.tolerant("نيه")),"Ta marbuta is not ha");
        Recall.ConservativeScheduler scheduler=new Recall.ConservativeScheduler();
        Recall.State fresh=new Recall.State("Q:1:1");
        check(scheduler.nextInterval(fresh,Recall.Kind.HARD)<scheduler.nextInterval(fresh,Recall.Kind.GOOD),"First HARD must return sooner than GOOD");
        for(long interval:new long[]{0,10*Recall.MINUTE,4*60*Recall.MINUTE,Recall.DAY,30*Recall.DAY,365*Recall.DAY}){
            fresh.interval=interval;
            check(scheduler.nextInterval(fresh,Recall.Kind.HARD)<=scheduler.nextInterval(fresh,Recall.Kind.GOOD),"Rating order remains monotonic across intervals");
        }
        fresh.interval=0;
        check(scheduler.nextInterval(fresh,Recall.Kind.HARD,"conservative-1")== (long)(Recall.DAY*1.15),"Legacy interval is reproduced, not silently migrated");
        List<Recall.Event> legacy=Arrays.asList(new Recall.Event("old-enroll","Q:1:1",Recall.Kind.ENROLL,1,"old","Q:1:1","conservative-1"),
            new Recall.Event("old-hard","Q:1:1",Recall.Kind.HARD,2,"old","Q:1:1","conservative-1"));
        check(Recall.replay(legacy,scheduler).get("Q:1:1").interval==(long)(Recall.DAY*1.15),"Replay uses recorded scheduler version");
        boolean unknown=false;try{scheduler.nextInterval(fresh,Recall.Kind.GOOD,"future-unknown");}catch(IllegalArgumentException expected){unknown=true;}
        check(unknown,"Unknown historical algorithm must fail visibly");
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
        List<Recall.Opportunity> next=Collections.singletonList(new Recall.Opportunity(state.target,2,true));
        check(Recall.queue(Collections.singleton(state),next,state.due,1).isEmpty(),"Exact upcoming occurrence can defer a practiced item");
        check(Recall.queue(Collections.singleton(state),next,state.due+Recall.DAY,1).size()==1,"Natural review deferral expires after one day");
        events.add(event("peek-again",Recall.Kind.PEEK,600));
        state=Recall.replay(events,new Recall.ConservativeScheduler()).get(state.target);
        check(state.peeksSinceReview==1,"New peek after review is fresh uncertainty");
        check(Recall.queue(Collections.singleton(state),next,state.due,1).size()==1,"Fresh difficulty cancels natural deferral");
        events.add(event("pause",Recall.Kind.PAUSE,700));events.add(event("paused-rating",Recall.Kind.EASY,800));
        check(Recall.replay(events,new Recall.ConservativeScheduler()).get(state.target).reviews==1,"Paused item cannot accumulate reviews");
        check(Recall.replay(Collections.singletonList(event("orphan",Recall.Kind.GOOD,100)),new Recall.ConservativeScheduler()).get(state.target).reviews==0,"Rating alone does not enroll an item");
        boolean conflict=false;try{Recall.replay(Arrays.asList(event("same",Recall.Kind.PEEK,1),event("same",Recall.Kind.GOOD,1)),new Recall.ConservativeScheduler());}catch(IllegalArgumentException expected){conflict=true;}
        check(conflict,"Conflicting event identity fails instead of silently losing history");
        check(RecallTarget.parse("Q:1:7:P:2-4").kind==RecallTarget.Kind.PHRASE,"Phrase has a stable canonical identity");
        check(RecallTarget.parse("Q:1:7:P:4-2")==null,"Reversed phrase rejected");
        check(RecallTarget.parse("Q:1:7:P:2-2")==null,"Single word not mislabelled as phrase");
        check(RecallTarget.parse("Q:115:1")==null,"Invalid surah rejected");
        check(RecallTarget.parse("Q:2:1:B:4")!=null,"Prefatory basmala word identity preserved");
        check(RecallTarget.parse("Q:2:1:B:5")==null,"Invalid basmala position rejected");
        check(RecallTarget.parse("Q:1:2:T:3").nextAyahId.equals("Q:1:3"),"Transition keeps both source identities");
        check(RecallTarget.parse("Q:1:2:T:4")==null,"Transition cannot skip an ayah");
        check(RecallTarget.parse("Q:1:2:T:1")==null,"Transition is directed, not reversible");
        check(RecallTarget.parse("Q:2:286:T:287")==null,"Transition cannot escape coordinate bounds");
        SourceText offsets=new SourceText("😀 أَحَدٌ، كلمةٌ ۞ أُخْرَى");
        check(offsets.tokens.size()==3,"Reading marks do not become source words");
        check(offsets.range(0,1).start==2&&offsets.range(0,1).text.equals("أَحَدٌ"),"Source ranges use code points including astral characters");
        check(offsets.range(0,3).text.equals("أَحَدٌ، كلمةٌ ۞ أُخْرَى"),"Source excerpt retains punctuation and marks between words");
        Ayah from=doc(1,"كلمة واحدة ثانية ثالثة"," ").ayah,to=doc(2,"أخرى تالية"," ").ayah;
        AyahTransition edge=new AyahTransition(from,to);
        check(edge.ending.text.equals("واحدة ثانية ثالثة")&&edge.opening.text.equals(to.arabic),"Transition uses bounded exact source excerpts");
        boolean distant=false;try{new AyahTransition(from,doc(3,"بعيد"," ").ayah);}catch(IllegalArgumentException expected){distant=true;}
        check(distant,"Nonadjacent content cannot form a transition");
        boolean boundary=false;try{new AyahTransition(from,new Ayah(2,2,"حد","hash",2));}catch(IllegalArgumentException expected){boundary=true;}
        check(boundary,"Transitions do not bridge surah boundaries");
        List<Recall.Event> bridge=Arrays.asList(new Recall.Event("bridge-enroll",edge.id,Recall.Kind.ENROLL,1,"s",from.id),
            new Recall.Event("bridge-rating",edge.id,Recall.Kind.GOOD,2,"s",from.id));
        Map<String,Recall.State> bridgeState=Recall.replay(bridge,scheduler);
        check(bridgeState.size()==1&&bridgeState.get(edge.id).reviews==1&&!bridgeState.containsKey(to.id),"A transition review never inflates either ayah's mastery");
        ReadingPosition position=new ReadingPosition("Q:2:1","Q:2:5",12,-8.5f,false);
        ReadingPosition restored=ReadingPosition.parse(position.encode());
        check(restored!=null&&restored.codePoint==12&&restored.lineOffsetDp==-8.5f&&restored.anchorId.equals("Q:2:5"),"Reading position survives a portable round trip");
        check(ReadingPosition.parse("Q:2:1|Q:3:1|0|0|0")==null,"Reader anchor cannot point to another surah");
        check(ReadingPosition.parse("Q:2:1|Q:2:9|0|0|0")==null,"Reader anchor cannot escape its page");
        check(ReadingPosition.parse("Q:2:1|Q:2:1|0|NaN|0")==null,"Nonfinite viewport offsets rejected on restore");
        check(Recall.rescueNeed(true,Double.NaN,0,1)==0,"Invalid model output cannot inflate priority");
        Map<String,String> snapshot=Collections.singletonMap("Q:1:1","exact source");
        check(References.verify("\"exact source\" [Q:1:1]",snapshot).passed(),"Exact quote validates");
        check(!References.verify("\"invented\" [Q:1:1]",snapshot).passed(),"Wrong quote rejected");
        check(!References.verify("[Q:2:2]",snapshot).passed(),"Citation outside snapshot rejected");
        check(!References.verify("No evidence here",snapshot).passed(),"No citations cannot pass");
        check(References.verify("\"exact source\" [Q:1:1]",snapshot).checkedQuotes==1,"Report actual checked quote count");
        check(!References.verify("[Q:1:1] and [Q:bad]",snapshot).passed(),"Malformed citation is not ignored beside valid citation");
        check(!References.verify("[Q:1:1] plus \"unsourced quote\"",snapshot).passed(),"Unsupported quote cannot receive a verified badge");
        checks+=FragmentChecks.run();
        checks+=ExportChecks.run();
        checks+=AmbientChecks.run();
        System.out.println("Core checks: "+checks+" passed");
    }
}
