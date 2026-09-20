package com.aaris.quran.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.aaris.quran.data.QuranRepository
import com.aaris.quran.model.QuranAyah
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal fun isCanonicalSurahNumber(surah: Int): Boolean = surah in 1..114

data class ReaderUiState(
    val surah: Int = 1,
    val ayahs: List<QuranAyah> = emptyList(),
    val targetAyah: Int? = null,
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
    val searchQuery: String = "",
    val searchResults: List<QuranAyah> = emptyList(),
    val isSearching: Boolean = false,
    val searchErrorMessage: String? = null,
)

class ReaderViewModel(
    private val repository: QuranRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(ReaderUiState())
    val state: StateFlow<ReaderUiState> = _state.asStateFlow()
    private var loadJob: Job? = null
    private var searchJob: Job? = null

    init {
        loadSurah(1)
    }

    fun previousSurah() = loadSurah((_state.value.surah - 1).coerceAtLeast(1))
    fun nextSurah() = loadSurah((_state.value.surah + 1).coerceAtMost(114))
    fun selectSurah(surah: Int) = loadSurah(surah)
    fun retry() = loadSurah(_state.value.surah, _state.value.targetAyah)

    fun updateSearchQuery(query: String) {
        searchJob?.cancel()
        _state.value = _state.value.copy(
            searchQuery = query,
            searchResults = emptyList(),
            isSearching = query.isNotBlank(),
            searchErrorMessage = null,
        )
        if (query.isBlank()) return

        searchJob = viewModelScope.launch {
            delay(180)
            try {
                val results = repository.searchAyahs(query)
                if (_state.value.searchQuery == query) {
                    _state.value = _state.value.copy(
                        searchResults = results,
                        isSearching = false,
                        searchErrorMessage = null,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                if (_state.value.searchQuery == query) {
                    _state.value = _state.value.copy(
                        searchResults = emptyList(),
                        isSearching = false,
                        searchErrorMessage = "Quran search could not be completed safely.",
                    )
                }
            }
        }
    }

    fun openSearchResult(ayah: QuranAyah) {
        updateSearchQuery("")
        loadSurah(ayah.surah, targetAyah = ayah.ayah)
    }

    private fun loadSurah(surah: Int, targetAyah: Int? = null) {
        if (!isCanonicalSurahNumber(surah)) return
        loadJob?.cancel()
        _state.value = _state.value.copy(
            surah = surah,
            targetAyah = targetAyah,
            isLoading = true,
            errorMessage = null,
        )
        loadJob = viewModelScope.launch {
            try {
                val ayahs = repository.ayahsForSurah(surah)
                _state.value = _state.value.copy(
                    surah = surah,
                    ayahs = ayahs,
                    targetAyah = targetAyah,
                    isLoading = false,
                    errorMessage = null,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                _state.value = _state.value.copy(
                    ayahs = emptyList(),
                    targetAyah = targetAyah,
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
