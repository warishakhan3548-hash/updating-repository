plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    namespace = "com.aaris.pharmacy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }
    defaultConfig {
        applicationId = "com.aaris.pharmacy"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    buildTypes {
        release {
            // Development distribution only. Configure an owner release key before store publication.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
flutter { source = "../.." }
dependencies {
    // Bundle Devanagari too: camera OCR must work without a first-run model download.
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}
