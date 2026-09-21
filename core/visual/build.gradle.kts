import java.net.URI
import java.security.MessageDigest

plugins {
    id("com.android.library")
}

val openNsfwSource =
    "https://raw.githubusercontent.com/devzwy/open_nsfw_android/" +
        "a1b49e0cf4d28c2f67bf60a87005a7c220cde487/data/nsfw.tflite"
val expectedModelBytes = 23_591_976L
val expectedGitBlobSha1 = "9583ed20d47ded82738891744c7983b3fe1f2bd3"
val generatedVisualAssets = layout.buildDirectory.dir("generated/visualModelAssets")
val generatedModel = generatedVisualAssets.map { it.file("aaris_shield/open_nsfw.tflite") }

val prepareVisualModel by tasks.registering {
    group = "verification"
    description = "Fetches and integrity-checks the pinned local OpenNSFW model."
    inputs.property("source", openNsfwSource)
    inputs.property("expectedBytes", expectedModelBytes)
    inputs.property("expectedGitBlobSha1", expectedGitBlobSha1)
    outputs.file(generatedModel)

    doLast {
        val output = generatedModel.get().asFile
        output.parentFile.mkdirs()
        val partial = output.resolveSibling("${output.name}.part")
        partial.delete()

        try {
            val connection = URI(openNsfwSource).toURL().openConnection().apply {
                connectTimeout = 30_000
                readTimeout = 90_000
                setRequestProperty("User-Agent", "Aaris-Shield-build")
            }
            connection.getInputStream().use { input ->
                partial.outputStream().buffered().use { sink -> input.copyTo(sink) }
            }

            check(partial.length() == expectedModelBytes) {
                "OpenNSFW model size mismatch: ${partial.length()} != $expectedModelBytes"
            }

            val digest = MessageDigest.getInstance("SHA-1")
            digest.update("blob $expectedModelBytes\u0000".toByteArray(Charsets.UTF_8))
            partial.inputStream().buffered().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            val actual = digest.digest().joinToString("") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }
            check(actual == expectedGitBlobSha1) {
                "OpenNSFW model Git blob hash mismatch: $actual"
            }

            if (output.exists()) output.delete()
            check(partial.renameTo(output)) { "Could not atomically publish verified visual model" }
        } finally {
            partial.delete()
        }
    }
}

android {
    namespace = "com.aaris.shield.visual"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets.getByName("main").assets.srcDir(generatedVisualAssets)
    androidResources {
        noCompress += "tflite"
    }
}

tasks.named("preBuild") {
    dependsOn(prepareVisualModel)
}

dependencies {
    implementation(project(":core:foundation"))
    implementation("com.google.ai.edge.litert:litert:1.4.2")
    testImplementation("junit:junit:4.13.2")
}
