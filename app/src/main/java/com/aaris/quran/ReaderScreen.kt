package com.aaris.quran

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aaris.quran.data.QuranAyah
import com.aaris.quran.data.QuranPackContract
import com.aaris.quran.data.QuranRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private sealed interface ReaderUiState {
    data object Loading : ReaderUiState
    data class Ready(val ayahs: List<QuranAyah>) : ReaderUiState
    data class Error(val message: String) : ReaderUiState
}

@Composable
fun QuranReaderApp() {
    val context = LocalContext.current
    val repository = remember(context.applicationContext) { QuranRepository(context.applicationContext) }
    var selectedSurah by rememberSaveable { mutableIntStateOf(1) }
    var showPicker by rememberSaveable { mutableStateOf(false) }
    var showSource by rememberSaveable { mutableStateOf(false) }

    val state by produceState<ReaderUiState>(ReaderUiState.Loading, selectedSurah) {
        value = ReaderUiState.Loading
        value = try {
            ReaderUiState.Ready(withContext(Dispatchers.IO) { repository.loadSurah(selectedSurah) })
        } catch (error: Throwable) {
            ReaderUiState.Error(error.message ?: "The Quran pack could not be verified.")
        }
    }

    ReaderScreen(
        surah = selectedSurah,
        state = state,
        onPrevious = { if (selectedSurah > 1) selectedSurah -= 1 },
        onNext = { if (selectedSurah < 114) selectedSurah += 1 },
        onChooseSurah = { showPicker = true },
        onSourceInfo = { showSource = true },
    )

    if (showPicker) {
        SurahPicker(
            selected = selectedSurah,
            onDismiss = { showPicker = false },
            onSelected = {
                selectedSurah = it
                showPicker = false
            },
        )
    }

    if (showSource) {
        val notice by produceState<String?>(initialValue = null, showSource) {
            value = withContext(Dispatchers.IO) { repository.bundledNotice() }
        }
        SourceDialog(
            notice = notice,
            onDismiss = { showSource = false },
            onOpenSource = {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(QuranPackContract.SOURCE_URL)))
            },
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ReaderScreen(
    surah: Int,
    state: ReaderUiState,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onChooseSurah: () -> Unit,
    onSourceInfo: () -> Unit,
) {
    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                navigationIcon = {
                    TextButton(
                        onClick = onPrevious,
                        enabled = surah > 1,
                        modifier = Modifier.semantics { contentDescription = "Previous surah" },
                    ) { Text("‹", fontSize = 28.sp) }
                },
                title = {
                    TextButton(onClick = onChooseSurah) {
                        Text("Surah $surah  ▾")
                    }
                },
                actions = {
                    TextButton(
                        onClick = onNext,
                        enabled = surah < 114,
                        modifier = Modifier.semantics { contentDescription = "Next surah" },
                    ) { Text("›", fontSize = 28.sp) }
                    TextButton(
                        onClick = onSourceInfo,
                        modifier = Modifier.semantics { contentDescription = "Quran text source" },
                    ) { Text("ⓘ") }
                },
            )
        },
    ) { padding ->
        when (state) {
            ReaderUiState.Loading -> Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator() }

            is ReaderUiState.Error -> Box(
                modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Reader unavailable", style = MaterialTheme.typography.titleLarge)
                    Text(
                        state.message,
                        modifier = Modifier.padding(top = 8.dp),
                        textAlign = TextAlign.Center,
                    )
                }
            }

            is ReaderUiState.Ready -> AyahList(
                ayahs = state.ayahs,
                contentPadding = PaddingValues(
                    start = 20.dp,
                    end = 20.dp,
                    top = padding.calculateTopPadding() + 16.dp,
                    bottom = padding.calculateBottomPadding() + 24.dp,
                ),
            )
        }
    }
}

@Composable
private fun AyahList(ayahs: List<QuranAyah>, contentPadding: PaddingValues) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(ayahs, key = { it.ayah }) { ayah ->
            Column(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = ayah.originalText,
                    modifier = Modifier.fillMaxWidth(),
                    style = MaterialTheme.typography.headlineSmall.copy(
                        fontFamily = FontFamily.Serif,
                        fontSize = 30.sp,
                        lineHeight = 48.sp,
                        textDirection = TextDirection.Rtl,
                    ),
                    textAlign = TextAlign.Center,
                )
                Text(
                    text = "${ayah.surah}:${ayah.ayah}",
                    modifier = Modifier
                        .align(Alignment.End)
                        .semantics { contentDescription = "Surah ${ayah.surah}, ayah ${ayah.ayah}" },
                    style = MaterialTheme.typography.labelMedium,
                )
                HorizontalDivider(modifier = Modifier.padding(top = 12.dp))
            }
        }
    }
}

@Composable
private fun SurahPicker(selected: Int, onDismiss: () -> Unit, onSelected: (Int) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Choose Surah") },
        text = {
            LazyColumn(modifier = Modifier.heightIn(max = 480.dp)) {
                items((1..114).toList(), key = { it }) { surah ->
                    ListItem(
                        headlineContent = { Text("Surah $surah") },
                        trailingContent = { if (surah == selected) Text("✓") },
                        modifier = Modifier.clickable { onSelected(surah) },
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

@Composable
private fun SourceDialog(notice: String?, onDismiss: () -> Unit, onOpenSource: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Quran text source") },
        text = {
            Column {
                Text("Arabic Quran text: ${QuranPackContract.SOURCE_NAME}, version 1.1.")
                Text(
                    "The exact verified source notice is bundled with this build.",
                    modifier = Modifier.padding(top = 8.dp),
                )
                if (!notice.isNullOrBlank()) {
                    Text(
                        notice,
                        modifier = Modifier
                            .padding(top = 12.dp)
                            .heightIn(max = 180.dp)
                            .verticalScroll(rememberScrollState()),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        confirmButton = { TextButton(onClick = onOpenSource) { Text("Open Tanzil") } },
    )
}
