package com.aaris.quran

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.aaris.quran.ui.AarisQuranTheme
import com.aaris.quran.ui.ReaderScreen
import com.aaris.quran.ui.ReaderViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            AarisQuranTheme {
                val repository = (application as QuranApplication).quranRepository
                val factory = remember(repository) {
                    ReaderViewModel.factory(repository)
                }
                val readerViewModel: ReaderViewModel = viewModel(factory = factory)
                val state by readerViewModel.uiState.collectAsStateWithLifecycle()

                ReaderScreen(
                    state = state,
                    onSelectSurah = readerViewModel::selectSurah,
                    onPrevious = readerViewModel::previousSurah,
                    onNext = readerViewModel::nextSurah,
                    onRetry = readerViewModel::retry,
                    onOpenSourceLink = {
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
