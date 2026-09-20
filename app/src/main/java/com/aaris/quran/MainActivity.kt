package com.aaris.quran

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.lifecycle.ViewModelProvider
import com.aaris.quran.data.PackagedQuranRepository
import com.aaris.quran.ui.ReaderRoute
import com.aaris.quran.ui.ReaderViewModel

class MainActivity : ComponentActivity() {
    private lateinit var readerViewModel: ReaderViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readerViewModel = ViewModelProvider(
            this,
            ReaderViewModel.Factory(PackagedQuranRepository(applicationContext)),
        )[ReaderViewModel::class.java]

        enableEdgeToEdge()
        setContent {
            MaterialTheme(
                colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(),
            ) {
                ReaderRoute(readerViewModel)
            }
        }
    }
}
