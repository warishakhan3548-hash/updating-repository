package com.aaris.quran.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aaris.quran.R
import com.aaris.quran.data.QuranAyah
import com.aaris.quran.data.QuranPackInfo
import com.aaris.quran.data.QuranPackStore

private sealed interface ReaderState {
    data object Loading : ReaderState

    data class Ready(
        val ayahs: List<QuranAyah>,
        val packInfo: QuranPackInfo,
    ) : ReaderState

    data object Error : ReaderState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuranReaderScreen(
    store: QuranPackStore,
    onOpenSource: () -> Unit,
) {
    var surah by rememberSaveable { mutableIntStateOf(ReaderNavigation.FIRST_SURAH) }
    val listState = rememberLazyListState()

    val state by produceState<ReaderState>(
        initialValue = ReaderState.Loading,
        key1 = store,
        key2 = surah,
    ) {
        value = try {
            ReaderState.Ready(
                ayahs = store.loadSurah(surah),
                packInfo = store.packInfo(),
            )
        } catch (_: Throwable) {
            ReaderState.Error
        }
    }

    LaunchedEffect(surah) {
        listState.scrollToItem(0)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.quran_title)) },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            SurahNavigation(
                surah = surah,
                onPrevious = { surah = ReaderNavigation.previous(surah) },
                onNext = { surah = ReaderNavigation.next(surah) },
            )

            when (val current = state) {
                ReaderState.Loading -> LoadingContent()
                ReaderState.Error -> ErrorContent()
                is ReaderState.Ready -> {
                    if (current.ayahs.isEmpty()) {
                        ErrorContent()
                    } else {
                        LazyColumn(
                            state = listState,
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            items(
                                items = current.ayahs,
                                key = QuranAyah::ayahId,
                            ) { ayah ->
                                AyahRow(ayah)
                            }

                            item(key = "source-attribution") {
                                SourceAttribution(
                                    packInfo = current.packInfo,
                                    onOpenSource = onOpenSource,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SurahNavigation(
    surah: Int,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        OutlinedButton(
            onClick = onPrevious,
            enabled = surah > ReaderNavigation.FIRST_SURAH,
        ) {
            Text(stringResource(R.string.previous_surah))
        }

        Text(
            text = stringResource(R.string.surah_number, surah),
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.titleMedium,
        )

        OutlinedButton(
            onClick = onNext,
            enabled = surah < ReaderNavigation.LAST_SURAH,
        ) {
            Text(stringResource(R.string.next_surah))
        }
    }
}

@Composable
private fun LoadingContent() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator()
            Spacer(Modifier.height(12.dp))
            Text(stringResource(R.string.loading_quran))
        }
    }
}

@Composable
private fun ErrorContent() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(R.string.content_verification_failed),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Composable
private fun AyahRow(ayah: QuranAyah) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 16.dp),
    ) {
        Text(
            text = ayah.ayah.toString(),
            style = MaterialTheme.typography.labelLarge,
        )

        Spacer(Modifier.height(8.dp))

        CompositionLocalProvider(
            LocalLayoutDirection provides LayoutDirection.Rtl,
        ) {
            Text(
                text = ayah.originalText,
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Start,
                fontSize = 28.sp,
                lineHeight = 48.sp,
                style = MaterialTheme.typography.bodyLarge,
            )
        }
    }

    HorizontalDivider()
}

@Composable
private fun SourceAttribution(
    packInfo: QuranPackInfo,
    onOpenSource: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "${packInfo.sourceName} · v${packInfo.sourceVersion} · pack ${packInfo.contentVersion}",
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodySmall,
        )
        TextButton(onClick = onOpenSource) {
            Text(stringResource(R.string.source_tanzil))
        }
    }
}
