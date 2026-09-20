import java.io.File
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val quranPackDir = rootProject.file("content-packs/quran-core/1.0.4")
val quranPackManifest = quranPackDir.resolve("manifest.json")
val quranPackDatabase = quranPackDir.resolve("content.sqlite")
val quranPackNotice = quranPackDir.resolve("NOTICE.txt")

check(quranPackManifest.isFile) { "Pinned Quran pack manifest is missing: $quranPackManifest" }
val manifestText = quranPackManifest.readText()

fun manifestString(key: String): String {
    val pattern = Regex(""""${Regex.escape(key)}"\s*:\s*"([^"]+)"""")
    return pattern.find(manifestText)?.groupValues?.get(1)
        ?: error("Quran pack manifest is missing string field: $key")
}

fun File.sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().use { input ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
}

val packVersion = manifestString("content_version")
val packSha256 = manifestString("built_sha256")
val packReviewStatus = manifestString("review_status")
val packSourceSha256 = manifestString("source_sha256")

android {
    namespace = "com.aaris.quran"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.aaris.quran"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-dev"
        buildConfigField("String", "QURAN_PACK_VERSION", "\"$packVersion\"")
        buildConfigField("String", "QURAN_PACK_SHA256", "\"$packSha256\"")
        buildConfigField("String", "QURAN_SOURCE_SHA256", "\"$packSourceSha256\"")
        buildConfigField("String", "QURAN_PACK_REVIEW_STATUS", "\"$packReviewStatus\"")
        // Repository publication now verifies real trusted-key Ed25519 signatures,
        // but Android production activation remains fail-closed until this client
        // independently verifies the signed manifest and persists anti-rollback state.
        buildConfigField("boolean", "QURAN_PACK_RELEASE_READY", "false")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            assets.srcDir(quranPackDir)
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.04.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.10.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

val verifyBundledQuranPack by tasks.registering {
    group = "verification"
    description = "Verify the exact Quran content pack bytes bundled into the Android reader."
    inputs.files(quranPackManifest, quranPackDatabase, quranPackNotice)

    doLast {
        check(quranPackDatabase.isFile) { "Pinned Quran pack database is missing" }
        check(quranPackNotice.isFile) { "Pinned Quran attribution notice is missing" }
        val actual = quranPackDatabase.sha256()
        check(actual == packSha256) {
            "Quran pack SHA-256 mismatch: expected $packSha256, got $actual"
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(verifyBundledQuranPack)
}

val verifyReleaseQuranPack by tasks.registering {
    group = "verification"
    description = "Fail closed until Android verifies signed pack metadata and anti-rollback state."

    doLast {
        check(packReviewStatus == "approved") {
            "Release build blocked: quran-core $packVersion is $packReviewStatus, not approved"
        }
        error(
            "Release build blocked: Android device-side trusted-key signature " +
                "verification and anti-rollback persistence are not implemented"
        )
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyReleaseQuranPack)
}
