plugins {
    id("com.android.application")
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
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
        versionCode = 31
        versionName = "1.7.9"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        buildConfig = true
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
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")

    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-database")

    implementation("io.github.webrtc-sdk:android:150.7871.01")

    testImplementation("junit:junit:4.13.2")
}
