package com.aaris.quran.ui

import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.material3.Surface
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
    onOpenSearchResult: (QuranAyah) -> Unit,
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
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
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
                    .heightIn(min = 48.dp),
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
                state.isLoading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                state.errorMessage != null -> {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.align(Alignment.Center).padding(24.dp),
                    ) {
                        Text(state.errorMessage)
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
    onOpenSearchResult: (QuranAyah) -> Unit,
) {
    when {
        state.isSearching -> {
            Box(Modifier.fillMaxSize()) {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            }
        }
        state.searchErrorMessage != null -> {
            Box(Modifier.fillMaxSize()) {
                Text(
                    text = state.searchErrorMessage,
                    modifier = Modifier.align(Alignment.Center).padding(24.dp),
                )
            }
        }
        state.searchResults.isEmpty() -> {
            Box(Modifier.fillMaxSize()) {
                Text(
                    text = "No reliable match found.",
                    modifier = Modifier.align(Alignment.Center).padding(24.dp),
                )
            }
        }
        else -> {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(state.searchResults, key = { it.ayah.ayahId }) { hit ->
                    val ayah = hit.ayah
                    TextButton(
                        onClick = { onOpenSearchResult(ayah) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .padding(horizontal = 8.dp),
                    ) {
                        Column(
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = "Surah ${ayah.surah} • Ayah ${ayah.ayah}",
                                style = MaterialTheme.typography.labelMedium,
                            )
                            if (hit.isApproximate) {
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
        title = { Text("Choose Surah") },
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
    var layoutResult by remember(ayah.ayahId) { mutableStateOf<TextLayoutResult?>(null) }
    var selectedAnchor by remember(ayah.ayahId) { mutableStateOf<SurfaceTapAnchor?>(null) }

    val displayText: AnnotatedString = remember(ayah.originalText, selectedAnchor) {
        buildAnnotatedString {
            append(ayah.originalText)
            selectedAnchor?.let { anchor ->
                addStyle(
                    SpanStyle(
                        fontWeight = FontWeight.SemiBold,
                        textDecoration = TextDecoration.Underline,
                    ),
                    anchor.start,
                    anchor.end,
                )
            }
        }
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
    ) {
        Text(
            text = "Ayah ${ayah.ayah}",
            style = MaterialTheme.typography.labelMedium,
        )
        Text(
            text = displayText,
            style = MaterialTheme.typography.bodyLarge.copy(
                fontSize = 32.sp,
                lineHeight = 54.sp,
                textDirection = TextDirection.ContentOrRtl,
            ),
            onTextLayout = { layoutResult = it },
            modifier = Modifier
                .fillMaxWidth()
                .semantics {
                    contentDescription =
                        "Surah ${ayah.surah}, ayah ${ayah.ayah}. ${ayah.originalText}"
                }
                .pointerInput(ayah.ayahId, ayah.originalText) {
                    detectTapGestures { position ->
                        val offset = layoutResult?.getOffsetForPosition(position)
                            ?: return@detectTapGestures
                        selectedAnchor = SurfaceTapAnchorResolver.resolve(
                            ayah.ayahId,
                            ayah.originalText,
                            offset,
                        )
                    }
                },
        )

        selectedAnchor?.let { anchor ->
            Surface(tonalElevation = 1.dp, shape = MaterialTheme.shapes.small) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(anchor.surface, style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Verified word details are not installed yet.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}
