plugins {
    id("com.android.library")
}

android {
    namespace = "com.aaris.shield.network"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":core:foundation"))
    testImplementation("junit:junit:4.13.2")
}
