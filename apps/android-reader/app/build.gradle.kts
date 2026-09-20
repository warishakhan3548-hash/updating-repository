import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val pack = Properties().apply {
    rootProject.file("reader-pack.properties").inputStream().use(::load)
}
val packVersion = pack.getProperty("content_version")
val packReviewStatus = pack.getProperty("review_status")
val packDir = rootProject.file("../../content-packs/quran-core/$packVersion")

check(packDir.resolve("content.sqlite").isFile) {
    "Missing pinned Quran content pack: $packDir/content.sqlite"
}
check(packDir.resolve("manifest.json").isFile) {
    "Missing pinned Quran manifest: $packDir/manifest.json"
}
check(packDir.resolve("NOTICE.txt").isFile) {
    "Missing pinned Quran notice: $packDir/NOTICE.txt"
}

android {
    namespace = "com.aaris.quran"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.aaris.quran"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField("String", "QURAN_PACK_ID", "\"${pack.getProperty("pack_id")}\"")
        buildConfigField("String", "QURAN_PACK_VERSION", "\"$packVersion\"")
        buildConfigField("String", "QURAN_PACK_REVIEW_STATUS", "\"$packReviewStatus\"")
        buildConfigField("String", "QURAN_PACK_SHA256", "\"${pack.getProperty("built_sha256")}\"")
        buildConfigField("String", "QURAN_SOURCE_SHA256", "\"${pack.getProperty("source_sha256")}\"")
        buildConfigField("String", "QURAN_NOTICE_SHA256", "\"${pack.getProperty("notice_sha256")}\"")
    }

    sourceSets {
        getByName("main").assets.srcDir(packDir)
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

if (packReviewStatus != "approved") {
    tasks.configureEach {
        if (name.contains("Release", ignoreCase = true)) {
            doFirst {
                throw GradleException(
                    "Release blocked: quran-core@$packVersion is '$packReviewStatus', not approved."
                )
            }
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
}
