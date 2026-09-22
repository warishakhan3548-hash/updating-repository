package com.aaris.quran.core;

import java.util.*;

final class AmbientChecks {
    static int run(){
        int n=0;long minute=Recall.MINUTE;
        AmbientSession s=new AmbientSession();s.start(0,5*minute,5*minute);
        require(s.advance(3*minute,false)==AmbientSession.Action.NONE&&s.remaining()==5*minute,"App foreground never consumes the timer");n++;
        s.advance(3*minute,true);
        require(s.advance(5*minute,true)==AmbientSession.Action.NONE&&s.remaining()==3*minute,"Switching other apps preserves elapsed time");n++;
        s.advance(6*minute,false);
        require(s.remaining()==2*minute,"Screen-off event accounts for preceding visible time");n++;
        s.advance(60*minute,true);
        require(s.remaining()==2*minute,"Locked screen contributes no elapsed time or backlog");n++;
        require(s.advance(62*minute,true)==AmbientSession.Action.SHOW,"Show exactly at the remaining interval");n++;
        require(s.advance(90*minute,true)==AmbientSession.Action.NONE,"Never stack cards while one is visible");n++;
        s.dismiss(90*minute);
        require(s.advance(94*minute,true)==AmbientSession.Action.NONE,"Dismiss starts a full new interval");n++;
        require(s.advance(95*minute,true)==AmbientSession.Action.SHOW,"Next card is measured from dismissal");n++;
        require(s.advance(95*minute,false)==AmbientSession.Action.HIDE&&!s.showing(),"Hide immediately when app opens or screen locks");n++;
        s.advance(100*minute,true);
        require(s.advance(104*minute,true)==AmbientSession.Action.NONE,"Hidden card does not return in a burst");n++;
        s.stop();require(s.advance(200*minute,true)==AmbientSession.Action.NONE&&!s.running(),"Stopped session never resumes itself");n++;
        s.start(0,5*minute,10_000);s.advance(0,true);
        require(s.advance(10_000,true)==AmbientSession.Action.SHOW,"Preview uses the same timer and permission path");n++;
        s.dismiss(10_000);require(s.remaining()==5*minute,"Preview does not change the real interval");n++;
        boolean invalid=false;try{s.start(0,0,1);}catch(IllegalArgumentException e){invalid=true;}
        require(invalid,"Invalid timer rejected");n++;
        Recall.State a=new Recall.State("Q:1:1"),b=new Recall.State("Q:1:2"),paused=new Recall.State("Q:1:3");
        a.active=b.active=true;a.due=1;b.due=2;paused.due=0;List<Recall.State> pool=Arrays.asList(a,b,paused);
        String first=s.choose(pool,3,true);s.presented(first);
        require(!first.equals(s.choose(pool,3,true)),"Dismissed overdue item cannot monopolize a session");n++;
        require(a.reviews==0&&b.reviews==0&&a.due==1&&b.due==2,"Selection and presentation cannot rate, enroll or reschedule");n++;
        require(s.choose(pool,0,true)==null,"Due-only session abstains when nothing is due");n++;
        require(s.choose(pool,0,false)!=null,"Explicit interval practice can include enrolled future items");n++;
        require(s.choose(Collections.singleton(paused),3,false)==null,"Paused or untouched targets never appear");n++;
        return n;
    }
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
}
