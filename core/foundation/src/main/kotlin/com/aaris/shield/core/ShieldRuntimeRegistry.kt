package com.aaris.shield.core

/**
 * Stable identifiers for independently evolving Aaris Shield subsystems.
 * Only FOUNDATION is implemented in Step 1; the other identifiers reserve
 * explicit ownership boundaries without pretending those protections exist.
 */
enum class ShieldComponentId {
    FOUNDATION,
    NETWORK,
    VISUAL_SAFETY,
    REGION_LOCALIZATION,
    OVERLAY,
    SCREEN_OBSERVATION,
    TEXT_SAFETY,
    AUDIO_SAFETY,
    SAFETY_COVER,
    STRICT_MODE,
    CALIBRATION,
    PRIVACY_PERFORMANCE,
}

enum class ShieldComponentState {
    READY,
    STARTING,
    STOPPED,
    DEGRADED,
    BLOCKED_BY_PLATFORM,
    FAILED,
}

data class ShieldComponentSnapshot(
    val id: ShieldComponentId,
    val state: ShieldComponentState,
    val detail: String,
) {
    init {
        require(detail.isNotBlank()) { "Component detail must not be blank" }
    }
}

/**
 * Thread-safe process-local registry for subsystem health.
 *
 * A component update mutates only that component's entry. This deliberately
 * prevents a future VPN, ML, accessibility, audio, or overlay failure from
 * implicitly disabling unrelated layers. Android services remain responsible
 * for persisting/recovering their own state in later roadmap steps.
 */
class ShieldRuntimeRegistry(
    initial: Iterable<ShieldComponentSnapshot> = emptyList(),
) {
    private val lock = Any()
    private val components = LinkedHashMap<ShieldComponentId, ShieldComponentSnapshot>()

    init {
        for (snapshot in initial) {
            require(!components.containsKey(snapshot.id)) {
                "Duplicate initial component: ${snapshot.id}"
            }
            components[snapshot.id] = snapshot
        }
    }

    fun update(snapshot: ShieldComponentSnapshot) {
        synchronized(lock) {
            components[snapshot.id] = snapshot
        }
    }

    fun get(id: ShieldComponentId): ShieldComponentSnapshot? = synchronized(lock) {
        components[id]
    }

    fun snapshot(): List<ShieldComponentSnapshot> = synchronized(lock) {
        components.values.toList()
    }
}
