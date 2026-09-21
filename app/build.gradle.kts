plugins {
    id("com.android.application")
}

android {
    namespace = "com.aaris.shield"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.aaris.shield"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-foundation"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":core:foundation"))
}
