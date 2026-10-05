package com.aaris.remoteassist.backend

import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import javax.net.ssl.SSLPeerUnverifiedException
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class BackendTransportTest {
    private val primary = "https://primary.aaris.test/".toHttpUrl()
    private val fallback = "https://fallback.aaris.test/".toHttpUrl()
    private val session = "a".repeat(64)
    private val controllerToken = "b".repeat(43)

    @Test fun unreachablePrimaryRetriesTheSameCodeAndTokenThenRemembersTheWorkingRoute() {
        val seen = mutableListOf<Request>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            seen += chain.request()
            if (chain.request().url.host == primary.host) throw ConnectException("Failed to connect")
            response(chain.request(), 200, "{\"ok\":true}")
        }.build()
        val transport = BackendTransport(client, listOf(primary, fallback))
        val body = JSONObject().put("code", "123456789012").put("controllerToken", controllerToken)
        assertTrue(transport.execute("POST", "/v1/sessions/redeem", null, body).getBoolean("ok"))
        assertEquals(listOf(primary.host, fallback.host), seen.map { it.url.host })
        val buffer = okio.Buffer()
        seen.last().body!!.writeTo(buffer)
        assertEquals(body.toString(), buffer.readUtf8())
        assertEquals(fallback, transport.currentOrigin())
        transport.execute("GET", "/v1/sessions/$session", "session-token", null)
        assertEquals(3, seen.size)
        assertEquals(fallback.host, seen.last().url.host)
        assertEquals("Bearer session-token", seen.last().header("Authorization"))
    }

    @Test fun codeAndAuthorizationErrorsNeverFailOverOrConsumeAnotherRedemption() {
        for (status in listOf(401, 404, 409, 410)) {
            var calls = 0
            val transport = BackendTransport(OkHttpClient.Builder().addInterceptor { chain ->
                calls++
                response(chain.request(), status, "{\"error\":\"invalid_code\"}")
            }.build(), listOf(primary, fallback))
            val error = assertThrows(CloudflareBackendException::class.java) {
                transport.execute("POST", "/v1/sessions/redeem", null,
                    JSONObject().put("controllerToken", controllerToken))
            }
            assertEquals(status, error.statusCode)
            assertEquals(1, calls)
            assertEquals(primary, transport.currentOrigin())
        }
    }

    @Test fun certificateFailureAndCancellationDoNotSwitchRoutes() {
        for (failure in listOf(SSLPeerUnverifiedException("untrusted certificate"), InterruptedIOException("canceled"))) {
            var calls = 0
            val transport = BackendTransport(OkHttpClient.Builder().addInterceptor {
                calls++
                throw failure
            }.build(), listOf(primary, fallback))
            assertSame(failure, assertThrows(failure.javaClass) {
                transport.execute("GET", "/healthz", null, null)
            })
            assertEquals(1, calls)
            assertEquals(primary, transport.currentOrigin())
        }
    }

    @Test fun bothUnreachableRoutesStopWithAUsefulErrorAndKeepTheOriginalCauses() {
        var calls = 0
        val transport = BackendTransport(OkHttpClient.Builder().addInterceptor {
            calls++
            throw ConnectException("unreachable")
        }.build(), listOf(primary, fallback))
        val error = assertThrows(CloudflareBackendException::class.java) {
            transport.execute("GET", "/healthz", null, null)
        }
        assertEquals("backend_unreachable", error.backendCode)
        assertEquals(0, error.statusCode)
        assertEquals(2, calls)
        assertTrue(error.cause is ConnectException)
        assertEquals(1, error.cause!!.suppressed.size)
    }

    @Test fun aStaleSocketFailureCannotReplaceTheWorkingOrigin() {
        val transport = BackendTransport(OkHttpClient(), listOf(primary, fallback))
        transport.connectionFailed(primary, ConnectException())
        assertEquals(fallback, transport.currentOrigin())
        transport.connected(fallback)
        transport.connectionFailed(primary, ConnectException())
        assertEquals(fallback, transport.currentOrigin())
        transport.connectionFailed("https://unrelated.test/".toHttpUrl(), ConnectException())
        assertEquals(fallback, transport.currentOrigin())
        transport.connectionFailed(fallback, ConnectException())
        assertEquals(primary, transport.currentOrigin())
    }

    @Test fun anAmbiguousSessionCreationOrEventIsNotSentAgain() {
        for (path in listOf("/v1/sessions", "/v1/sessions/$session/events")) {
            HttpProbe(null).use { first ->
                HttpProbe("{\"ok\":true}").use { second ->
                    val transport = BackendTransport(networkClient(), listOf(first.origin, second.origin))
                    assertThrows(CloudflareBackendException::class.java) {
                        transport.execute("POST", path, "session-token", JSONObject().put("kind", "presence"))
                    }
                    assertEquals("The first server committed the request", 1, first.requests.size)
                    assertTrue("A lost response must not create a duplicate", second.requests.isEmpty())
                    assertEquals(second.origin, transport.currentOrigin())
                }
            }
        }
    }

    @Test fun ambiguousRedemptionCanRecoverWithTheExactSameBody() {
        HttpProbe(null).use { first ->
            HttpProbe("{\"ok\":true}").use { second ->
                val transport = BackendTransport(networkClient(), listOf(first.origin, second.origin))
                val body = JSONObject().put("code", "123456789012").put("controllerToken", controllerToken)
                assertTrue(transport.execute("POST", "/v1/sessions/redeem", null, body).getBoolean("ok"))
                assertEquals(1, first.requests.size)
                assertEquals(1, second.requests.size)
                assertEquals(first.requests.single(), second.requests.single())
                assertEquals(controllerToken, JSONObject(second.requests.single()).getString("controllerToken"))
            }
        }
    }

    @Test fun redirectsNeverForwardSessionCredentialsToAnotherOrigin() {
        HttpProbe("{}", 302, "Location: https://unrelated.test/steal\r\n").use { server ->
            val transport = BackendTransport(networkClient(), listOf(server.origin, fallback))
            val error = assertThrows(CloudflareBackendException::class.java) {
                transport.execute("GET", "/v1/sessions/$session", "private-session-token", null)
            }
            assertEquals(302, error.statusCode)
            assertEquals(1, server.requests.size)
        }
    }

    @Test fun nonIdempotentRequestCanUseFallbackBeforeAnyHeadersAreSent() {
        val transport = BackendTransport(OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().url.host == primary.host) throw ConnectException("offline")
            assertTrue(chain.request().body!!.isOneShot())
            response(chain.request(), 201, "{\"sessionId\":\"created-once\"}")
        }.build(), listOf(primary, fallback))
        assertEquals("created-once", transport.execute("POST", "/v1/sessions", null, null).getString("sessionId"))
    }

    @Test fun fastFallbackReachesTheSecondIpWithoutWaitingForTheBlackholedIpTimeout() {
        HttpProbe("{\"ok\":true}").use { server ->
            val started = CountDownLatch(1)
            val canceled = CountDownLatch(1)
            val blocked = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 2))
            val socketFactory = object : SocketFactory() {
                override fun createSocket(): Socket = object : Socket() {
                    @Volatile private var blackholed = false
                    override fun connect(endpoint: java.net.SocketAddress, timeout: Int) {
                        blackholed = (endpoint as InetSocketAddress).address == blocked
                        if (!blackholed) { super.connect(endpoint, timeout); return }
                        started.countDown()
                        if (!canceled.await(timeout.toLong(), TimeUnit.MILLISECONDS)) throw SocketTimeoutException("blackhole")
                        throw SocketException("canceled losing route")
                    }
                    override fun close() { if (blackholed) canceled.countDown(); super.close() }
                }
                override fun createSocket(host: String, port: Int) = createSocket().apply { connect(InetSocketAddress(host, port)) }
                override fun createSocket(host: InetAddress, port: Int) = createSocket().apply { connect(InetSocketAddress(host, port)) }
                override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int) =
                    createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
                override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int) =
                    createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
            }
            val client = CloudflareBackend.httpClient.newBuilder()
                .dispatcher(Dispatcher()).connectionPool(ConnectionPool())
                .proxy(Proxy.NO_PROXY).socketFactory(socketFactory)
                .dns { listOf(blocked, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))) }
                .build()
            val before = System.nanoTime()
            try {
                client.newCall(Request.Builder().url("http://race.aaris.test:${server.origin.port}/healthz").build())
                    .execute().use { assertEquals(200, it.code) }
                val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before)
                assertTrue("The first address must actually be tried", started.await(1, TimeUnit.SECONDS))
                assertTrue("The losing connect must be canceled", canceled.await(1, TimeUnit.SECONDS))
                assertTrue("Fallback took $elapsedMs ms instead of racing IPs", elapsedMs < 3_000)
                assertEquals(1, server.requests.size)
            } finally {
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
            }
        }
    }

    private fun networkClient() = OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
        .connectTimeout(2, TimeUnit.SECONDS).readTimeout(2, TimeUnit.SECONDS)
        .callTimeout(4, TimeUnit.SECONDS).build()

    private fun response(request: Request, status: Int, json: String) = Response.Builder()
        .request(request).protocol(okhttp3.Protocol.HTTP_1_1).code(status).message("probe")
        .body(json.toResponseBody()).build()

    private class HttpProbe(private val json: String?, private val status: Int = 200,
        private val extraHeaders: String = "") : AutoCloseable {
        private val server = ServerSocket(0, 8, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
        val origin = "http://127.0.0.1:${server.localPort}/".toHttpUrl()
        val requests = CopyOnWriteArrayList<String>()
        private val failure = AtomicReference<Throwable>()
        private val thread = Thread({
            try {
                while (!server.isClosed) server.accept().use { socket ->
                    socket.soTimeout = 3_000
                    val reader = socket.getInputStream().bufferedReader()
                    var line = reader.readLine() ?: return@use
                    var length = 0
                    while (line.isNotEmpty()) {
                        if (line.startsWith("Content-Length:", true)) length = line.substringAfter(':').trim().toInt()
                        line = reader.readLine() ?: return@use
                    }
                    val chars = CharArray(length)
                    var read = 0
                    while (read < length) {
                        val count = reader.read(chars, read, length - read)
                        check(count > 0)
                        read += count
                    }
                    requests += String(chars)
                    if (json != null) socket.getOutputStream().apply {
                        write(("HTTP/1.1 $status Probe\r\nContent-Type: application/json\r\n" +
                            "Connection: close\r\nContent-Length: ${json.toByteArray().size}\r\n" +
                            "$extraHeaders\r\n$json").toByteArray())
                        flush()
                    }
                }
            } catch (error: Throwable) { if (!server.isClosed) failure.set(error) }
        }, "backend-http-probe").apply { isDaemon = true; start() }

        override fun close() {
            server.close()
            thread.join(4_000)
            assertFalse("HTTP probe did not stop", thread.isAlive)
            failure.get()?.let { throw AssertionError("HTTP probe failed", it) }
        }
    }
}
