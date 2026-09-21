import com.aaris.shield.core.ShieldComponentId
import com.aaris.shield.core.ShieldComponentSnapshot
import com.aaris.shield.core.ShieldComponentState
import com.aaris.shield.core.ShieldRuntimeRegistry

fun main() {
    val registry = ShieldRuntimeRegistry(
        listOf(
            ShieldComponentSnapshot(
                ShieldComponentId.NETWORK,
                ShieldComponentState.READY,
                "network healthy",
            ),
            ShieldComponentSnapshot(
                ShieldComponentId.VISUAL_SAFETY,
                ShieldComponentState.READY,
                "visual healthy",
            ),
        ),
    )

    registry.update(
        ShieldComponentSnapshot(
            ShieldComponentId.VISUAL_SAFETY,
            ShieldComponentState.FAILED,
            "simulated isolated failure",
        ),
    )

    check(registry.get(ShieldComponentId.NETWORK)?.state == ShieldComponentState.READY) {
        "One subsystem failure must not mutate another subsystem"
    }
    check(registry.get(ShieldComponentId.VISUAL_SAFETY)?.state == ShieldComponentState.FAILED)

    val duplicateRejected = runCatching {
        ShieldRuntimeRegistry(
            listOf(
                ShieldComponentSnapshot(ShieldComponentId.NETWORK, ShieldComponentState.READY, "a"),
                ShieldComponentSnapshot(ShieldComponentId.NETWORK, ShieldComponentState.READY, "b"),
            ),
        )
    }.isFailure
    check(duplicateRejected) { "Duplicate subsystem ownership must be rejected" }

    val immutableView = registry.snapshot()
    check(immutableView.size == 2)
    registry.update(
        ShieldComponentSnapshot(
            ShieldComponentId.TEXT_SAFETY,
            ShieldComponentState.STARTING,
            "new component",
        ),
    )
    check(immutableView.size == 2) { "Snapshots must not be live mutable views" }

    println("Aaris Shield foundation smoke checks: PASS")
}
