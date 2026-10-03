package com.aaris.remoteassist.ai

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test

class AiConnectorBackendCloseTest {
    @Test fun pooledSocketIsClosedOffTheCallerThreadEvenWhenCloseIsCalledTwice() {
        val closeThread = AtomicReference<Thread>()
        val closed = CountDownLatch(1)
        val sockets = object : SocketFactory() {
            override fun createSocket(): Socket = object : Socket() {
                override fun close() {
                    closeThread.compareAndSet(null, Thread.currentThread())
                    try { super.close() } finally { closed.countDown() }
                }
            }
            override fun createSocket(host: String, port: Int) = createSocket().apply { connect(InetSocketAddress(host, port)) }
            override fun createSocket(host: InetAddress, port: Int) = createSocket().apply { connect(InetSocketAddress(host, port)) }
            override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int) =
                createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
            override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int) =
                createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
        }
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val serverDone = CountDownLatch(1)
            Thread({
                try {
                    server.accept().use { socket ->
                        socket.soTimeout = 5000
                        val reader = socket.getInputStream().bufferedReader()
                        while (!reader.readLine().isNullOrEmpty()) { /* consume HTTP headers */ }
                        socket.getOutputStream().apply {
                            write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".toByteArray())
                            flush()
                        }
                        reader.read() // Wait for pool eviction, not a server-initiated close.
                    }
                } finally { serverDone.countDown() }
            }, "test-http-server").apply { isDaemon = true; start() }
            val client = OkHttpClient.Builder().socketFactory(sockets).build()
            try {
                client.newCall(Request.Builder().url("http://127.0.0.1:${server.localPort}/").build()).execute().use {
                    assertEquals("OK", it.body!!.string())
                }
                assertEquals(1, client.connectionPool.idleConnectionCount())
                val caller = Thread.currentThread()
                val backend = AiConnectorBackend(client)
                backend.close()
                backend.close()
                assertTrue("Pool cleanup must still finish after the caller returns", closed.await(5, TimeUnit.SECONDS))
                assertNotSame("Closing a pooled TLS socket can write close_notify: never do it on the UI/caller thread", caller, closeThread.get())
                assertEquals(0, client.connectionPool.connectionCount())
                assertTrue(serverDone.await(5, TimeUnit.SECONDS))
            } finally {
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
            }
        }
    }
}
