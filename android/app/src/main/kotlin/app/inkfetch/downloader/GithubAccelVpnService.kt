package app.inkfetch.downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean

/**
 * GitHub 加速用的 DNS 分流 VPN。
 *
 * 只做一件事：接管系统 DNS 查询，把 GitHub 相关域名解析成我们实测可用的 IP，
 * 其余域名照常转发给上游 DNS。**不转发、不代理任何正文流量**，因此
 * 不会影响用户其它应用的网络行为，也不需要公网代理服务器。
 *
 * 相比 Windows 改 hosts，Android 不允许普通应用改 hosts（需要 root），
 * VpnService 是官方提供的、唯一能按应用生效且可随时关闭的做法。
 *
 * 工作方式：
 *  - 建立一条只包含我们自己地址的 tun（10.111.222.1/32），
 *    并把自己设为 DNS 服务器，这样系统的 DNS 请求会送到我们这里；
 *  - 从 tun 读 IP 报文，拆出 UDP:53 的查询；
 *  - 若查询的域名在加速表里，直接用表里的 IP 应答；否则转发上游；
 *  - 其它任何流量（TCP、非 53 端口的 UDP）一律丢回内核以外的地方——
 *    因为没加路由，系统不会把它们送进来。
 */
class GithubAccelVpnService : VpnService() {

    companion object {
        const val ACTION_START = "app.inkfetch.downloader.ACCEL_START"
        const val ACTION_STOP = "app.inkfetch.downloader.ACCEL_STOP"
        const val ACTION_STATE = "app.inkfetch.downloader.ACCEL_STATE"

        const val EXTRA_UPSTREAM = "upstream_dns"
        const val EXTRA_DOMAIN_IPS = "domain_ips"
        const val EXTRA_ACTIVE = "active"
        const val EXTRA_MESSAGE = "message"

        private const val CHANNEL_ID = "inkfetch_accel"
        private const val NOTIFICATION_ID = 4311
        // tun 内部地址：只用于接管 DNS，不承载任何实际流量。
        private const val VPN_ADDRESS = "10.111.222.1"
        private const val VPN_MTU = 1500
        // 连续这么多次转发失败就自动关闭加速，避免用户彻底断网。
        private const val MAX_CONSECUTIVE_FAILURES = 8

        @Volatile var isActive: Boolean = false
            private set

        /** 供 Flutter 侧查询当前是否在运行。 */
        @Volatile var lastMessage: String = ""
            private set

        internal fun setState(active: Boolean, message: String) {
            isActive = active
            lastMessage = message
        }
    }

    private var tun: ParcelFileDescriptor? = null
    private val running = AtomicBoolean(false)
    private var worker: Thread? = null

    /// 连续转发失败计数。达到上限就自动关闭 VPN。
    ///
    /// 这是安全兜底：万一在某个 ROM 上转发不通，我们不能让用户的
    /// 设备一直处于"DNS 全挂"的状态——那等于彻底断网。
    /// 宁可自动关掉加速，让系统回到原本可用的网络。
    private var consecutiveFailures = 0

    /** 域名 -> 要返回的 IP（来自 Dart 侧实测结果）。 */
    private val overrides = HashMap<String, String>()

    /** 上游 DNS，用于转发不属于 GitHub 的查询。 */
    private var upstream: String = "223.5.5.5"

