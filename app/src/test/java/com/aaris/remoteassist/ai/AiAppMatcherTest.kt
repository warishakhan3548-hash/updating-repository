package com.aaris.remoteassist.ai

import org.junit.Assert.*
import org.junit.Test

class AiAppMatcherTest {
    private val apps = listOf(
        AiLaunchCandidate("ChatGPT", "com.openai.chatgpt", "Main"),
        AiLaunchCandidate("Google Chrome", "com.android.chrome", "Main"),
        AiLaunchCandidate("Chrome Beta", "com.chrome.beta", "Main"),
        AiLaunchCandidate("Camera", "com.vendor.camera", "Camera")
    )

    @Test fun exactLabelAndPackageAreDeterministic() {
        assertEquals("com.openai.chatgpt", AiAppMatcher.choose("chatgpt", apps)?.packageName)
        assertEquals("com.android.chrome", AiAppMatcher.choose("com.android.chrome", apps)?.packageName)
    }

    @Test fun uniqueShortLabelMaySelectLongerLauncherName() {
        assertEquals("com.android.chrome", AiAppMatcher.choose("google chrome", apps)?.packageName)
    }

    @Test fun ambiguousOrUnrelatedNamesFailClosed() {
        val ambiguous = listOf(
            AiLaunchCandidate("Files Alpha", "a.files", "Main"),
            AiLaunchCandidate("Files Beta", "b.files", "Main")
        )
        assertNull(AiAppMatcher.choose("files", ambiguous))
        assertNull(AiAppMatcher.choose("bank", apps))
        assertNull(AiAppMatcher.choose("   ", apps))
    }
}
