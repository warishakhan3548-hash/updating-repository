plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

val localKeyProperties = java.util.Properties()
val localKeyPropertiesFile = rootProject.file("key.properties")
if (localKeyPropertiesFile.exists()) {
    localKeyPropertiesFile.inputStream().use(localKeyProperties::load)
}

fun signingValue(envName: String, propertyName: String): String? =
    System.getenv(envName)?.trim()?.takeIf { it.isNotEmpty() }
        ?: localKeyProperties.getProperty(propertyName)?.trim()?.takeIf { it.isNotEmpty() }

val releaseStoreFilePath = signingValue("CM_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("CM_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("CM_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("CM_KEY_PASSWORD", "keyPassword")
val releaseSigningReady = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

// Debug builds must remain easy to run locally and in GitHub CI, but a release
// artifact must never silently fall back to Android's debug signing identity.
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseTaskRequested && !releaseSigningReady) {
    throw org.gradle.api.GradleException(
        "Permanent release signing credentials are missing. " +
            "Use Codemagic android_signing (CM_KEYSTORE_*) or an ignored android/key.properties file.",
    )
}

android {
    namespace = "com.aaris.pharmacy"

    // Keep the compile SDK aligned with the Flutter SDK used by CI/build services.
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

    signingConfigs {
        create("release") {
            if (releaseSigningReady) {
                val configuredStore = java.io.File(releaseStoreFilePath!!)
                storeFile = if (configuredStore.isAbsolute) {
                    configuredStore
                } else {
                    rootProject.file(releaseStoreFilePath)
                }
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
