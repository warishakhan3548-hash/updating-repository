package com.aaris.shield.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ShieldRuntimeRegistryTest {
    @Test
    fun failedComponentDoesNotMutateIndependentComponent() {
        val registry = ShieldRuntimeRegistry(
            listOf(
                ShieldComponentSnapshot(ShieldComponentId.NETWORK, ShieldComponentState.READY, "ready"),
                ShieldComponentSnapshot(ShieldComponentId.VISUAL_SAFETY, ShieldComponentState.READY, "ready"),
            ),
        )

        registry.update(
            ShieldComponentSnapshot(
                ShieldComponentId.VISUAL_SAFETY,
                ShieldComponentState.FAILED,
                "simulated failure",
            ),
        )

        assertEquals(ShieldComponentState.READY, registry.get(ShieldComponentId.NETWORK)?.state)
        assertEquals(ShieldComponentState.FAILED, registry.get(ShieldComponentId.VISUAL_SAFETY)?.state)
    }

    @Test
    fun duplicateInitialOwnershipIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            ShieldRuntimeRegistry(
                listOf(
                    ShieldComponentSnapshot(ShieldComponentId.NETWORK, ShieldComponentState.READY, "one"),
                    ShieldComponentSnapshot(ShieldComponentId.NETWORK, ShieldComponentState.READY, "two"),
                ),
            )
        }
    }

    @Test
    fun returnedSnapshotIsNotLiveView() {
        val registry = ShieldRuntimeRegistry(
            listOf(
                ShieldComponentSnapshot(ShieldComponentId.FOUNDATION, ShieldComponentState.READY, "ready"),
            ),
        )
        val firstSnapshot = registry.snapshot()

        registry.update(
            ShieldComponentSnapshot(ShieldComponentId.TEXT_SAFETY, ShieldComponentState.STARTING, "starting"),
        )

        assertEquals(1, firstSnapshot.size)
        assertEquals(2, registry.snapshot().size)
    }
}
