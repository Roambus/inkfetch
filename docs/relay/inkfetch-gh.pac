// InkFetch GitHub 加速 PAC
//
// 只有 GitHub 相关域名走中转代理，其它一切流量保持 DIRECT，
// 因此不影响用户任何其它上网行为。
//
// 代理只对 GitHub 主机名开放（服务端白名单），即便 PAC 被改坏
// 也无法被当作开放代理滥用。

function FindProxyForURL(url, host) {
    var h = host.toLowerCase();

    // GitHub 主域及其子域
    if (h === "github.com" || dnsDomainIs(h, ".github.com")) {
        return "PROXY 8.133.220.160:8899";
    }
    // raw / objects / avatars 等 CDN
    if (dnsDomainIs(h, ".githubusercontent.com")) {
        return "PROXY 8.133.220.160:8899";
    }
    if (h === "githubassets.com" || dnsDomainIs(h, ".githubassets.com")) {
        return "PROXY 8.133.220.160:8899";
    }
    if (h === "ghcr.io") {
        return "PROXY 8.133.220.160:8899";
    }

    // 其余全部直连
    return "DIRECT";
}
