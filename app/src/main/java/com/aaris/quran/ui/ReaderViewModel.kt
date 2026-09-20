package com.aaris.quran.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.aaris.quran.data.QuranRepository
import com.aaris.quran.model.QuranAyah
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal fun isCanonicalSurahNumber(surah: Int): Boolean = surah in 1..114

data class ReaderUiState(
    val surah: Int = 1,
    val ayahs: List<QuranAyah> = emptyList(),
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
)

class ReaderViewModel(
    private val repository: QuranRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(ReaderUiState())
    val state: StateFlow<ReaderUiState> = _state.asStateFlow()
    private var loadJob: Job? = null

    init {
        loadSurah(1)
    }

    fun previousSurah() = loadSurah((_state.value.surah - 1).coerceAtLeast(1))
    fun nextSurah() = loadSurah((_state.value.surah + 1).coerceAtMost(114))
    fun selectSurah(surah: Int) = loadSurah(surah)
    fun retry() = loadSurah(_state.value.surah)

    private fun loadSurah(surah: Int) {
        if (!isCanonicalSurahNumber(surah)) return
        loadJob?.cancel()
        _state.value = _state.value.copy(
            surah = surah,
            isLoading = true,
            errorMessage = null,
        )
        loadJob = viewModelScope.launch {
            runCatching { repository.ayahsForSurah(surah) }
                .onSuccess { ayahs ->
                    _state.value = ReaderUiState(
                        surah = surah,
                        ayahs = ayahs,
                        isLoading = false,
                    )
                }
                .onFailure {
                    _state.value = _state.value.copy(
                        ayahs = emptyList(),
                        isLoading = false,
                        errorMessage = "Quran content could not be opened safely.",
                    )
                }
        }
    }

    class Factory(
        private val repository: QuranRepository,
    ) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass.isAssignableFrom(ReaderViewModel::class.java))
            @Suppress("UNCHECKED_CAST")
            return ReaderViewModel(repository) as T
        }
    }
}
