package com.aaris.quran.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aaris.quran.data.QuranAyah
import com.aaris.quran.data.QuranRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private sealed interface ReaderState {
    data object Loading : ReaderState
    data class Ready(val ayahs: List<QuranAyah>) : ReaderState
    data object Failed : ReaderState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen() {
    val context = LocalContext.current
    val repository = remember { QuranRepository(context.applicationContext) }
    val listState = rememberLazyListState()

    var surah by rememberSaveable { mutableIntStateOf(1) }
    var retryGeneration by rememberSaveable { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<ReaderState>(ReaderState.Loading) }
    var showSurahPicker by rememberSaveable { mutableStateOf(false) }
    var showSource by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(surah, retryGeneration) {
        state = ReaderState.Loading
        state = try {
            val ayahs = withContext(Dispatchers.IO) { repository.loadSurah(surah) }
            ReaderState.Ready(ayahs)
        } catch (error: Exception) {
            Log.e("AarisQuran", "Verified Quran pack could not be opened", error)
            ReaderState.Failed
        }
    }

    LaunchedEffect(state) {
        if (state is ReaderState.Ready) {
            listState.scrollToItem(0)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Quran") },
                actions = {
                    TextButton(
                        onClick = { showSource = true },
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) {
                        Text("Source")
                    }
                },
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
                enabled = state !is ReaderState.Loading,
                onPrevious = { if (surah > 1) surah -= 1 },
                onChoose = { showSurahPicker = true },
                onNext = { if (surah < 114) surah += 1 },
            )

            when (val current = state) {
                ReaderState.Loading -> Loading()
                ReaderState.Failed -> VerificationFailed(
                    onRetry = { retryGeneration += 1 },
                )
                is ReaderState.Ready -> LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(
                        items = current.ayahs,
                        key = { it.ayahId },
                    ) { ayah ->
                        AyahRow(ayah)
                    }
                }
            }
        }
    }

    if (showSurahPicker) {
        SurahPicker(
            selected = surah,
            onDismiss = { showSurahPicker = false },
            onSelect = {
                surah = it
                showSurahPicker = false
            },
        )
    }

    if (showSource) {
        SourceDialog(
            notice = runCatching { repository.verifiedNotice() }
                .getOrElse { "Source notice could not be verified." },
            onDismiss = { showSource = false },
            onOpenSource = {
                val intent = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://tanzil.net/"),
                )
                try {
                    context.startActivity(intent)
                } catch (_: ActivityNotFoundException) {
                    // The verified local notice remains available without a browser.
                }
            },
        )
    }
}

@Composable
private fun SurahNavigation(
    surah: Int,
    enabled: Boolean,
    onPrevious: () -> Unit,
    onChoose: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Button(
            onClick = onPrevious,
            enabled = enabled && surah > 1,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text("Previous")
        }
        TextButton(
            onClick = onChoose,
            enabled = enabled,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text("Surah $surah")
        }
        Button(
            onClick = onNext,
            enabled = enabled && surah < 114,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text("Next")
        }
    }
}

@Composable
private fun AyahRow(ayah: QuranAyah) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clearAndSetSemantics {
                contentDescription =
                    "Surah ${ayah.surah}, ayah ${ayah.ayah}. ${ayah.originalText}"
            }
            .padding(horizontal = 20.dp, vertical = 14.dp),
    ) {
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Rtl) {
            Text(
                text = ayah.originalText,
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Right,
                fontSize = 30.sp,
                lineHeight = 48.sp,
                style = MaterialTheme.typography.bodyLarge,
            )
        }
        Text(
            text = "Ayah ${ayah.ayah}",
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.End,
            style = MaterialTheme.typography.labelMedium,
        )
    }
    HorizontalDivider()
}

@Composable
private fun Loading() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun VerificationFailed(onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "Quran content could not be verified.",
            style = MaterialTheme.typography.titleMedium,
            textAlign = TextAlign.Center,
        )
        Text(
            text = "The app will not display unverified text.",
            modifier = Modifier.padding(top = 8.dp, bottom = 20.dp),
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onRetry,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            Text("Retry")
        }
    }
}

@Composable
private fun SurahPicker(
    selected: Int,
    onDismiss: () -> Unit,
    onSelect: (Int) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Choose Surah") },
        text = {
            LazyColumn(
                modifier = Modifier.heightIn(max = 440.dp),
            ) {
                items(count = 114) { index ->
                    val number = index + 1
                    TextButton(
                        onClick = { onSelect(number) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp),
                    ) {
                        Text(
                            text = if (number == selected) {
                                "Surah $number · Current"
                            } else {
                                "Surah $number"
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
private fun SourceDialog(
    notice: String,
    onDismiss: () -> Unit,
    onOpenSource: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Source & licence") },
        text = {
            Text(
                text = notice,
                modifier = Modifier
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                style = MaterialTheme.typography.bodySmall,
            )
        },
        confirmButton = {
            TextButton(
                onClick = onOpenSource,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text("Open Tanzil")
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
