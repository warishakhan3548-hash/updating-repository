package com.aaris.quran;

import android.content.Context;
import android.graphics.*;
import android.graphics.pdf.PdfDocument;
import android.text.*;
import com.aaris.quran.core.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

/** Human and machine exports are generated from the same read-only snapshot. */
final class EvidenceExporter {
    static final class Bundle {String id,json,text;byte[] zip;}
    static Bundle build(Context context,ContentStore store,Collection<String> selection,String query,Map<String,JSONObject> traces) throws Exception {
        if(selection.isEmpty()||selection.size()>50)throw new IllegalArgumentException("Choose 1–50 ayat");
        Bundle out=new Bundle();out.id=UUID.randomUUID().toString();JSONArray records=new JSONArray();List<Ayah> ayahs=new ArrayList<>();
        String notice=ContentStore.asset(context,"licenses/TANZIL.txt");
        StringBuilder txt=new StringBuilder("AARIS QURAN — EVIDENCE SNAPSHOT\nBundle: "+out.id+"\nQuery: "+query+"\n\n"+References.reasoningPrompt()+"\n\n");
        for(String id:selection){Ayah a=store.ayah(id);if(a==null)throw new IllegalArgumentException("Unknown citation");
            if(!References.sha256(a.arabic).equals(a.sha256))throw new IllegalStateException("Source text hash mismatch");
            JSONObject trace=traces.get(a.id);if(trace==null)trace=new JSONObject().put("selection_origin","SELECTION_WITHOUT_RETRIEVAL_TRACE");
            records.put(new JSONObject().put("citation_id",a.id).put("surah",a.surah).put("ayah",a.number).put("arabic",a.arabic).put("sha256",a.sha256).put("source","Tanzil Uthmani 1.1").put("source_url","https://tanzil.net/").put("retrieval",trace));
            ayahs.add(a);txt.append('[').append(a.id).append("] ").append(store.surah(a.surah).name).append('\n').append(a.arabic).append('\n').append(selectionNote(trace)).append("\n\n");
        }
        txt.append(notice);
        JSONObject evidence=new JSONObject().put("schema",1).put("bundle_id",out.id).put("query",query).put("records",records).put("instructions",References.reasoningPrompt()).put("notice",notice)
            .put("quran_pack_sha256",store.packHash).put("retrieval_engine",SearchEngine.VERSION);
        out.json=evidence.toString(2);out.text=txt.toString();
        byte[] json=out.json.getBytes(StandardCharsets.UTF_8),text=out.text.getBytes(StandardCharsets.UTF_8);
        byte[] pdf=pdf(context,store,ayahs,notice,out.id,traces);
        JSONObject files=new JSONObject().put("evidence.json",hash(json)).put("evidence.txt",hash(text)).put("evidence.pdf",hash(pdf));
        JSONObject manifest=new JSONObject().put("schema_version",1).put("bundle_id",out.id).put("created_at",System.currentTimeMillis())
            .put("quran_pack_sha256",store.packHash).put("retrieval_engine",SearchEngine.VERSION).put("query",query).put("files",files)
            .put("verification_scope","Reference existence and supported exact quotes only; no religious conclusion verification.");
        // No self-referential hash: hash the file manifest, not a ZIP containing its own hash.
        StringBuilder canonical=new StringBuilder();for(String name:new String[]{"evidence.json","evidence.pdf","evidence.txt"})canonical.append(name).append('\t').append(files.getString(name)).append('\n');
        manifest.put("payload_manifest_format","filename<TAB>sha256<LF>, filenames sorted ascending; UTF-8");
        manifest.put("payload_manifest_sha256",References.sha256(canonical.toString()));
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(ZipOutputStream zip=new ZipOutputStream(bytes)) {
            put(zip,"evidence.json",json);put(zip,"evidence.txt",text);put(zip,"evidence.pdf",pdf);
            put(zip,"manifest.json",manifest.toString(2).getBytes(StandardCharsets.UTF_8));
        }
        out.zip=bytes.toByteArray();return out;
    }
    private static String hash(byte[] bytes) throws Exception {byte[] h=MessageDigest.getInstance("SHA-256").digest(bytes);StringBuilder b=new StringBuilder();for(byte x:h)b.append(String.format(Locale.ROOT,"%02x",x&255));return b.toString();}
    private static void put(ZipOutputStream zip,String path,byte[] bytes)throws IOException {ZipEntry entry=new ZipEntry(path);entry.setTime(0);zip.putNextEntry(entry);zip.write(bytes);zip.closeEntry();}
    private static String selectionNote(JSONObject trace){
        if(trace==null)return "Selection: retrieval provenance unavailable.";
        String origin=trace.optString("selection_origin","");
        if(origin.equals("SEARCH_FRAGMENT"))return "Selection: exact source fragment only. The whole query was not found as one quotation. See evidence.json for original query, exact spans and unmatched words.";
        if(origin.equals("SEARCH"))return "Selection: "+trace.optString("strength","related")+" retrieval. This does not verify a claim or interpretation.";
        return "Selection: "+origin+". No search-match claim.";
    }
    private static byte[] pdf(Context context,ContentStore store,List<Ayah> ayahs,String notice,String id,Map<String,JSONObject> traces)throws IOException {
        try(Pages pages=new Pages()) {
            pages.block("AARIS QURAN\nEvidence snapshot",Typeface.DEFAULT_BOLD,20,false);
            pages.block("Bundle "+id+"\nSource: Tanzil Uthmani 1.1 · https://tanzil.net/\n",Typeface.DEFAULT,10,false);
            pages.block("Each citation below is a separate source record. Search fragments must not be joined into a new quotation. References and exact quotes can be checked; interpretation is not verified.",Typeface.DEFAULT,10,false);
            Typeface arabic=Typeface.createFromAsset(context.getAssets(),"fonts/AmiriQuran.ttf");
            for(Ayah a:ayahs){pages.block("["+a.id+"]  "+store.surah(a.surah).name,Typeface.DEFAULT_BOLD,12,false);pages.block(a.arabic,arabic,24,true);pages.block(selectionNote(traces.get(a.id)),Typeface.DEFAULT,10,false);}
            pages.block("Source notice\n"+notice,Typeface.DEFAULT,10,false);
            return pages.bytes();
        }
    }
    static final class Pages implements AutoCloseable {
        final PdfDocument doc=new PdfDocument();PdfDocument.Page page;float y=44;int number;
        final String footer;
        Pages(){this("Tanzil Project · https://tanzil.net/");}
        Pages(String footer){this.footer=footer;next();}
        void finish(){if(page!=null){Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);p.setTextSize(9);p.setColor(Color.DKGRAY);page.getCanvas().drawText(footer+"     |     "+number,40,817,p);doc.finishPage(page);page=null;}}
        void next(){finish();page=doc.startPage(new PdfDocument.PageInfo.Builder(595,842,++number).create());y=44;}
        void block(String text,Typeface font,int size,boolean rtl){
            TextPaint paint=new TextPaint(Paint.ANTI_ALIAS_FLAG);paint.setColor(Color.BLACK);paint.setTypeface(font);paint.setTextSize(size);
            StaticLayout layout=StaticLayout.Builder.obtain(text,0,text.length(),paint,515).setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setTextDirection(rtl?TextDirectionHeuristics.RTL:TextDirectionHeuristics.LTR).setIncludePad(true).setLineSpacing(rtl?8:3,1).build();
            int from=0;while(from<layout.getLineCount()){
                if(790-y<layout.getLineBottom(from)-layout.getLineTop(from)+8)next();
                int to=from;int top=layout.getLineTop(from);
                while(to<layout.getLineCount()&&layout.getLineBottom(to)-top<=790-y)to++;
                if(to==from){next();continue;}
                int height=layout.getLineBottom(to-1)-top;Canvas c=page.getCanvas();c.save();c.clipRect(40,y,555,y+height);c.translate(40,y-top);layout.draw(c);c.restore();y+=height;from=to;if(from<layout.getLineCount())next();
            }y+=16;
        }
        byte[] bytes()throws IOException {finish();ByteArrayOutputStream out=new ByteArrayOutputStream();doc.writeTo(out);return out.toByteArray();}
        public void close(){finish();doc.close();}
    }
}
