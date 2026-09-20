import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val quranPackDir = rootProject.file("../content-packs/quran-core/1.0.4")
val quranManifest = quranPackDir.resolve("manifest.json")
val quranDatabase = quranPackDir.resolve("content.sqlite")

check(quranManifest.isFile) { "Missing pinned Quran pack manifest: " + quranManifest.path }
check(quranDatabase.isFile) { "Missing pinned Quran pack database: " + quranDatabase.path }

@Suppress("UNCHECKED_CAST")
val quranManifestData = JsonSlurper().parse(quranManifest) as Map<String, Any?>

fun manifestString(key: String): String =
    quranManifestData[key] as? String
        ?: error("Missing string " + key + " in " + quranManifest.path)

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

val quranPackVersion = manifestString("content_version")
val quranPackSha256 = manifestString("built_sha256")
val quranSourceAttribution = manifestString("source_attribution")
val quranSourceLicenceSha256 = manifestString("source_licence_sha256")
val quranSourceProvenanceSha256 = manifestString("source_provenance_sha256")

check(quranPackVersion == "1.0.4") { "Unexpected Quran content pack version" }
check(sha256(quranDatabase) == quranPackSha256) {
    "Pinned Quran pack SHA-256 does not match its manifest"
}

android {
    namespace = "com.aaris.quran"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.aaris.quran"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField("String", "QURAN_PACK_VERSION", JsonOutput.toJson(quranPackVersion))
        buildConfigField("String", "QURAN_PACK_SHA256", JsonOutput.toJson(quranPackSha256))
        buildConfigField("String", "QURAN_SOURCE_LICENCE_SHA256", JsonOutput.toJson(quranSourceLicenceSha256))
        buildConfigField("String", "QURAN_SOURCE_PROVENANCE_SHA256", JsonOutput.toJson(quranSourceProvenanceSha256))
        buildConfigField(
            "String",
            "QURAN_SOURCE_ATTRIBUTION",
            JsonOutput.toJson(quranSourceAttribution),
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets.named("main") {
        assets.srcDir(quranPackDir)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)

    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.11.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
