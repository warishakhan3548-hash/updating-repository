package com.aaris.shield.network

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import com.aaris.shield.core.ShieldComponentId
import com.aaris.shield.core.ShieldComponentSnapshot
import com.aaris.shield.core.ShieldComponentState
import com.aaris.shield.core.ShieldRuntimeRegistry
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class NetworkShieldVpnService : VpnService() {
    private val running = AtomicBoolean(false)
    private val outputLock = Any()
    private val registry = ShieldRuntimeRegistry()

    @Volatile
    private var tunnel: ParcelFileDescriptor? = null

    @Volatile
    private var output: FileOutputStream? = null

    private var readerThread: Thread? = null
    private var workers: ThreadPoolExecutor? = null
    private var tracker: UnderlyingDnsTracker? = null
    private var dnsClient: ProtectedDnsClient? = null
    private var domainPolicy: DomainPolicy? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            NetworkShieldStateStore.setRequested(this, false)
            stopTunnel("Stopped by user", NetworkShieldState.STOPPED)
            stopSelf()
            return Service.START_NOT_STICKY
        }

        if (intent?.action == ACTION_START) {
            NetworkShieldStateStore.setRequested(this, true)
        } else if (!NetworkShieldStateStore.isRequested(this)) {
            stopSelf()
            return Service.START_NOT_STICKY
        }

        if (prepare(this) != null) {
            NetworkShieldStateStore.setRequested(this, false)
            NetworkShieldStateStore.update(
                this,
                NetworkShieldState.CONSENT_REQUIRED,
                "VPN permission must be granted before network protection can start",
            )
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return Service.START_NOT_STICKY
        }

        if (running.compareAndSet(false, true)) {
            NetworkShieldStateStore.update(this, NetworkShieldState.STARTING, "Starting local DNS shield")
            try {
                startTunnel()
                startInForeground()
            } catch (error: Throwable) {
                running.set(false)
                NetworkShieldStateStore.update(
                    this,
                    NetworkShieldState.DEGRADED,
                    "Network shield could not start safely: ${error.javaClass.simpleName}",
                )
                updateRegistry(ShieldComponentState.FAILED, "Network shield startup failed")
                stopTunnel("Startup failed", NetworkShieldState.DEGRADED)
                stopSelf()
                return Service.START_NOT_STICKY
            }
        }
        return Service.START_STICKY
    }

    override fun onRevoke() {
        NetworkShieldStateStore.setRequested(this, false)
        stopTunnel("VPN permission revoked", NetworkShieldState.CONSENT_REQUIRED)
        super.onRevoke()
    }

    override fun onDestroy() {
        if (running.get() || tunnel != null) {
            val requested = NetworkShieldStateStore.isRequested(this)
            stopTunnel(
                detail = if (requested) "Network shield service stopped; Android may restart it" else "Network shield stopped",
                state = if (requested) NetworkShieldState.DEGRADED else NetworkShieldState.STOPPED,
            )
        }
        super.onDestroy()
    }

    private fun startTunnel() {
        val policy = OfflineDomainPolicyLoader.load(this)
        domainPolicy = policy

        val networkTracker = UnderlyingDnsTracker(this) { snapshot ->
            val networks = snapshot?.let { arrayOf(it.network) } ?: emptyArray()
            if (tunnel != null) runCatching { setUnderlyingNetworks(networks) }
        }
        tracker = networkTracker
        dnsClient = ProtectedDnsClient(this, networkTracker)
        networkTracker.start()

        val builder = Builder()
            .setSession("Aaris Shield DNS")
            .setMtu(TUN_MTU)
            .addAddress(CLIENT_ADDRESS, 32)
            .addRoute(DNS_ADDRESS, 32)
            .addDnsServer(DNS_ADDRESS)
            .setBlocking(true)
        networkTracker.snapshot()?.let { builder.setUnderlyingNetworks(arrayOf(it.network)) }
        val interfaceDescriptor = builder.establish()
            ?: error("Android refused to establish VPN interface")

        tunnel = interfaceDescriptor
        val stream = FileOutputStream(interfaceDescriptor.fileDescriptor)
        output = stream
        workers = ThreadPoolExecutor(
            DNS_WORKERS,
            DNS_WORKERS,
            0L,
            TimeUnit.MILLISECONDS,
            ArrayBlockingQueue(MAX_PENDING_QUERIES),
        )

        readerThread = Thread(
            { readLoop(interfaceDescriptor, policy) },
            "AarisShield-DnsReader",
        ).apply {
            isDaemon = true
            start()
        }

        updateRegistry(
            ShieldComponentState.READY,
            "DNS shield active with ${policy.blockedRuleCount} offline blocked-domain rules",
        )
        NetworkShieldStateStore.update(
            this,
            NetworkShieldState.RUNNING,
            "Local DNS shield active (${policy.blockedRuleCount} offline block rules)",
        )
    }

    private fun readLoop(interfaceDescriptor: ParcelFileDescriptor, policy: DomainPolicy) {
        FileInputStream(interfaceDescriptor.fileDescriptor).use { input ->
            val buffer = ByteArray(TUN_MTU)
            while (running.get()) {
                val length = try {
                    input.read(buffer)
                } catch (_: Throwable) {
                    break
                }
                if (length <= 0) continue
                val request = Ipv4UdpPacket.parse(buffer, length) ?: continue
                if (request.destinationPort != DNS_PORT || request.destinationAddress.hostAddress != DNS_ADDRESS) continue
                val workersSnapshot = workers ?: break
                try {
                    workersSnapshot.execute { handleDnsRequest(request, policy) }
                } catch (_: RejectedExecutionException) {
                    writeDnsResponse(request, DnsMessage.servfailResponse(request.payload))
                }
            }
        }
        if (running.get()) {
            NetworkShieldStateStore.update(this, NetworkShieldState.DEGRADED, "DNS tunnel reader stopped unexpectedly")
            updateRegistry(ShieldComponentState.DEGRADED, "DNS tunnel reader stopped")
        }
    }

    private fun handleDnsRequest(request: Ipv4UdpPacket, policy: DomainPolicy) {
        val question = DnsMessage.firstQuestion(request.payload)
        val response = when {
            question == null || question.dnsClass != DNS_CLASS_IN -> DnsMessage.servfailResponse(request.payload)
            policy.decide(question.name) == DomainDecision.BLOCK -> DnsMessage.nxdomainResponse(request.payload)
            else -> {
                val upstream = dnsClient?.query(request.payload)
                if (upstream == null) {
                    DnsMessage.servfailResponse(request.payload)
                } else {
                    val aliases = DnsMessage.aliasTargets(upstream)
                    when {
                        aliases == null -> DnsMessage.servfailResponse(request.payload)
                        aliases.any { policy.decide(it) == DomainDecision.BLOCK } -> DnsMessage.nxdomainResponse(request.payload)
                        else -> upstream
                    }
                }
            }
        }
        writeDnsResponse(request, response)
    }

    private fun writeDnsResponse(request: Ipv4UdpPacket, dnsResponse: ByteArray?) {
        if (dnsResponse == null || !running.get()) return
        val packet = runCatching { Ipv4UdpPacket.buildResponse(request, dnsResponse) }.getOrNull() ?: return
        synchronized(outputLock) {
            runCatching {
                output?.write(packet)
                output?.flush()
            }
        }
    }

    private fun stopTunnel(detail: String, state: NetworkShieldState) {
        running.set(false)
        readerThread?.interrupt()
        readerThread = null
        workers?.shutdownNow()
        workers = null
        tracker?.close()
        tracker = null
        dnsClient = null
        domainPolicy = null
        synchronized(outputLock) {
            runCatching { output?.close() }
            output = null
            runCatching { tunnel?.close() }
            tunnel = null
        }
        NetworkShieldStateStore.update(this, state, detail)
        updateRegistry(
            if (state == NetworkShieldState.STOPPED) ShieldComponentState.STOPPED else ShieldComponentState.DEGRADED,
            detail,
        )
    }

    private fun updateRegistry(state: ShieldComponentState, detail: String) {
        registry.update(
            ShieldComponentSnapshot(
                id = ShieldComponentId.NETWORK,
                state = state,
                detail = detail,
            ),
        )
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Aaris Shield network protection",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_shield_notification)
            .setContentTitle("Aaris Shield network protection")
            .setContentText("Filtering DNS locally on this device")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .apply { if (pendingIntent != null) setContentIntent(pendingIntent) }
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val ACTION_START = "com.aaris.shield.network.START"
        const val ACTION_STOP = "com.aaris.shield.network.STOP"

        private const val CLIENT_ADDRESS = "10.111.222.2"
        private const val DNS_ADDRESS = "10.111.222.1"
        private const val DNS_PORT = 53
        private const val DNS_CLASS_IN = 1
        private const val TUN_MTU = 1_500
        private const val DNS_WORKERS = 2
        private const val MAX_PENDING_QUERIES = 32
        private const val NOTIFICATION_ID = 2202
        private const val NOTIFICATION_CHANNEL_ID = "aaris_shield_network"
    }
}
