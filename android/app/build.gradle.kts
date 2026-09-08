plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aaris.pharmacy"

    // Keep the compile SDK aligned with the Flutter SDK used by CI/build services.
    // Hard-coding API 37 caused Codemagic to request android-37 and then fail to
    // resolve that target. Flutter 3.47.x currently validates against API 36.
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

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
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Bundle Devanagari too: camera OCR must work without a first-run model download.
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}
