package com.aaris.shield.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.net.InetAddress

internal data class UnderlyingDnsSnapshot(
    val network: Network,
    val dnsServers: List<InetAddress>,
)

internal class UnderlyingDnsTracker(
    context: Context,
    private val onChanged: (UnderlyingDnsSnapshot?) -> Unit,
) : AutoCloseable {
    private data class Candidate(
        val network: Network,
        var capabilities: NetworkCapabilities? = null,
        var linkProperties: LinkProperties? = null,
    )

    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val lock = Any()
    private val candidates = LinkedHashMap<Network, Candidate>()
    private var current: UnderlyingDnsSnapshot? = null
    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            synchronized(lock) {
                candidates.getOrPut(network) { Candidate(network) }
                recalculateLocked()
            }
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            synchronized(lock) {
                candidates.getOrPut(network) { Candidate(network) }.capabilities = networkCapabilities
                recalculateLocked()
            }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            synchronized(lock) {
                candidates.getOrPut(network) { Candidate(network) }.linkProperties = linkProperties
                recalculateLocked()
            }
        }

        override fun onLost(network: Network) {
            synchronized(lock) {
                candidates.remove(network)
                recalculateLocked()
            }
        }
    }

    fun start() {
        synchronized(lock) {
            if (registered) return
            registered = true
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        connectivityManager.registerNetworkCallback(request, callback)
        for (network in connectivityManager.allNetworks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) continue
            val linkProperties = connectivityManager.getLinkProperties(network) ?: continue
            synchronized(lock) {
                candidates[network] = Candidate(network, capabilities, linkProperties)
                recalculateLocked()
            }
        }
    }

    fun snapshot(): UnderlyingDnsSnapshot? = synchronized(lock) { current }

    override fun close() {
        val shouldUnregister = synchronized(lock) {
            if (!registered) false else {
                registered = false
                candidates.clear()
                current = null
                true
            }
        }
        if (shouldUnregister) {
            runCatching { connectivityManager.unregisterNetworkCallback(callback) }
        }
        onChanged(null)
    }

    private fun recalculateLocked() {
        val selected = candidates.values
            .asSequence()
            .filter { candidate ->
                val capabilities = candidate.capabilities ?: return@filter false
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                    !candidate.linkProperties?.dnsServers.isNullOrEmpty()
            }
            .sortedByDescending { candidate ->
                if (candidate.capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) 1 else 0
            }
            .firstOrNull()
            ?.let { candidate ->
                UnderlyingDnsSnapshot(
                    network = candidate.network,
                    dnsServers = candidate.linkProperties?.dnsServers.orEmpty().distinct(),
                )
            }

        if (selected != current) {
            current = selected
            onChanged(selected)
        }
    }
}
