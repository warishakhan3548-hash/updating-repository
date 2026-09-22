package com.aaris.quran.core;

import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/** Small engineering regression set, not a scholarly relevance benchmark or phone benchmark. */
public final class CorpusChecks {
    private static String decode(String s){return new String(Base64.getDecoder().decode(s),StandardCharsets.UTF_8);}
    public static void main(String[] args)throws Exception {
        List<SearchEngine.Document> documents=new ArrayList<>();
        for(String line:Files.readAllLines(Paths.get(args[0]),StandardCharsets.UTF_8)) {
            String[] p=line.split("\t",-1);String text=decode(p[3]);
            documents.add(new SearchEngine.Document(new Ayah(Integer.parseInt(p[0]),Integer.parseInt(p[1]),text,References.sha256(text),Integer.parseInt(p[2])),decode(p[4])));
        }
        long started=System.nanoTime();SearchEngine engine=new SearchEngine(documents);
        if(documents.size()!=6236)throw new AssertionError("Full corpus required");
        String[][] cases={
            {"2:255","Q:2:255"},{"٢:٢٥٥","Q:2:255"},{"۲:۲۵۵","Q:2:255"},
            {"قل هو الله أحد","Q:112:1"},{"قل هو الله احد","Q:112:1"},
            {"قُلْ هُوَ ٱللَّهُ أَحَدٌ","Q:112:1"},{"قل هو الله احذ","Q:112:1"},
            {"مالك يوم الدين","Q:1:4"},{"اهدنا الصراط المستقيم","Q:1:6"},
            {"بسم الله الرحمن الرحيم","Q:1:1"},{"الرحمن الرحيم","Q:1:3"},
            {"إن مع العسر يسرا","Q:94:6"},{"ان مع العسر يسرا","Q:94:6"}
        };
        int hit=0;double reciprocal=0;List<Long> times=new ArrayList<>();
        for(String[] test:cases) {
            SearchEngine.Response response=engine.search(test[0],10);times.add(response.elapsedNanos);
            int rank=-1;for(int i=0;i<response.results.size();i++)if(response.results.get(i).ayah.id.equals(test[1])){rank=i+1;break;}
            if(rank<0)throw new AssertionError("Missing "+test[1]+" for "+test[0]+"; got "+response.results.stream().map(r->r.ayah.id).collect(java.util.stream.Collectors.toList()));
            hit++;reciprocal+=1.0/rank;
        }
        String[] absent={"quantum flux capacitor","blockchain spaceship","galactic teleportation","neutrino supercomputer",
            "unicorn telescope","cryptographic nanobot","स्मार्टफोन ब्लूटूथ","क्वांटम कम्प्यूटर","مصطلحغيرموجودتجريبيا",
            "999:999","2:999","0:1","115:1","1:8","teleporting llama","abcdefzzzzz","फ्लक्स कैपेसिटर",
            "ہولوگرافک کمپیوٹر","extraterrestrial skateboard","प्लूटोनियम स्मार्टवॉच"};
        for(String query:absent)if(!engine.search(query,10).results.isEmpty())throw new AssertionError("False positive for engineered absent query: "+query);
        // Every coordinate resolves to the exact archived text, including prefatory basmala.
        for(SearchEngine.Document d:documents){SearchEngine.Response r=engine.search(d.ayah.id,1);
            if(r.results.size()!=1||!r.results.get(0).ayah.arabic.equals(d.ayah.arabic))throw new AssertionError("Coordinate identity drift");}
        Collections.sort(times);
        System.out.printf(Locale.ROOT,"Corpus checks: 6,236 coordinates; %d/%d retrieval cases; %d absent queries; MRR@10 %.3f; JVM p95 %.1f ms; total %.1f s%n",
            hit,cases.length,absent.length,reciprocal/cases.length,times.get((int)Math.ceil(times.size()*.95)-1)/1e6,(System.nanoTime()-started)/1e9);
    }
}
