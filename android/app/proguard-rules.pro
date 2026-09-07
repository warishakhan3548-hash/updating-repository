# The ML Kit Flutter bridge compiles optional script branches but this app only
# exposes Latin and Devanagari. These three optional models are deliberately not
# bundled. Do not suppress warnings for the Latin/Devanagari or barcode classes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
