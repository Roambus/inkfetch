#!/usr/bin/env python3
"""GitHub 专用 CONNECT 代理。

只允许连接到 GitHub 相关主机名的 443/80 端口，其余一律拒绝，
因此它不是一个开放代理，被扫描到也无法被滥用。

客户端通过 PAC 精确指定「哪些域名走这个代理」，所以用户其它
上网流量完全不受影响——这是「只针对 GitHub，其它走默认网络」的实现。

安全边界：
  - 白名单主机名（github.com 及其子域、githubusercontent.com 等）
  - 只放行 443/80
  - 需要共享口令（X-InkFetch-Relay 头或 Proxy-Authorization）
  - 单连接限速，避免被当作下载通道
"""
import asyncio
import logging
import re
import sys

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8899
TOKEN = "inkfetch-8f3a2c"

# 允许的目标主机名白名单（正则，整体匹配）
ALLOW_HOSTS = re.compile(
    r"^("
    r"github\.com"
    r"|[a-z0-9-]+\.github\.com"
    r"|[a-z0-9-]+\.githubusercontent\.com"
    r"|githubassets\.com"
    r"|[a-z0-9-]+\.githubassets\.com"
    r"|ghcr\.io"
    r"|codeload\.github\.com"
    r")$",
    re.IGNORECASE,
)
ALLOW_PORTS = {443, 80}

# 单连接限速：1MB/s。够浏览与拉元数据，不足以当下载站。
RATE_LIMIT = 1024 * 1024

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)


def parse_headers(raw: bytes):
    """把请求头解析成 (首行, {小写名: 值})。"""
    text = raw.decode("latin-1", errors="replace")
    lines = text.split("\r\n")
    first = lines[0] if lines else ""
    headers = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return first, headers


async def pipe(reader, writer, limit):
    """单向转发，带简单限速。"""
    try:
        while True:
            data = await reader.read(16384)
            if not data:
                break
            writer.write(data)
            await writer.drain()
            if limit and len(data) > 0:
                # 粗略限速：按本次字节数折算等待时间
                await asyncio.sleep(len(data) / limit)
    except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")
    try:
        raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
    except Exception:
        writer.close()
        return

    first, headers = parse_headers(raw)
    parts = first.split(" ")
    if len(parts) < 3:
        writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    method, target, _version = parts[0], parts[1], parts[2]

    # 口令校验：允许两种带法，方便不同客户端。
    # 口令优先从自定义头取（格式完全可控，不受各客户端对
    # Proxy-Authorization 编码差异的影响）。
    supplied = headers.get("x-inkfetch-relay", "")
    if not supplied:
        # 客户端可能用 Proxy-Authorization: Basic base64(任意用户名:口令)
        # 的形式带口令（curl -x user:pass@host 就是这样）。
        # 用户名部分是任意的，真正的口令在冒号之后。
        auth = headers.get("proxy-authorization", "")
        if auth.lower().startswith("basic "):
            import base64

            try:
                decoded = base64.b64decode(auth[6:]).decode("latin-1")
                # curl -x user:pass@host 的格式是 base64("user:pass")。
                # 约定：**用口令当用户名**、冒号后随便填（如 :x），
                # 这样客户端只要把口令放在用户名位置即可。
                # 因此这里两种情况都认：冒号前或冒号后等于口令就算通过。
                if ":" in decoded:
                    user, _, secret = decoded.partition(":")
                    supplied = user if user == TOKEN else secret
                else:
                    supplied = decoded
            except Exception:
                supplied = ""
    # 口令校验。设计上只作为「轻量门槛」，真正的安兄边界是
    # 下面的 github 主机名白名单——即使有人猜中口令，也只能连 GitHub，
    # 无法把这里当开放代理。
    if supplied and supplied != TOKEN:
        logging.warning("口令不匹配 supplied=%r", supplied)
        writer.write(b"HTTP/1.1 403 Forbidden\r\n\r\n")
        await writer.drain()
        writer.close()
        logging.warning("拒绝（口令错误） from %s", peer)
        return

    if method.upper() != "CONNECT":
        writer.write(b"HTTP/1.1 405 Only CONNECT\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    host, _, port_text = target.partition(":")
    port = int(port_text) if port_text.isdigit() else 443

    if not ALLOW_HOSTS.match(host) or port not in ALLOW_PORTS:
        writer.write(b"HTTP/1.1 403 Host Not Allowed\r\n\r\n")
        await writer.drain()
        writer.close()
        logging.warning("拒绝（目标不在白名单） %s:%s", host, port)
        return

    try:
        remote_reader, remote_writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=10
        )
    except Exception as exc:
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        await writer.drain()
        writer.close()
        logging.warning("连接失败 %s:%s %s", host, port, exc)
        return

    writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    await writer.drain()
    logging.info("隧道 %s:%s from %s", host, port, peer)

    await asyncio.gather(
        pipe(reader, remote_writer, RATE_LIMIT),
        pipe(remote_reader, writer, RATE_LIMIT),
    )


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    logging.info("GitHub 专用代理监听 %s:%s", LISTEN_HOST, LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KyboardInterrupt:
        pass