    /**
     * 上游 DNS 列表：按顺序尝试，前一个失败就用下一个。
     *
     * 单个上游是「浏览器上不了网」的隐患——运营商 DNS 偶尔会超时、
     * 或被地区限制，一旦它挂了，所有非 GitHub 域名就都解析不出来。
     * 这里准备多家公共 DNS 兜底。
     */
    private val upstreams: List<String>
        get() {
            val list = mutableListOf<String>()
            if (upstream.isNotBlank()) list.add(upstream)
            for (candidate in listOf("223.5.5.5", "119.29.29.29", "1.1.1.1", "8.8.8.8")) {
                if (candidate != upstream) list.add(candidate)
            }
            return list
        }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopVpn("已关闭 GitHub 加速")
                return START_NOT_STICKY
            }
            ACTION_START -> {
                upstream = intent.getStringExtra(EXTRA_UPSTREAM) ?: "223.5.5.5"
                @Suppress("UNCHECKED_CAST")
                val map = intent.getSerializableExtra(EXTRA_DOMAIN_IPS)
                    as? HashMap<String, String>
                overrides.clear()
                map?.forEach { (k, v) -> overrides[k.lowercase()] = v }
                if (overrides.isEmpty()) {
                    setState(false, "没有可用的 IP，未启动")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startVpn()
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startVpn() {
        if (running.get()) {
            setState(true, "加速已开启")
            return
        }
        // 只声明 IPv4 地址与 DNS。
        //
        // 这里刻意**不加 IPv6**。上一版为了"把 v6 查询也收进来"同时
        // 声明了 v6 地址与 v6 DNS，但我们的报文处理只认 IPv4，
        // 收到的 v6 查询被直接丢弃 → 那些查询全部超时 →
        // 浏览器打不开网页。这正是「开了加速就断网」的真凶。
        //
        // 只声明 v4 时，系统不会把 v6 的 DNS 发给我们，而是继续用
        // 底层网络原本的 v6 DNS，v6 解析照常工作——这比"接管然后丢掉"安全得多。
        val builder = Builder()
            .setSession("墨取 GitHub 加速")
            .addAddress(VPN_ADDRESS, 32)
            .setMtu(VPN_MTU)
            .addDnsServer(VPN_ADDRESS)
            // 阻塞模式：非阻塞下读不到数据会立刻返回，循环空转烧 CPU，
            // 设备变慢也表现为"上不了网"。
            .setBlocking(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            // 本应用自己不走这条 VPN：转发查询要用本机网络，
            // 若被自己的 tun 接管会形成回环。
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
            }
        }

        val descriptor = try {
            builder.establish()
        } catch (e: Exception) {
            null
        }
        if (descriptor == null) {
            setState(false, "无法建立 VPN（可能被其它 VPN 占用）")
            stopSelf()
            return
        }

        tun = descriptor
        running.set(true)
        setState(true, "加速已开启")
        // 不再自己 startForeground：VpnService 建立后系统会为 VPN 显示
        // 常驻通知（这是系统行为，应用无需也不能用前台服务顶替它）。
        // 主动 startForeground 在没有声明 foregroundServiceType 时
        // 在 Android 14+ 会抛 MissingForegroundServiceTypeException。
        showNotification()

        worker = Thread({ pump(descriptor) }, "inkfetch-accel-dns").apply {
            isDaemon = true
            start()
        }
    }

    /**
     * 主循环：从 tun 读原始 IP 报文，处理 UDP:53。
     *
     * 只处理 IPv4 + UDP + 目的端口 53 的包，其余直接忽略。
     */
    private fun pump(descriptor: ParcelFileDescriptor) {
        val input = java.io.FileInputStream(descriptor.fileDescriptor)
        val output = java.io.FileOutputStream(descriptor.fileDescriptor)
        val buffer = ByteArray(VPN_MTU)
        while (running.get()) {
            val length = try {
                input.read(buffer)
            } catch (e: Exception) {
                // 读失败（tun 已关闭 / 被系统回收）就退出循环。
                break
            }
            if (length <= 0) {
                // 阻塞模式下读到 0 说明通道已无可用数据，
                // 稍等再试，避免空转把 CPU 打满。
                if (!running.get()) break
                try {
                    Thread.sleep(10)
                } catch (_: InterruptedException) {
                    break
                }
                continue
            }
            try {
                handlePacket(buffer, length, output)
            } catch (_: Exception) {
                // 单个包解析失败不该拖垮整个服务。
            }
        }
    }

    private fun handlePacket(packet: ByteArray, length: Int, output: java.io.OutputStream) {
        if (length < 20) return
        val version = (packet[0].toInt() shr 4) and 0x0F
        // IPv6 包：我们不处理，但必须在 DNS 层给出可用的回应路径。
        // 系统有时会把 DNS 查询发到 v6 地址；把它们静默丢弃会让
        // 那些查询超时（表现为网页打不开）。这里不做 v6 转发，
        // 而是靠上面同时声明 v4/v6 DNS 地址、由 v4 响应兜住。
        if (version == 6) return
        if (version != 4) return
        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (headerLength < 20 || length < headerLength + 8) return
        if (packet[9].toInt() and 0xFF != 17) return // 只处理 UDP

        val udpOffset = headerLength
        val destPort = ((packet[udpOffset + 2].toInt() and 0xFF) shl 8) or
            (packet[udpOffset + 3].toInt() and 0xFF)
        if (destPort != 53) return

        val udpLength = ((packet[udpOffset + 4].toInt() and 0xFF) shl 8) or
            (packet[udpOffset + 5].toInt() and 0xFF)
        val payloadLength = udpLength - 8
        if (payloadLength <= 0 || udpOffset + 8 + payloadLength > length) return

        val query = packet.copyOfRange(udpOffset + 8, udpOffset + 8 + payloadLength)
        val name = parseQueryName(query) ?: return

        val answer = resolveLocally(name, query) ?: forwardUpstream(query)
        if (answer == null) {
            // 上游转发也失败：记一次失败，连续失败就自我关闭，
            // 宁可不用加速，也不能让用户彻底断网。
            consecutiveFailures++
            if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
                setState(false, "DNS 转发连续失败，已自动关闭加速以免影响上网")
                stopVpn("DNS 转发失败，已自动关闭")
            }
            return
        }
        consecutiveFailures = 0

        val response = buildUdpResponse(packet, headerLength, udpOffset, answer)
        try {
            output.write(response)
        } catch (_: Exception) {
        }
    }

    /** 如果命中加速表，就地构造应答。 */
    private fun resolveLocally(name: String, query: ByteArray): ByteArray? {
        val ip = lookup(name) ?: return null
        val address = try {
            InetAddress.getByName(ip).address
        } catch (e: Exception) {
            return null
        }
        if (address.size != 4) return null
        return buildDnsAnswer(query, address)
    }

    /** 最长后缀匹配：api.github.com 命中 github.com 的条目。 */
    private fun lookup(name: String): String? {
        val lower = name.lowercase().trimEnd('.')
        overrides[lower]?.let { return it }
        for ((domain, ip) in overrides) {
            if (lower.endsWith(".$domain")) return ip
        }
        return null
    }

    /**
     * 非 GitHub 域名：原样转发给上游 DNS。
     *
     * 这是「开了加速之后浏览器上不了网」最容易出问题的地方：
     * 一旦这里返回 null，系统就拿不到任何解析结果，浏览器表现为
     * 「无法访问此网站」。所以这里必须做到尽量不失败：
     *   - 准备多个上游，失败就换下一个；
     *   - 每次转发都设超时，否则 DNS 卡住会拖死整个上网体验。
     */
    private fun forwardUpstream(query: ByteArray): ByteArray? {
        for (server in upstreams) {
            val answer = tryForward(query, server)
            if (answer != null) return answer
        }
        return null
    }

    private fun tryForward(query: ByteArray, server: String): ByteArray? {
        return try {
            DatagramSocket().use { socket ->
                // 关键：把我们自己的 socket 绑定到「不经过本 VPN」的底层网络。
                //
                // 不这么做的话，转发出去的查询会被这条 VPN 再次捕获
                // （即使 addDisallowedApplication 排除了本应用，
                // 某些 ROM 上仍会回环），形成自己问自己，永远没有回包。
                // protect() 让该 socket 走真实网络，这是 VpnService 的
                // 标准做法，也是「开加速后浏览器断网」的另一个常见原因。
                if (!protect(socket)) {
                    return null
                }
                socket.soTimeout = 2500
                val target = InetAddress.getByName(server)
                socket.send(
                    DatagramPacket(query, query.size, InetSocketAddress(target, 53))
                )
                val buffer = ByteArray(4096)
                val response = DatagramPacket(buffer, buffer.size)
                socket.receive(response)
                buffer.copyOfRange(0, response.length)
            }
        } catch (e: Exception) {
            null
        }
    }

    /** 解析查询里的域名（跳过 DNS 头，处理 label 压缩指针）。 */
    private fun parseQueryName(query: ByteArray): String? {
        if (query.size < 13) return null
        val builder = StringBuilder()
        var index = 12
        while (index < query.size) {
            val len = query[index].toInt() and 0xFF
            if (len == 0) break
            if (len and 0xC0 == 0xC0) break // 压缩指针，查询里正常不出现
            index++
            if (index + len > query.size) return null
            if (builder.isNotEmpty()) builder.append('.')
            builder.append(String(query, index, len, Charsets.US_ASCII))
            index += len
        }
        val name = builder.toString()
        return if (name.isEmpty()) null else name
    }

    /** 构造一条 A 记录应答。 */
    private fun buildDnsAnswer(query: ByteArray, address: ByteArray): ByteArray {
        // 找到查询末尾（域名 + QTYPE + QCLASS）。
        var index = 12
        while (index < query.size) {
            val len = query[index].toInt() and 0xFF
            if (len == 0) {
                index++
                break
            }
            if (len and 0xC0 == 0xC0) {
                index += 2
                break
            }
            index += len + 1
        }
        val questionEnd = (index + 4).coerceAtMost(query.size)
        val question = query.copyOfRange(12, questionEnd)

        val out = java.io.ByteArrayOutputStream()
        // 头：沿用查询的 ID，设响应位 + 有应答。
        out.write(query[0].toInt() and 0xFF)
        out.write(query[1].toInt() and 0xFF)
        out.write(0x81) // QR=1, RD=1
        out.write(0x80) // RA=1, RCODE=0
        out.write(0x00); out.write(0x01) // QDCOUNT=1
        out.write(0x00); out.write(0x01) // ANCOUNT=1
        out.write(0x00); out.write(0x00) // NSCOUNT
        out.write(0x00); out.write(0x00) // ARCOUNT
        out.write(question)
        // 应答：压缩指针指向问题里的域名。
        out.write(0xC0); out.write(0x0C)
        out.write(0x00); out.write(0x01) // TYPE=A
        out.write(0x00); out.write(0x01) // CLASS=IN
        out.write(0x00); out.write(0x00); out.write(0x00); out.write(0x3C) // TTL=60
        out.write(0x00); out.write(0x04) // RDLENGTH=4
        out.write(address)
        return out.toByteArray()
    }

    /** 把 DNS 应答包成发回给发起方的 UDP/IP 报文。 */
    private fun buildUdpResponse(
        request: ByteArray,
        headerLength: Int,
        udpOffset: Int,
        payload: ByteArray
    ): ByteArray {
        val sourceIp = request.copyOfRange(12, 16)
        val destIp = request.copyOfRange(16, 20)
        val sourcePort = request.copyOfRange(udpOffset, udpOffset + 2)
        val destPort = request.copyOfRange(udpOffset + 2, udpOffset + 4)

        val udpLength = 8 + payload.size
        val totalLength = 20 + udpLength
        val packet = ByteArray(totalLength)

        packet[0] = 0x45
        packet[1] = 0x00
        packet[2] = ((totalLength shr 8) and 0xFF).toByte()
        packet[3] = (totalLength and 0xFF).toByte()
        packet[4] = 0x00; packet[5] = 0x00
        packet[6] = 0x40; packet[7] = 0x00 // DF
        packet[8] = 64 // TTL
        packet[9] = 17 // UDP
        packet[10] = 0x00; packet[11] = 0x00 // 校验和稍后填
        // 源/目的地址互换
        System.arraycopy(destIp, 0, packet, 12, 4)
        System.arraycopy(sourceIp, 0, packet, 16, 4)
        val ipChecksum = checksum(packet, 0, 20)
        packet[10] = ((ipChecksum shr 8) and 0xFF).toByte()
        packet[11] = (ipChecksum and 0xFF).toByte()

        // UDP 头：端口互换
        System.arraycopy(destPort, 0, packet, 20, 2)
        System.arraycopy(sourcePort, 0, packet, 22, 2)
        packet[24] = ((udpLength shr 8) and 0xFF).toByte()
        packet[25] = (udpLength and 0xFF).toByte()
        packet[26] = 0x00; packet[27] = 0x00 // 不校验，0 表示无校验
        System.arraycopy(payload, 0, packet, 28, payload.size)
        return packet
    }

    private fun checksum(data: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var i = offset
        while (i < offset + length - 1) {
            sum += (((data[i].toInt() and 0xFF) shl 8) or
                (data[i + 1].toInt() and 0xFF)).toLong()
            i += 2
        }
        if (i < offset + length) {
            sum += (data[i].toInt() and 0xFF shl 8).toLong()
        }
        while (sum shr 16 != 0L) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        return (sum.inv() and 0xFFFF).toInt()
    }

    private fun stopVpn(message: String) {
        running.set(false)
        try {
            worker?.interrupt()
        } catch (_: Exception) {
        }
        worker = null
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        setState(false, message)
        // 只清理我们自己发的普通通知；系统的 VPN 常驻通知会在
        // tun 关闭后由系统自动撤下，不需要（也不该）用 stopForeground。
        val manager = getSystemService(NotificationManager::class.java)
        manager?.cancel(NOTIFICATION_ID)
        stopSelf()
    }

    override fun onRevoke() {
        stopVpn("VPN 权限已被系统或其它应用收回")
        super.onRevoke()
    }

    override fun onDestroy() {
        running.set(false)
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        setState(false, "加速已停止")
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "GitHub 加速",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "保持 DNS 分流加速运行"
            manager?.createNotificationChannel(channel)
        }
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("墨取 · GitHub 加速运行中")
            .setContentText("${overrides.size} 个域名走加速 DNS")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
            .setContentIntent(openApp)
            .build()
    }

    private fun showNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, buildNotification())
    }
}
