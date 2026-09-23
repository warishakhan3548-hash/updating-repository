package com.aaris.quran;

import android.content.Context;
import android.graphics.Typeface;
import com.aaris.quran.core.*;
import java.util.*;

/** Complete source records with attributed translations; no generated religious interpretation. */
final class ResearchExport {
    static final String PROMPT="Analyze only the attached evidence. Cite the collection and record or ayah number for every conclusion. Keep each narration and its grading separate. Do not combine excerpts into a new quotation. Distinguish text-match levels from authenticity. State uncertainty and differences; do not invent missing translations or references.";
    static byte[] quran(Context c,ContentStore store,TranslationStore translations,String edition,List<Ayah> ayahs,Map<String,String> matches,String query)throws Exception{
        Typeface arabic=Typeface.createFromAsset(c.getAssets(),"fonts/AmiriQuran.ttf");
        try(EvidenceExporter.Pages pages=new EvidenceExporter.Pages("Aaris · Quran research")){
            header(pages,query,ayahs.size());
            for(Ayah a:ayahs){
                if(!References.sha256(a.arabic).equals(a.sha256))throw new IllegalStateException("Source hash mismatch");
                pages.block("["+a.id+"] · "+store.surah(a.surah).name+"\n"+matches.getOrDefault(a.id,"Selected source; no match-level claim"),Typeface.DEFAULT_BOLD,12,false);
                pages.block(a.arabic,arabic,24,true);
                TranslationStore.Entry entry=translations==null?null:translations.get(edition,a.id);
                if(entry!=null){pages.block(entry.text,"ur".equals(entry.edition.language)?arabic:Typeface.DEFAULT,14,"ur".equals(entry.edition.language));
                    if(!entry.footnotes.isEmpty())pages.block(entry.footnotes,Typeface.DEFAULT,11,"ur".equals(entry.edition.language));
                    pages.block(entry.edition.attribution()+"\n"+entry.edition.description,Typeface.DEFAULT,10,false);}
                pages.block("Arabic SHA-256: "+a.sha256,Typeface.DEFAULT,9,false);
            }
            pages.block(ContentStore.asset(c,"licenses/TANZIL.txt"),Typeface.DEFAULT,9,false);
            if(translations!=null)pages.block(translations.notice+"\nTranslation pack: "+translations.packHash,Typeface.DEFAULT,9,false);
            return pages.bytes();
        }
    }
    static byte[] hadith(Context c,HadithStore store,List<HadithStore.Hit> hits,String language,String query)throws Exception{
        Typeface arabic=Typeface.createFromAsset(c.getAssets(),"fonts/AmiriQuran.ttf");
        try(EvidenceExporter.Pages pages=new EvidenceExporter.Pages("Aaris · Hadith research")){
            header(pages,query,hits.size());
            pages.block(store.sourceName+" · "+store.sourceVersion+"\nPack: "+store.packHash+"\n"+store.redistributionBasis,Typeface.DEFAULT,10,false);
            for(HadithStore.Hit hit:hits){
                HadithStore.Record record=hit.record;HadithStore.CollectionInfo collection=store.collection(record.collectionId);
                pages.block((collection==null?record.collectionId:collection.nameEn)+" · Hadith "+record.number+"\n["+record.id+"]",Typeface.DEFAULT_BOLD,13,false);
                pages.block(hit.match.band+" TEXT MATCH · "+hit.match.matched+" / "+hit.match.total+" query words",Typeface.DEFAULT,10,false);
                pages.block(record.arabic,arabic,22,true);
                HadithStore.DisplayTranslation translated=store.translation(record,language);
                if(translated!=null){pages.block(translated.text,"ur".equals(translated.language)?arabic:Typeface.DEFAULT,14,"ur".equals(translated.language));pages.block(translated.provenance,Typeface.DEFAULT,10,false);}
                else pages.block("No translation is installed for this record.",Typeface.DEFAULT,10,false);
                List<String> grades=store.grades(record.id);pages.block(grades.isEmpty()?"No individual grading is recorded in this pack.":String.join("\n",grades),Typeface.DEFAULT,10,false);
                pages.block("Book: "+String.valueOf(record.bookId)+" · Chapter: "+String.valueOf(record.chapterId)+"\n"+String.join("\n",store.references(record.id))+"\nSource: "+record.sourceRef+"\nArabic SHA-256: "+References.sha256(record.arabic),Typeface.DEFAULT,9,false);
            }
            return pages.bytes();
        }
    }
    private static void header(EvidenceExporter.Pages pages,String query,int count){pages.block("AARIS\nResearch evidence",Typeface.DEFAULT_BOLD,22,false);pages.block("Search: "+query+"\nExported records: "+count+"\n"+PROMPT,Typeface.DEFAULT,11,false);}
}
