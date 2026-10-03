plugins {
    id("com.android.application")
}

val codemagicKeystorePath = System.getenv("CM_KEYSTORE_PATH")
val codemagicKeystorePassword = System.getenv("CM_KEYSTORE_PASSWORD")
val codemagicKeyAlias = System.getenv("CM_KEY_ALIAS")
val codemagicKeyPassword = System.getenv("CM_KEY_PASSWORD")
val hasCodemagicSigning = listOf(
    codemagicKeystorePath,
    codemagicKeystorePassword,
    codemagicKeyAlias,
    codemagicKeyPassword
).all { !it.isNullOrBlank() }

android {
    namespace = "com.aaris.remoteassist"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.aaris.remoteassist"
        minSdk = 26
        targetSdk = 36
        versionCode = 93
        versionName = "1.9.5"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { buildConfig = true }
    testOptions.unitTests.all {
        it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    signingConfigs {
        if (hasCodemagicSigning) {
            create("release") {
                storeFile = file(codemagicKeystorePath!!)
                storePassword = codemagicKeystorePassword
                keyAlias = codemagicKeyAlias
                keyPassword = codemagicKeyPassword
            }
        }
    }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            if (hasCodemagicSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
    packaging {
        resources.excludes += setOf(
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE*",
            "META-INF/NOTICE*"
        )
    }
}

dependencies {
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("androidx.fragment:fragment-ktx:1.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.github.webrtc-sdk:android:150.7871.01")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
