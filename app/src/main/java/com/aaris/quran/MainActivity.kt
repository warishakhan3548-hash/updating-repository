package com.aaris.quran

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import com.aaris.quran.data.QuranReaderRepository
import com.aaris.quran.ui.QuranReaderScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val repository = QuranReaderRepository(applicationContext)

        setContent {
            MaterialTheme(
                colorScheme = if (isSystemInDarkTheme()) {
                    darkColorScheme()
                } else {
                    lightColorScheme()
                },
            ) {
                QuranReaderScreen(
                    repository = repository,
                    onOpenSource = {
                        runCatching {
                            startActivity(
                                Intent(
                                    Intent.ACTION_VIEW,
                                    Uri.parse("https://tanzil.net/"),
                                ),
                            )
                        }
                    },
                )
            }
        }
    }
}
