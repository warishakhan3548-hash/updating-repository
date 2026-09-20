package com.aaris.quran.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aaris.quran.BuildConfig
import com.aaris.quran.data.QuranAyah

@Composable
fun AarisQuranTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(),
        content = content,
    )
}

@Composable
fun ReaderScreen(
    state: ReaderUiState,
    onSelectSurah: (Int) -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onRetry: () -> Unit,
    onOpenSourceLink: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pickerOpen by remember { mutableStateOf(false) }
    var sourceOpen by remember { mutableStateOf(false) }

    Column(
        modifier = modifier.fillMaxSize(),
    ) {
        Surface(shadowElevation = 2.dp) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = "Quran",
                        style = MaterialTheme.typography.headlineSmall,
                    )
                    TextButton(
                        onClick = { sourceOpen = true },
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text("Source")
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    OutlinedButton(
                        onClick = onPrevious,
                        enabled = state.surah > 1 && !state.loading,
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text("Previous")
                    }

                    Box {
                        Button(
                            onClick = { pickerOpen = true },
                            enabled = !state.loading,
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) {
                            Text("Surah " + state.surah)
                        }
                        DropdownMenu(
                            expanded = pickerOpen,
                            onDismissRequest = { pickerOpen = false },
                        ) {
                            for (surah in 1..114) {
                                DropdownMenuItem(
                                    text = { Text("Surah " + surah) },
                                    onClick = {
                                        pickerOpen = false
                                        onSelectSurah(surah)
                                    },
                                )
                            }
                        }
                    }

                    OutlinedButton(
                        onClick = onNext,
                        enabled = state.surah < 114 && !state.loading,
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text("Next")
                    }
                }
            }
        }

        when {
            state.loading -> LoadingState()
            state.error != null -> ErrorState(onRetry)
            else -> AyahList(
                surah = state.surah,
                ayahs = state.ayahs,
            )
        }
    }

    if (sourceOpen) {
        SourceDialog(
            onDismiss = { sourceOpen = false },
            onOpenSourceLink = onOpenSourceLink,
        )
    }
}

@Composable
private fun LoadingState() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun ErrorState(onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "The verified Quran content pack could not be opened.",
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onRetry,
            modifier = Modifier
                .padding(top = 16.dp)
                .heightIn(min = 48.dp),
        ) {
            Text("Retry")
        }
    }
}

@Composable
private fun AyahList(
    surah: Int,
    ayahs: List<QuranAyah>,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        items(
            items = ayahs,
            key = { it.ayahId },
        ) { ayah ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp),
            ) {
                Text(
                    text = surah.toString() + ":" + ayah.ayah,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
                Text(
                    text = ayah.originalText,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.End,
                    style = TextStyle(
                        color = MaterialTheme.colorScheme.onBackground,
                        fontSize = 30.sp,
                        lineHeight = 52.sp,
                        textDirection = TextDirection.ContentOrRtl,
                    ),
                )
            }
            HorizontalDivider()
        }
    }
}

@Composable
private fun SourceDialog(
    onDismiss: () -> Unit,
    onOpenSourceLink: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Quran text source") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(BuildConfig.QURAN_SOURCE_ATTRIBUTION)
                Text("Local content pack " + BuildConfig.QURAN_PACK_VERSION)
                Text("Arabic text is rendered from the verified local evidence pack.")
            }
        },
        confirmButton = {
            TextButton(
                onClick = onOpenSourceLink,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text("Open tanzil.net")
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text("Close")
            }
        },
    )
}
