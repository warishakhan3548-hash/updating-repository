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
        versionCode = 2
        versionName = "0.2.0-network"
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
    implementation(project(":core:network"))
}
