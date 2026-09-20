package com.aaris.quran.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.aaris.quran.data.QuranSearchHit
import com.aaris.quran.data.QuranSearchMatchKind
import com.aaris.quran.model.QuranAyah

@Composable
fun ReaderRoute(viewModel: ReaderViewModel, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    ReaderScreen(
        state = state,
        onPreviousSurah = viewModel::previousSurah,
        onNextSurah = viewModel::nextSurah,
        onSelectSurah = viewModel::selectSurah,
        onSearchQueryChange = viewModel::updateSearchQuery,
        onOpenSearchResult = viewModel::openSearchResult,
        onRetry = viewModel::retry,
        modifier = modifier,
    )
}

@Composable
fun ReaderScreen(
    state: ReaderUiState,
    onPreviousSurah: () -> Unit,
    onNextSurah: () -> Unit,
    onSelectSurah: (Int) -> Unit,
    onSearchQueryChange: (String) -> Unit,
    onOpenSearchResult: (QuranSearchHit) -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showSurahChooser by remember { mutableStateOf(false) }
    val ayahListState = rememberLazyListState()

    LaunchedEffect(state.surah, state.targetAyah, state.ayahs.size) {
        val target = state.targetAyah ?: return@LaunchedEffect
        val index = state.ayahs.indexOfFirst { it.ayah == target }
        if (index >= 0) ayahListState.scrollToItem(index)
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        Text(
            text = "Quran",
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier
                .padding(horizontal = 20.dp, vertical = 12.dp)
                .semantics { heading() },
        )
        OutlinedTextField(
            value = state.searchQuery,
            onValueChange = onSearchQueryChange,
            singleLine = true,
            label = { Text("Search Quran") },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 4.dp),
        )

        if (state.searchQuery.isBlank()) {
            TextButton(
                onClick = { showSurahChooser = true },
                enabled = !state.isLoading,
                modifier = Modifier
                    .padding(horizontal = 8.dp)
                    .heightIn(min = 48.dp)
                    .semantics { stateDescription = "Current surah" },
            ) {
                Text(
                    text = "Surah ${state.surah} ▾",
                    style = MaterialTheme.typography.titleMedium,
                )
            }
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            when {
                state.searchQuery.isNotBlank() -> {
                    SearchResultsContent(
                        state = state,
                        onOpenSearchResult = onOpenSearchResult,
                    )
                }
                state.isLoading -> CircularProgressIndicator(
                    Modifier
                        .align(Alignment.Center)
                        .semantics { contentDescription = "Loading Quran" },
                )
                state.errorMessage != null -> {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.align(Alignment.Center).padding(24.dp),
                    ) {
                        val errorText = state.errorMessage
                        Text(
                            text = errorText,
                            modifier = Modifier.semantics {
                                error(errorText)
                                liveRegion = LiveRegionMode.Polite
                            },
                        )
                        TextButton(
                            onClick = onRetry,
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) {
                            Text("Try again")
                        }
                    }
                }
                else -> {
                    LazyColumn(
                        state = ayahListState,
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(state.ayahs, key = { it.ayahId }) { ayah ->
                            AyahRow(ayah)
                            HorizontalDivider()
                        }
                    }
                }
            }
        }

        if (state.searchQuery.isBlank()) {
            Row(
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(
                    onClick = onPreviousSurah,
                    enabled = state.surah > 1 && !state.isLoading,
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text("Previous Surah")
                }
                TextButton(
                    onClick = onNextSurah,
                    enabled = state.surah < 114 && !state.isLoading,
                    modifier = Modifier.heightIn(min = 48.dp),
                ) {
                    Text("Next Surah")
                }
            }
        }
    }

    if (showSurahChooser) {
        SurahChooserDialog(
            currentSurah = state.surah,
            onDismiss = { showSurahChooser = false },
            onSelect = { surah ->
                showSurahChooser = false
                onSelectSurah(surah)
            },
        )
    }
}

@Composable
private fun SearchResultsContent(
    state: ReaderUiState,
    onOpenSearchResult: (QuranSearchHit) -> Unit,
) {
    when {
        state.isSearching -> {
            Box(Modifier.fillMaxSize()) {
                CircularProgressIndicator(
                    Modifier
                        .align(Alignment.Center)
                        .semantics { contentDescription = "Searching Quran" },
                )
            }
        }
        state.searchErrorMessage != null -> {
            Box(Modifier.fillMaxSize()) {
                val errorText = state.searchErrorMessage
                Text(
                    text = errorText,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(24.dp)
                        .semantics {
                            error(errorText)
                            liveRegion = LiveRegionMode.Polite
                        },
                )
            }
        }
        state.searchResults.isEmpty() -> {
            Box(Modifier.fillMaxSize()) {
                Text(
                    text = "No reliable match found.",
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(24.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
        else -> {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(state.searchResults, key = { it.ayah.ayahId }) { hit ->
                    val ayah = hit.ayah
                    TextButton(
                        onClick = { onOpenSearchResult(hit) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .padding(horizontal = 8.dp)
                            .semantics {
                                if (
                                    hit.matchKind ==
                                        QuranSearchMatchKind.APPROXIMATE_SPELLING
                                ) {
                                    stateDescription = "Approximate spelling match"
                                }
                            },
                    ) {
                        Column(
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = "Surah ${ayah.surah} • Ayah ${ayah.ayah}",
                                style = MaterialTheme.typography.labelMedium,
                            )
                            if (hit.matchKind == QuranSearchMatchKind.APPROXIMATE_SPELLING) {
                                Text(
                                    text = "Approximate spelling match",
                                    style = MaterialTheme.typography.labelSmall,
                                )
                            }
                            Text(
                                text = ayah.originalText,
                                style = MaterialTheme.typography.bodyLarge.copy(
                                    fontSize = 26.sp,
                                    lineHeight = 42.sp,
                                    textDirection = TextDirection.ContentOrRtl,
                                ),
                            )
                        }
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun SurahChooserDialog(
    currentSurah: Int,
    onDismiss: () -> Unit,
    onSelect: (Int) -> Unit,
) {
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = (currentSurah - 1).coerceIn(0, 113),
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = "Choose Surah",
                modifier = Modifier.semantics { heading() },
            )
        },
        text = {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp),
            ) {
                items((1..114).toList(), key = { it }) { surah ->
                    TextButton(
                        onClick = { onSelect(surah) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp),
                    ) {
                        Text(
                            text = if (surah == currentSurah) {
                                "Surah $surah — current"
                            } else {
                                "Surah $surah"
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text("Close")
            }
        },
    )
}

@Composable
private fun AyahRow(ayah: QuranAyah) {
    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
    ) {
        Text(
            text = "Ayah ${ayah.ayah}",
            style = MaterialTheme.typography.labelMedium,
        )
        Text(
            text = ayah.originalText,
            style = MaterialTheme.typography.bodyLarge.copy(
                fontSize = 32.sp,
                lineHeight = 54.sp,
                textDirection = TextDirection.ContentOrRtl,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .semantics {
                    contentDescription =
                        "Surah ${ayah.surah}, ayah ${ayah.ayah}. ${ayah.originalText}"
                },
        )
    }
}
