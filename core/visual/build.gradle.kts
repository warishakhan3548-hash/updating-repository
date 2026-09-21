import java.io.File
import java.net.URI
import java.security.MessageDigest
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

plugins {
    id("com.android.library")
}

abstract class PrepareVisualModelTask : DefaultTask() {
    @get:Input
    abstract val sourceUrl: Property<String>

    @get:Input
    abstract val expectedBytes: Property<Long>

    @get:Input
    abstract val expectedGitBlobSha1: Property<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun prepare() {
        val bytesExpected = expectedBytes.get()
        val hashExpected = expectedGitBlobSha1.get()
        val output = outputDirectory.file("aaris_shield/open_nsfw.tflite").get().asFile
        output.parentFile.mkdirs()
        val partial = File(output.parentFile, "${output.name}.part")
        partial.delete()

        try {
            val connection = URI(sourceUrl.get()).toURL().openConnection().apply {
                connectTimeout = 30_000
                readTimeout = 90_000
                setRequestProperty("User-Agent", "Aaris-Shield-build")
            }
            connection.getInputStream().use { input ->
                partial.outputStream().buffered().use { sink -> input.copyTo(sink) }
            }

            check(partial.length() == bytesExpected) {
                "OpenNSFW model size mismatch: ${partial.length()} != $bytesExpected"
            }

            val digest = MessageDigest.getInstance("SHA-1")
            digest.update("blob $bytesExpected\u0000".toByteArray(Charsets.UTF_8))
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
            check(actual == hashExpected) {
                "OpenNSFW model Git blob hash mismatch: $actual"
            }

            if (output.exists()) output.delete()
            check(partial.renameTo(output)) { "Could not atomically publish verified visual model" }
        } finally {
            partial.delete()
        }
    }
}

val prepareVisualModel = tasks.register<PrepareVisualModelTask>("prepareVisualModel") {
    group = "verification"
    description = "Fetches and integrity-checks the pinned local OpenNSFW model."
    sourceUrl.set(
        "https://raw.githubusercontent.com/devzwy/open_nsfw_android/" +
            "a1b49e0cf4d28c2f67bf60a87005a7c220cde487/data/nsfw.tflite",
    )
    expectedBytes.set(23_591_976L)
    expectedGitBlobSha1.set("9583ed20d47ded82738891744c7983b3fe1f2bd3")
    outputDirectory.set(layout.buildDirectory.dir("generated/visualModelAssets"))
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

    androidResources {
        noCompress += "tflite"
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            prepareVisualModel,
            PrepareVisualModelTask::outputDirectory,
        )
    }
}

dependencies {
    implementation(project(":core:foundation"))
    implementation("com.google.ai.edge.litert:litert:1.4.2")
    testImplementation("junit:junit:4.13.2")
}
