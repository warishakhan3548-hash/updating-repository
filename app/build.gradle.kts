plugins {
    id("com.android.application")
}

val codemagicKeystorePath = System.getenv("CM_KEYSTORE_PATH")
val codemagicKeystorePassword = System.getenv("CM_KEYSTORE_PASSWORD")
val codemagicKeyAlias = System.getenv("CM_KEY_ALIAS")
val codemagicKeyPassword = System.getenv("CM_KEY_PASSWORD")
val signingInputs = listOf(
    codemagicKeystorePath,
    codemagicKeystorePassword,
    codemagicKeyAlias,
    codemagicKeyPassword
)
val hasCodemagicSigning = signingInputs.all { !it.isNullOrBlank() }
val hasAnyCodemagicSigningInput = signingInputs.any { !it.isNullOrBlank() }
val requireReleaseSigning =
    providers.gradleProperty("requireReleaseSigning")
        .orNull
        ?.toBooleanStrictOrNull()
        ?: false

if (hasAnyCodemagicSigningInput && !hasCodemagicSigning) {
    throw GradleException(
        "Incomplete release signing configuration. All CM_KEYSTORE_* " +
            "variables must be present together."
    )
}

if (requireReleaseSigning && !hasCodemagicSigning) {
    throw GradleException(
        "A signed release was required, but Codemagic signing is not configured. " +
            "Refusing to produce an installable release artifact."
    )
}

if (requireReleaseSigning && codemagicKeyAlias != "upload") {
    throw GradleException(
        "Unexpected release key alias. The permanent Aaris release alias must be 'upload'."
    )
}

android {
    namespace = "com.aaris.remoteassist"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.aaris.remoteassist"
        minSdk = 26
        targetSdk = 36
        versionCode = 147
        versionName = "1.9.59"
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
            isDebuggable = false
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
