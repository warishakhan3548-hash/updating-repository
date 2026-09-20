package com.aaris.quran.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.aaris.quran.data.QuranAyah
import com.aaris.quran.data.QuranContentRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ReaderUiState(
    val surah: Int = 1,
    val ayahs: List<QuranAyah> = emptyList(),
    val loading: Boolean = true,
    val error: String? = null,
)

class ReaderViewModel(
    private val repository: QuranContentRepository,
) : ViewModel() {
    private val _uiState = MutableStateFlow(ReaderUiState())
    val uiState: StateFlow<ReaderUiState> = _uiState.asStateFlow()

    private var generation = 0L

    init {
        selectSurah(1)
    }

    fun selectSurah(surah: Int) {
        if (surah !in 1..114) return
        val request = ++generation
        _uiState.value = _uiState.value.copy(
            surah = surah,
            ayahs = emptyList(),
            loading = true,
            error = null,
        )
        viewModelScope.launch {
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    repository.loadSurah(surah)
                }
            }
            if (request != generation) return@launch
            _uiState.value = result.fold(
                onSuccess = { ayahs ->
                    ReaderUiState(
                        surah = surah,
                        ayahs = ayahs,
                        loading = false,
                    )
                },
                onFailure = {
                    ReaderUiState(
                        surah = surah,
                        loading = false,
                        error = "Could not open the verified local Quran pack.",
                    )
                },
            )
        }
    }

    fun previousSurah() = selectSurah(_uiState.value.surah - 1)

    fun nextSurah() = selectSurah(_uiState.value.surah + 1)

    fun retry() = selectSurah(_uiState.value.surah)

    companion object {
        fun factory(repository: QuranContentRepository): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    require(modelClass.isAssignableFrom(ReaderViewModel::class.java))
                    return ReaderViewModel(repository) as T
                }
            }
    }
}
