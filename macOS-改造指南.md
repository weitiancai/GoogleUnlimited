# macOS 端改造指南：把 gotohp 定制为"独一份"的客户端

> 面向对象：在 macOS 上执行本改造的 agent / 工程师
> 参考实现：Windows 端已完成并验证（`C:\Users\17119\GoogleUnlimited`）
> 目标仓库：`https://github.com/shishir0x/gotohp`（上传引擎） + `https://github.com/shishir0x/GoogleUnlimited`（watcher 壳）
> 文档版本：2026-11-24（第二轮修正）

---

## 0-A. 三条硬性底线（先看这个，做错等于白做）

| # | 底线 | 为什么 |
|---|---|---|
| 1 | **机型必须是第一代 Pixel / Pixel XL，且 Android 最高只能到 10（API 29）** | Pixel 1 官方生命周期止于 Android 10（2019-09 发布，2019-12 最后一次安全更新）。**写 Android 11 / API 30 是伪造出来的组合，本身就是破绽。** Apple Silicon / Intel 都一样 |
| 2 | **凭据里的 `sdk_version` 必须与机型一致** | 上游写死 `sdk_version=33`（Android 13），与 Pixel 1 矛盾，且**每次刷新 token 都会发给 Google**。见 12.5.1 |
| 3 | **TLS 指纹随机池只放 Chromium 家族 + Android OkHttp** | 客户端自称是 Android 上的 Google Photos，网络栈是 Cronet。随机到 Safari / iOS 反而更可疑 |

已在本机 Windows 端验证通过的身份：

```
model=Pixel XL  android=Android 10(API 29)  build=QQ3A.200805.001
cronet=83.0.4103.106  client=49133800  lang=zh-CN  tls=chrome
凭据: sdk_version=29  lang=zh_CN  device_country=us  gms=240913000
```

三处（身份档案 / 凭据 / User-Agent）必须互相自洽。

---

## 0. 为什么要做这个改造

上游 gotohp 把**一套 Google Pixel 伪装身份硬编码**在源码里，导致全世界所有使用该二进制的人，在 Google 服务端看到的**指纹完全相同**：

| 硬编码项 | 位置 | 全局相同？ |
|---|---|---|
| `model = "Pixel XL"` / `make = "Google"` | `core/api.go` | ✅ 是 |
| `androidAPIVersion = 28` | `core/api.go` | ✅ 是 |
| `clientVersionCode = 49029607` | `core/api.go` | ✅ 是 |
| UA 中的 `Build/PQ2A.190205.001; Cronet/127.0.6510.5` | `core/api.go` | ✅ 是 |
| `x-goog-ext-*-bin` capability blob | `core/api.go` | ✅ 是 |
| **Go 默认 TLS ClientHello（JA3/JA4）** | Go 标准库 | ✅ 是 ← **最强的"大众特征"** |
| 上传顺序、扫描周期 | `core/upload.go` / watcher | ✅ 是 |
| `androidId` / `Token` / OAuth bearer | 凭据 | ❌ 每账号天然不同 |
| 出口 IP | 网络 | ❌ 天然不同 |

**改造目标**：把上面"全局相同"的部分改成**每台机器可配置、可随机、内在自洽**的值，同时**保持免配额功能不变**。

### 不可动的底线

以下语义直接决定"免配额"，**必须保持**：

- `model` 必须是**第一代 Pixel（Pixel / Pixel XL）**——只有这代设备的"原始画质永久免配额"权益还活着
- `Quality = 3`（原始画质）
- `storagePolicy = 3`
- `saver = false`、`use_quota = false`

---

## 1. 目标产物

macOS 上最终应得到：

```
~/GoogleUnlimited/                      # watcher 壳（仓库克隆）
├── google-unlimited.sh                 # 已改造：代理传递 + 扫描抖动
├── gotohp-cli-macos-universal          # 上游原版（保留，回滚用）
├── gotohp-cli-custom                   # ← 定制编译产物（新）
├── identity.profile                    # ← 本机唯一身份档案（新）
├── gotohp.config                       # 凭据 + proxy 设置
├── watch_dirs.txt                      # 监控目录
└── gphotos.db                          # 上传历史
```

---

## 2. 环境准备

```bash
# 检查 Go（需要 >= 1.27，仓库 go.mod 要求 go 1.27.0）
go version
# 若没有：brew install go  # 或 https://go.dev/dl/

# 检查基础工具
sqlite3 --version
curl --version
```

### 克隆上游引擎

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/xob0t/gotohp.git gotohp-custom
cd gotohp-custom
git log --oneline -1     # 记录基线 commit，写进交付说明
```

---

## 3. 改造点 1：身份层（`core/identity.go` 新建文件）

新建 `core/identity.go`，把原先散落在 `core/api.go` 的常量收敛到一处，并支持**运行时环境变量覆盖**（这样不用重新编译就能临时改）：

```go
package core

import (
	"fmt"
	"os"
	"strconv"
)

// Device identity presented to Google Photos.
//
// Upstream hard-codes a single Pixel profile, so every installation looks
// byte-identical on the wire. The values below are collected in one place so
// that a build, or a single run, can present a coherent and unique profile.
//
// Build-time overrides (go build -ldflags):
//   -X app/core.DefaultDeviceModel=Pixel
// Runtime overrides (environment variables):
//   GOTOHP_DEVICE_MODEL / GOTOHP_DEVICE_MAKE / GOTOHP_ANDROID_VERSION /
//   GOTOHP_ANDROID_API / GOTOHP_BUILD / GOTOHP_CLIENT_VERSION /
//   GOTOHP_CRONET_VERSION / GOTOHP_AUTH_UA / GOTOHP_LANG
var (
	DefaultDeviceModel         = "Pixel XL"
	DefaultDeviceMake          = "Google"
	DefaultDeviceAndroidVer    = "Android 9"
	DefaultDeviceAndroidAPI    = "28"
	DefaultDeviceBuild         = "PQ2A.190205.001"
	DefaultClientVersionCode   = "49029607"
	DefaultCronetVersion       = "127.0.6510.5"
	DefaultGoogleAuthUserAgent = "GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip"
	DefaultLanguage            = ""
	DefaultSaverModel          = "Pixel 2"
	DefaultQuotaModel          = "Pixel 8"
	DefaultClientExt173412678  = "<从 upstream 原样搬运，不要手改>"
	DefaultClientExt174067345  = "<从 upstream 原样搬运，不要手改>"
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func IdentityModel() string         { return envOr("GOTOHP_DEVICE_MODEL", DefaultDeviceModel) }
func IdentityMake() string          { return envOr("GOTOHP_DEVICE_MAKE", DefaultDeviceMake) }
func IdentityAndroidVer() string    { return envOr("GOTOHP_ANDROID_VERSION", DefaultDeviceAndroidVer) }
func IdentityAndroidAPI() int64 {
	n, err := strconv.ParseInt(envOr("GOTOHP_ANDROID_API", DefaultDeviceAndroidAPI), 10, 64)
	if err != nil || n <= 0 { n = 28 }
	return n
}
func IdentityBuild() string         { return envOr("GOTOHP_BUILD", DefaultDeviceBuild) }
func IdentityClientVersionCode() int64 {
	n, err := strconv.ParseInt(envOr("GOTOHP_CLIENT_VERSION", DefaultClientVersionCode), 10, 64)
	if err != nil || n <= 0 { n = 49029607 }
	return n
}
func IdentityCronetVersion() string { return envOr("GOTOHP_CRONET_VERSION", DefaultCronetVersion) }
func IdentityAuthUserAgent() string { return envOr("GOTOHP_AUTH_UA", DefaultGoogleAuthUserAgent) }
func IdentitySaverModel() string    { return envOr("GOTOHP_SAVER_MODEL", DefaultSaverModel) }
func IdentityQuotaModel() string    { return envOr("GOTOHP_QUOTA_MODEL", DefaultQuotaModel) }

// IdentityLanguage resolves the Accept-Language sent with every request.
func IdentityLanguage(credential string) string {
	if v := os.Getenv("GOTOHP_LANG"); v != "" { return v }
	if DefaultLanguage != "" { return DefaultLanguage }
	return credential
}

// AppUserAgent renders the Google Photos app User-Agent for the active identity.
func AppUserAgent(language string) string {
	return fmt.Sprintf(
		"com.google.android.apps.photos/%d (Linux; U; %s; %s; %s; Build/%s; Cronet/%s) (gzip)",
		IdentityClientVersionCode(), IdentityAndroidVer(), language,
		IdentityModel(), IdentityBuild(), IdentityCronetVersion(),
	)
}
```

### ⚠️ blob 常量的搬运方式

`x-goog-ext-173412678-bin` / `x-goog-ext-174067345-bin` 的原始值在仓库里（base64），**用脚本搬运，不要手抄**：

```bash
# 从 upstream core/api.go 抽取原值，写进 identity.go
python3 - <<'PY'
import re
api = open('core/api.go', encoding='utf-8').read()
pat = re.compile(r'"x-goog-ext-173412678-bin": "([^"]*)",\n\s*"x-goog-ext-174067345-bin": "([^"]*)",')
m = pat.search(api)
a, b = m.group(1), m.group(2)
idp = open('core/identity.go', encoding='utf-8').read()
idp = idp.replace('DefaultClientExt173412678  = "<从 upstream 原样搬运，不要手改>"',
                  f'DefaultClientExt173412678  = "{a}"')
idp = idp.replace('DefaultClientExt174067345  = "<从 upstream 原样搬运，不要手改>"',
                  f'DefaultClientExt174067345  = "{b}"')
open('core/identity.go', 'w', encoding='utf-8').write(idp)
print("blob values injected")
PY
```

---

## 4. 改造点 2：改造 `core/api.go`

### 4.1 构造函数

把：

```go
	api := &Api{
		androidAPIVersion: 28,
		model:             "Pixel XL",
		make:              "Google",
		clientVersionCode: 49029607,
		language:          params.Get("lang"),
		...
	}

	api.userAgent = fmt.Sprintf(
		"com.google.android.apps.photos/%d (Linux; U; Android 9; %s; %s; Build/PQ2A.190205.001; Cronet/127.0.6510.5) (gzip)",
		api.clientVersionCode,
		api.language,
		api.model,
	)
```

替换为：

```go
	api := &Api{
		androidAPIVersion: IdentityAndroidAPI(),
		model:             IdentityModel(),
		make:              IdentityMake(),
		clientVersionCode: IdentityClientVersionCode(),
		language:          IdentityLanguage(params.Get("lang")),
		...
	}

	api.userAgent = AppUserAgent(api.language)
```

### 4.2 GoogleAuth UA

```go
// 之前
		"User-Agent":      "GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip",
// 之后
		"User-Agent":      IdentityAuthUserAgent(),
```

### 4.3 saver / quota 机型

```go
// 之前
	if a.saver { qualityVal = 1; a.model = "Pixel 2" }
	if a.useQuota { a.model = "Pixel 8" }
// 之后
	if a.saver { qualityVal = 1; a.model = IdentitySaverModel() }
	if a.useQuota { a.model = IdentityQuotaModel() }
```

`core/create_media_items.go` 里同样的两处也要改：

```go
		if api.saver { model = IdentitySaverModel() }
		if api.useQuota { model = IdentityQuotaModel() }
```

### 4.4 capability blob

把 `core/api.go` 中**所有**出现的：

```go
		"x-goog-ext-173412678-bin": "<原值>",
		"x-goog-ext-174067345-bin": "<原值>",
```

替换为：

```go
		"x-goog-ext-173412678-bin": extA,
		"x-goog-ext-174067345-bin": extB,
```

并在**每一个**包含这两行的 `headers := map[string]string{` **之前**插入一行：

```go
	extA, extB := IdentityClientExt()
```

> ⚠️ 上游有 **3 处** header map 用了这两个 blob（commit / createMediaItems / 另一条 commit 路径）。用脚本批量替换，别漏。

在 `core/identity.go` 追加：

```go
// IdentityClientExt returns the opaque client capability blobs sent with
// commit requests.
func IdentityClientExt() (string, string) {
	return envOr("GOTOHP_EXT_173412678", DefaultClientExt173412678),
		envOr("GOTOHP_EXT_174067345", DefaultClientExt174067345)
}
```

---

## 5. 改造点 3：TLS 指纹模拟（**最重要的一层**）

> 这是消除"大众特征"收益最大的改造：Go 标准库的 ClientHello 让所有 gotohp 用户共享同一个 JA3/JA4。

### 5.1 加依赖

```bash
go get github.com/refraction-networking/utls@latest
go mod tidy
```

### 5.2 新建 `core/tlsfingerprint.go`

```go
package core

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	utls "github.com/refraction-networking/utls"
)

// DefaultTLSFingerprint selects the ClientHello profile to emulate.
var DefaultTLSFingerprint = "chrome"

func TLSFingerprintName() string {
	return envOr("GOTOHP_TLS_FINGERPRINT", DefaultTLSFingerprint)
}

func tlsFingerprintEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(TLSFingerprintName()))
	return v != "" && v != "off" && v != "none" && v != "0"
}

// chromeHelloID maps a profile name to a uTLS ClientHello ID.
// The exact constant set depends on the utls version; run
//   grep -n "= ClientHelloID{" $(go env GOMODCACHE)/github.com/refraction-networking/utls@*/u_common.go
// and pick from what your version provides.
func chromeHelloID(profile string) (utls.ClientHelloID, bool) {
	switch strings.ToLower(strings.TrimSpace(profile)) {
	case "chrome", "":
		return utls.HelloChrome_Auto, true
	case "chrome_133":
		return utls.HelloChrome_133, true
	case "chrome_120":
		return utls.HelloChrome_120, true
	case "chrome_115":
		return utls.HelloChrome_115_PQ, true
	case "chrome_106":
		return utls.HelloChrome_106_Shuffle, true
	case "chrome_102":
		return utls.HelloChrome_102, true
	case "chrome_96":
		return utls.HelloChrome_96, true
	case "chrome_87":
		return utls.HelloChrome_87, true
	case "firefox":
		return utls.HelloFirefox_120, true
	case "safari":
		return utls.HelloSafari_16_0, true
	case "edge":
		return utls.HelloEdge_106, true
	case "android":
		return utls.HelloAndroid_11_OkHttp, true
	case "ios":
		return utls.HelloIOS_14, true
	default:
		return utls.ClientHelloID{}, false
	}
}

// bufferedConn replays bytes read ahead while parsing the proxy CONNECT reply.
type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }

func proxyFromEnvironmentRaw() string {
	for _, key := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"} {
		raw := strings.TrimSpace(os.Getenv(key))
		if raw != "" {
			return raw
		}
	}
	return ""
}

// dialThroughProxy opens a tunnel to targetAddr through an HTTP proxy.
func dialThroughProxy(ctx context.Context, proxyURL *url.URL, targetAddr string, timeout time.Duration) (net.Conn, error) {
	proxyAddr := proxyURL.Host
	if proxyURL.Port() == "" {
		switch strings.ToLower(proxyURL.Scheme) {
		case "https":
			proxyAddr = net.JoinHostPort(proxyURL.Hostname(), "443")
		default:
			proxyAddr = net.JoinHostPort(proxyURL.Hostname(), "80")
		}
	}

	dialer := &net.Dialer{Timeout: timeout}
	conn, err := dialer.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, err
	}

	req := &http.Request{
		Method: http.MethodConnect,
		URL:    &url.URL{Opaque: targetAddr},
		Host:   targetAddr,
		Header: http.Header{},
	}
	if user := proxyURL.User; user != nil {
		password, _ := user.Password()
		req.Header.Set("Proxy-Authorization",
			"Basic "+base64.StdEncoding.EncodeToString([]byte(user.Username()+":"+password)))
	}

	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(timeout))
	}
	if err := req.Write(conn); err != nil {
		conn.Close()
		return nil, err
	}

	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		conn.Close()
		return nil, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		conn.Close()
		return nil, fmt.Errorf("proxy CONNECT failed: %s", resp.Status)
	}
	_ = conn.SetDeadline(time.Time{})
	return &bufferedConn{Conn: conn, reader: br}, nil
}

// newFingerprintDialer performs a uTLS handshake with the selected browser
// profile, tunnelling through an HTTP proxy when one is configured.
func newFingerprintDialer(profile string, proxyURL *url.URL, timeout time.Duration) func(ctx context.Context, network, addr string) (net.Conn, error) {
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		helloID, ok := chromeHelloID(profile)
		if !ok {
			return nil, fmt.Errorf("unsupported TLS fingerprint profile: %s", profile)
		}

		var rawConn net.Conn
		if proxyURL != nil {
			rawConn, err = dialThroughProxy(ctx, proxyURL, addr, timeout)
		} else {
			dialer := &net.Dialer{Timeout: timeout}
			rawConn, err = dialer.DialContext(ctx, network, addr)
		}
		if err != nil {
			return nil, err
		}

		spec, err := utls.UTLSIdToSpec(helloID)
		if err != nil {
			rawConn.Close()
			return nil, err
		}
		// Speak only HTTP/1.1 in ALPN: the returned connection is not a
		// *tls.Conn, so the standard library cannot negotiate HTTP/2 on it.
		for i := range spec.Extensions {
			if alpn, ok := spec.Extensions[i].(*utls.ALPNExtension); ok {
				alpn.AlpnProtocols = []string{"http/1.1"}
			}
		}

		uconn := utls.UClient(rawConn, &utls.Config{
			ServerName: host,
			MinVersion: tls.VersionTLS12,
		}, utls.HelloCustom)
		if err := uconn.ApplyPreset(&spec); err != nil {
			rawConn.Close()
			return nil, err
		}
		if err := uconn.HandshakeContext(ctx); err != nil {
			rawConn.Close()
			return nil, err
		}
		state := uconn.ConnectionState()
		if !state.HandshakeComplete || len(state.PeerCertificates) == 0 {
			rawConn.Close()
			return nil, fmt.Errorf("TLS handshake did not complete")
		}
		return uconn, nil
	}
}

// applyTLSFingerprint installs the fingerprint dialer on the transport.
// Any failure falls back to the standard Go TLS stack so uploads keep working.
func applyTLSFingerprint(transport *http.Transport, proxyURL *url.URL, timeout time.Duration) {
	if !tlsFingerprintEnabled() {
		return
	}
	profile := TLSFingerprintName()
	dialTLS := newFingerprintDialer(profile, proxyURL, timeout)

	transport.DialTLSContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := dialTLS(ctx, network, addr)
		if err == nil {
			return conn, nil
		}
		d := &tls.Dialer{Config: transport.TLSClientConfig, NetDialer: &net.Dialer{Timeout: timeout}}
		return d.DialContext(ctx, network, addr)
	}
}
```

### 5.3 改 `core/httpclient.go`（**关键：代理路径必须自己 tunnel**）

> ⚠️ **这是最容易踩的坑**：Go 的 `http.Transport` 在配置了 proxy 时，`connectMethod.scheme()` 返回的是**代理的 scheme**，于是标准库自己做 CONNECT + 标准 TLS 握手，**自定义 `DialTLSContext` 根本不会被调用**，指纹模拟静默失效。
> 解决办法：启用指纹模拟时，把 `transport.Proxy` 置为 `nil`，改由自定义 dialer 内部完成 CONNECT。

```go
func NewHTTPClientWithProxy(proxyURLStr string) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig.InsecureSkipVerify = false

	transport.MaxIdleConns = 100
	transport.MaxIdleConnsPerHost = 10
	transport.MaxConnsPerHost = 10
	transport.IdleConnTimeout = 90 * time.Second

	proxyURL, err := resolveProxy(proxyURLStr)
	if err != nil {
		return nil, err
	}
	if proxyURLStr != "" && proxyURL != nil {
		transport.Proxy = http.ProxyURL(proxyURL)
		transport.TLSClientConfig.InsecureSkipVerify = true
	}

	if tlsFingerprintEnabled() {
		// The custom dialer establishes the proxy tunnel itself.
		transport.Proxy = nil
		applyTLSFingerprint(transport, proxyURL, 30*time.Second)
	}

	client := &http.Client{
		Transport: transport,
		Timeout:   0,
	}
	return client, nil
}

// resolveProxy returns the proxy URL to use, or nil when none applies.
func resolveProxy(proxyURLStr string) (*url.URL, error) {
	raw := strings.TrimSpace(proxyURLStr)
	if raw == "" {
		raw = proxyFromEnvironmentRaw()
	}
	if raw == "" {
		return nil, nil
	}
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("failed to parse proxy URL: %w", err)
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https", "socks5", "socks5h":
		return u, nil
	default:
		return nil, fmt.Errorf("unsupported proxy scheme: %s", u.Scheme)
	}
}
```

### 5.4 验证指纹真的变了

```bash
# 起一个本地监听，抓 ClientHello，对比不同 profile
mkdir -p /tmp/fpcheck && cat > /tmp/fpcheck/main.go <<'EOF'
package main

import (
	"fmt"
	"net"
	"os"
	"time"

	"app/core"
)

func main() {
	for _, profile := range []string{"chrome", "chrome_133", "firefox", "safari"} {
		ln, _ := net.Listen("tcp", "127.0.0.1:0")
		go func() {
			c, _ := ln.Accept()
			buf := make([]byte, 512)
			n, _ := c.Read(buf)
			c.Close()
			ln.Close()
			os.WriteFile(fmt.Sprintf("/tmp/ch_%s.bin", profile), buf[:n], 0644)
		}()
		os.Setenv("GOTOHP_TLS_FINGERPRINT", profile)
		client, err := core.NewHTTPClientWithProxy("")
		if err != nil { fmt.Println("err:", err); continue }
		go func() { _, _ = client.Get("https://" + ln.Addr().String() + "/") }()
		time.Sleep(300 * time.Millisecond)
	}
}
EOF
mkdir -p cmd/fpcheck && cp /tmp/fpcheck/main.go cmd/fpcheck/main.go
go run ./cmd/fpcheck
xxd /tmp/ch_chrome.bin | head -3
xxd /tmp/ch_firefox.bin | head -3
# 两者应明显不同（cipher suite 列表 / extension 顺序 / GREASE 值）
rm -rf cmd/fpcheck
```

**代理路径也要验证**（本地起一个 CONNECT 代理再抓一次，见 Windows 端 `cmd/proxytest` 的实现思路）。

---

## 6. 改造点 4：行为去特征化

### 6.1 `core/upload.go`：随机上传顺序 + 随机间隔

在 `UploadManager` 里 `numWorkers := min(opts.Threads, len(workItems))` **之前**插入：

```go
	// Shuffle the work order. A fixed ordering is a strong behavioural
	// fingerprint across installations of this client.
	shuffleWorkItems(workItems)
```

新增函数（放在 `runWorker` 之前）：

```go
// shuffleWorkItems randomises the upload order.
func shuffleWorkItems(items []UploadWorkItem) {
	if len(items) < 2 {
		return
	}
	rand.Shuffle(len(items), func(i, j int) {
		items[i], items[j] = items[j], items[i]
	})
}

// interUploadDelay returns a randomised pause before the next upload so the
// request pattern does not look machine generated.
func interUploadDelay() time.Duration {
	base := envInt("GOTOHP_UPLOAD_DELAY_MIN_MS", 800)
	spread := envInt("GOTOHP_UPLOAD_DELAY_JITTER_MS", 2400)
	if base <= 0 && spread <= 0 {
		return 0
	}
	if spread < 0 {
		spread = 0
	}
	return time.Duration(base+rand.Intn(spread+1)) * time.Millisecond
}

// envInt reads a non-negative integer environment variable.
func envInt(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n := 0
	for _, c := range v {
		if c < '0' || c > '9' {
			return fallback
		}
		n = n*10 + int(c-'0')
	}
	return n
}
```

在 `runWorker` 的 `for item := range workChan {` 循环体开头插入随机延迟：

```go
	for item := range workChan {
		select {
		case <-cancel:
			...
			return
		case <-time.After(interUploadDelay()):
		}
		select {
		case <-cancel:
			...
```

并确保 import 里有 `"math/rand"` 和 `"time"`。

### 6.2 `google-unlimited.sh`：扫描周期抖动

上游是固定 15 分钟（`sleep 900` 之类）。改为带抖动：

```bash
# 原来
SWEEP_INTERVAL=900
# 改成
SWEEP_BASE=900
SWEEP_JITTER=420
# 每次重算
new_sweep_interval() {
    local delta=$(( RANDOM % (2 * SWEEP_JITTER + 1) - SWEEP_JITTER ))
    echo $(( SWEEP_BASE + delta ))
}
```

调用处（Phase 2 主循环里）把固定的 `sleep 900` 换成动态值。

> macOS 的 `$RANDOM` 在 bash 3.2+ 可用。若脚本用 `sh` 兼容模式，请改用 `awk` 或 `openssl rand`。

---

## 7. 改造点 5：身份档案（每机一份，可复现）

新建 `core/identity_profile.go`：定义**真实存在**的 Pixel / Pixel XL 机型档案表，保证 `model / Android 版本 / build / Cronet 版本` 四者**自洽**（服务端做一致性校验时不自相矛盾）。

```go
package core

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Both first generation Pixels (sailfish / marlin) stopped at Android 10
// (API 29). Android 10 shipped September 2019 and December 2019 was the final
// security update. Android 11 on these devices exists only as a third-party
// ROM, so advertising it would contradict the model and look forged.
var pixelBuilds = []struct {
	Model, AndroidVer, AndroidAPI, Build, CronetVersion string
}{
	{"Pixel XL", "Android 9", "28", "PQ2A.190205.001", "68.0.3440.91"},
	{"Pixel XL", "Android 9", "28", "PQ3A.190801.002", "70.0.3538.110"},
	{"Pixel XL", "Android 10", "29", "QQ3A.200805.001", "76.0.3809.132"},
	{"Pixel XL", "Android 10", "29", "QQ3A.200805.001", "80.0.3987.132"},
	// NO Android 11: first generation Pixels stopped at Android 10 (API 29).
	{"Pixel", "Android 9", "28", "PQ2A.190205.001", "68.0.3440.91"},
	{"Pixel", "Android 9", "28", "PQ3A.190801.002", "72.0.3626.121"},
	{"Pixel", "Android 10", "29", "QQ3A.200805.001", "78.0.3904.108"},
	{"Pixel", "Android 10", "29", "QQ3A.200805.001", "83.0.4103.116"},
	{"Pixel XL", "Android 10", "29", "QQ3A.200805.001", "83.0.4103.106"},
	{"Pixel", "Android 8.1", "27", "OPM4.171019.021.P1", "68.0.3440.70"},
}

var clientVersionCodes = []int64{
	48995415, 49010401, 49029607, 49038112, 49043514,
	49100411, 49133800, 49175518, 49220104, 49266983,
}

var languageProfiles = []string{
	"zh-CN", "zh-TW", "zh-HK", "en-US", "en-GB", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES",
}

// Random identities only draw from this pool.
//
// The emulated client is Google Photos on Android, whose network stack is
// Cronet (Chromium). Safari / iOS / Firefox / Edge would therefore be an
// inconsistency in themselves, so they are manual opt-ins only.
var tlsFingerprintProfiles = []string{
	"chrome", "chrome_133", "chrome_131", "chrome_120", "chrome_115",
	"chrome_106", "chrome_102", "chrome_96", "chrome_87",
	"android",
}

// OptionalTLSFingerprintProfiles are selectable only on purpose.
var OptionalTLSFingerprintProfiles = []string{
	"firefox", "safari", "edge", "ios",
}

type IdentityProfile struct {
	Model, Make, AndroidVersion, AndroidAPI   string
	Build, CronetVersion, Language            string
	ClientVersion                              int64
	AuthUserAgent, TLSFingerprint              string
	SaverModel, QuotaModel                     string
	CreatedAt                                  string
	Seed                                       int64
}

func RandomIdentity(rnd *rand.Rand) IdentityProfile {
	p := pixelBuilds[rnd.Intn(len(pixelBuilds))]
	profile := IdentityProfile{
		Model: p.Model, Make: "Google",
		AndroidVersion: p.AndroidVer, AndroidAPI: p.AndroidAPI,
		Build: p.Build, CronetVersion: p.CronetVersion,
		Language:      languageProfiles[rnd.Intn(len(languageProfiles))],
		ClientVersion: clientVersionCodes[rnd.Intn(len(clientVersionCodes))],
		TLSFingerprint: tlsFingerprintProfiles[rnd.Intn(len(tlsFingerprintProfiles))],
		SaverModel:    "Pixel 2",
		QuotaModel:    "Pixel 8",
	}
	profile.AuthUserAgent = profile.AuthUserAgentFor()
	profile.Seed = rnd.Int63()
	profile.CreatedAt = time.Now().Format(time.RFC3339)
	return profile
}

func (p IdentityProfile) AuthUserAgentFor() string {
	return fmt.Sprintf("GoogleAuth/1.4 (%s %s); gzip", p.Model, p.Build)
}

func (p IdentityProfile) Describe() string {
	return fmt.Sprintf("model=%s android=%s(API %s) build=%s cronet=%s client=%d lang=%s tls=%s",
		p.Model, p.AndroidVersion, p.AndroidAPI, p.Build, p.CronetVersion,
		p.ClientVersion, p.Language, p.TLSFingerprint)
}

// ApplyToDefaults makes the profile the built-in default for this process.
// Environment variables still take precedence.
func (p IdentityProfile) ApplyToDefaults() {
	DefaultDeviceModel = p.Model
	DefaultDeviceMake = p.Make
	DefaultDeviceAndroidVer = p.AndroidVersion
	DefaultDeviceAndroidAPI = p.AndroidAPI
	DefaultDeviceBuild = p.Build
	DefaultClientVersionCode = fmt.Sprintf("%d", p.ClientVersion)
	DefaultCronetVersion = p.CronetVersion
	DefaultGoogleAuthUserAgent = p.AuthUserAgent
	DefaultLanguage = p.Language
	DefaultTLSFingerprint = p.TLSFingerprint
	DefaultSaverModel = p.SaverModel
	DefaultQuotaModel = p.QuotaModel
}

func ProfilePath(configPath string) string {
	dir := "."
	if configPath != "" {
		dir = filepath.Dir(configPath)
	}
	return filepath.Join(dir, "identity.profile")
}

// LoadProfile / SaveProfile 用简单的 key=value 文本格式
func LoadProfile(configPath string) (*IdentityProfile, error) { /* 解析 key=value */ }
func SaveProfile(configPath string, p IdentityProfile) error   { /* 写 key=value，权限 0600 */ }
```

### 7.1 在 `core/configmanager.go` 中自动加载

`LoadConfig` 里加一行，让每次启动自动套用档案：

```go
func LoadConfig(path string) error {
	configMu.Lock()
	defer configMu.Unlock()
	ConfigPath = path
	// A stored identity profile sits next to the config and defines the
	// device identity this installation presents. Environment variables still
	// take precedence over the stored profile.
	applyStoredProfile(path)
	return loadConfigLocked()
}

func applyStoredProfile(configPath string) {
	p, err := LoadProfile(configPath)
	if err != nil {
		return
	}
	p.ApplyToDefaults()
}
```

### 7.2 加 `identity` 子命令

新建 `internal/cli/identity.go`：

```go
package cli

import (
	"fmt"
	"math/rand"
	"time"

	"app/core"

	"github.com/spf13/cobra"
)

func newIdentityCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "identity",
		Short: "Show or generate the emulated device identity used for uploads",
		Args:  cobra.NoArgs,
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			configPath, _ := cmd.Flags().GetString("config")
			return core.LoadConfig(configPath)
		},
		RunE: func(cmd *cobra.Command, _ []string) error {
			return showIdentity(cmd)
		},
	}
	gen := &cobra.Command{
		Use:   "generate",
		Short: "Generate a new unique device identity and store it next to the config",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return generateIdentity(cmd)
		},
	}
	gen.Flags().Int64("seed", 0, "deterministic seed (0 picks a random one)")
	gen.Flags().String("model", "", "force a device model: Pixel or Pixel XL")
	gen.Flags().String("tls", "", "force a TLS fingerprint profile, e.g. chrome_133")
	gen.Flags().String("lang", "", "force the Accept-Language value, e.g. zh-CN")
	cmd.AddCommand(gen)
	return cmd
}
```

在 `internal/cli/cli.go` 注册：

```go
	root.AddCommand(newUploadCommand(), newCredentialsCommand(), newIdentityCommand(), ...)
	// 并把 IsCLIInvocation 的白名单加上 "identity"
	return slices.Contains([]string{"upload", "credentials", "creds", "identity", "help", "version"}, arg)
```

---

## 8. 编译 macOS 产物

```bash
cd ~/src/gotohp-custom

# CLI-only 构建（跳过 Wails GUI）
GOOS=darwin GOARCH=arm64 go build -tags cli -ldflags "-s -w" -o ~/GoogleUnlimited/gotohp-cli-custom .
# Intel Mac：
GOOS=darwin GOARCH=amd64 go build -tags cli -ldflags "-s -w" -o ~/GoogleUnlimited/gotohp-cli-custom-amd64 .
```

> `-tags cli` 很重要：`main.go` 是 Wails GUI 入口（`//go:build !cli`），`main_cli.go` 是 CLI 入口（`//go:build cli`）。

### 校验与回滚

```bash
cd ~/GoogleUnlimited
chmod 700 gotohp-cli-custom
shasum -a 256 gotohp-cli-custom     # 记录进交付说明
# 回滚：把原版 gotohp-cli-macos-universal 复制回去即可
```

---

## 9. 接入 watcher（macOS 侧）

### 9.1 让 `google-unlimited.sh` 优先使用定制二进制

在上游脚本的 `get_gotohp_bin()` 候选列表里，把 `gotohp-cli-custom` 放在**第一位**：

```bash
get_gotohp_bin() {
    local cands=("$SCRIPT_DIR/gotohp-cli-custom" "$SCRIPT_DIR/gotohp-cli")
    ...
}
```

### 9.2 代理必须显式传给 CLI（**关键**）

> gotohp CLI **只从 config 读凭据**，`proxy` / `quality` 等一律走 flag。
> 更重要的是：**launchd / 后台启动的进程拿不到你 shell 里的 `HTTPS_PROXY` 环境变量**，
> 而直连 Google 在很多网络环境下根本不通 → 上传全部失败并卡在重试队列。
> 所以代理必须**写进 `gotohp.config` 并由脚本显式 `--proxy` 传给 CLI**。

在 `gotohp.config` 里设置：

```yaml
preferences:
    proxy: "http://127.0.0.1:7897"   # 换成你实际的代理端口
```

在 `google-unlimited.sh` 的 `run_gotohp()` 里统一追加 `--proxy`：

```bash
run_gotohp() {
    local bin cmd=()
    bin="$(get_gotohp_bin)"
    [ -z "$bin" ] && { echo "ERROR: gotohp-cli binary not found" >&2; return 1; }

    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        cmd+=("--config" "$SCRIPT_DIR/gotohp.config")
        # 读取 config 里的 proxy 并传 --proxy
        local cfg_proxy
        cfg_proxy="$(grep -E '^[[:space:]]*proxy:' "$SCRIPT_DIR/gotohp.config" 2>/dev/null \
                    | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
        if [ -n "$cfg_proxy" ] && [ "$cfg_proxy" != " " ]; then
            cmd+=("--proxy" "$cfg_proxy")
        fi
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi
    # 环境变量兜底
    if [ ${#cmd[@]} -eq 0 ] || ! printf '%s\n' "${cmd[@]}" | grep -q -- "--proxy"; then
        local env_proxy="${GOTOHP_PROXY:-${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}}"
        if [ -n "$env_proxy" ]; then
            cmd+=("--proxy" "$env_proxy")
        fi
    fi
    "$bin" "${cmd[@]}" "$@"
}
```

> ⚠️ `creds` 子命令**不接受** `--proxy`（只有 `upload` 有）。
> 如果给 `creds list` 也加了 `--proxy` 会报 `unknown flag: --proxy`。
> 处理方式：给 `run_gotohp` 加一个开关，或者在调用 creds 的地方单独走不带 proxy 的路径。

---

## 10. 生成 macOS 端的身份档案

```bash
cd ~/GoogleUnlimited
./gotohp-cli-custom --config gotohp.config identity generate --model "Pixel" --tls chrome --lang zh-CN
cat identity.profile
./gotohp-cli-custom --config gotohp.config identity
```

> **建议 Windows 与 macOS 使用不同的 model**：
> Windows 用 `Pixel XL`，macOS 用 `Pixel`（同样是第一代，永久免配额原始画质），
> 两台机器就不会在服务端呈现完全相同的机型字段。

> ⚠️ **凭据不要跨机共用**：两台机器共用同一个 `androidId`/`Token`，
> 服务端会看到"同一台设备"出现在两个不同 IP → 极其明显的异常。
> **macOS 必须单独走一遍 Embedded Setup 生成自己的 oauth_token**。

### macOS 获取 oauth_token

```bash
# 1. 浏览器打开
open "https://accounts.google.com/embedded/setup/v2/android"
# 2. 登录 → 点"I agree"（页面会一直转圈，这是正常的）
# 3. F12 → Application/Storage → Cookies → accounts.google.com → oauth_token
# 4. 粘贴（隐藏输入，不进历史）
./gotohp-cli-custom --config gotohp.config creds add
# 或管道方式
echo "<oauth_token>" | ./gotohp-cli-custom --config gotohp.config creds add -
chmod 600 gotohp.config
```

---

## 11. 验收清单

```bash
cd ~/GoogleUnlimited

# 1. 身份档案生效
./gotohp-cli-custom --config gotohp.config identity
#    → 确认 Effective identity 与 identity.profile 一致

# 2. TLS 指纹确实变了（直连 + 代理两条路径）
#    → 抓到的 ClientHello 应与 upstream 二进制不同

# 3. 单文件上传成功
./gotohp-cli-custom --config gotohp.config upload --no-tui "/path/to/test.jpg"
#    → "success": true，带 mediaKey

# 4. 网页端确认免配额（**必须人工确认**）
#    打开 https://photos.google.com → 点开刚上传的文件 → ⓘ 信息
#    → 应显示"原始画质" + "此内容不会占用您的账号存储空间"

# 5. 代理生效（不带环境变量也能传）
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
  ./gotohp-cli-custom --config gotohp.config upload --no-tui "/path/to/test2.jpg"

# 6. watcher 端到端
./google-unlimited.sh watch   # 前台跑，看进度
#    往监控目录丢一个文件，确认 1~5 秒内被捕获并上传
./google-unlimited.sh status

# 7. 后台常驻
./google-unlimited.sh enable   # launchd LaunchAgent
./google-unlimited.sh status
```

---

## 12. 常见坑速查

### 12.0 ⚠️ 必读：启动全量扫描会阻塞主循环（已修复，务必照搬）

**这是 macOS 端改造时最容易遗漏、也最难自己发现的问题。** 详细分析与修复方案见 **12.1**。

一句话版：上游 `google-unlimited.sh` 把“每 30 秒重试 flush”和“每 15 分钟安全扫”写在主循环里，
但**启动全量扫描在主循环之前**。监控目录文件一多（几千个），扫描要跑几小时，
期间主循环一次都不会执行 → **重试队列完全冻结**（`attempts` 恒为 1、`last_attempt` 不变），
而你看到上传日志一直在刷（那是事件处理器干的）→ 误以为“系统在跑”。

**验收时务必确认**：`sqlite3 gphotos.db "SELECT MAX(last_attempt) FROM retry_queue;"`
的值会随时间推进，否则就是踩了这个坑。

### 12.1 详细排查与修复| 现象 | 原因 / 处理 |
|---|---|
| **重试队列不消化（`Pending Retries` 不变）** | ⚠️ **重点看 12.1**：启动全量扫描（Phase 1）会阻塞主循环，重试 flush 根本没运行。需按 12.1 重构 |
| 上传全失败，日志 `dial tcp ...: i/o timeout` | **后台进程没有代理环境变量**。把 proxy 写进 `gotohp.config` 并由脚本 `--proxy` 传参（见 9.2） |
| `unknown flag: --proxy` | `creds` 子命令不支持该 flag，只给 `upload` 传 |
| 指纹模拟"没生效" | Go 在配置了 proxy 时会用标准库做 CONNECT+TLS，绕过自定义 dialer。必须 `transport.Proxy = nil`（见 5.3） |
| `unsupported TLS fingerprint profile` | utls 版本没有该常量，查 `u_common.go` 里的 `= ClientHelloID{` 列表 |
| `ApplyPreset` 参数类型错 | utls v1.8 需要 `*ClientHelloSpec`，即 `ApplyPreset(&spec)` |
| `ALPNExtension` 类型断言失败 | 扩展在 `spec.Extensions` 里的具体类型是 `*utls.ALPNExtension`，用类型断言取，不要用 `Id` 字段比较 |
| 改完仍然"像大众" | 检查 `identity` 命令输出是否真的变了；确认 `identity.profile` 存在且 `LoadConfig` 加载了它 |
| 上传变慢 | 正常：指纹模拟只走 HTTP/1.1，且每次上传前有 0.8~3.2s 随机延迟 |
| 配额开始计入 | 检查 `saver`/`use_quota` 是否被误改；`model` 必须仍是第一代 Pixel |
| Gatekeeper 阻止运行 | `xattr -d com.apple.quarantine gotohp-cli-custom && chmod 700 gotohp-cli-custom` |
| 需要完全磁盘访问 | 系统设置 → 隐私与安全性 → 完全磁盘访问权限，添加终端 |

### 12.1 ⚠️ 重点：重试队列不消化 / “Retry queue: N file(s) pending” 不变

**这是 macOS 端最需要重点排查的问题，Windows 端已确认踩过并修复。**

**现象**：状态栏一直显示 `Pending Retries: 32`，数字几乎不动；`retry_queue` 表里所有条目的
`attempts` 恒为 1、`last_attempt` 停在某个旧时间点；明明有文件没上传成功，却始终没有新的重试记录。

**根因（Windows 端实测定位）**：**启动全量扫描（Phase 1）会阻塞主循环**。

```
主循环结构（上游原版）:
  while (true) {
      每 30 秒  -> 重试 flush      ← 位于 while 内部
      每 15 分钟 -> 安全扫
  }
  但 Phase 1（启动全量扫描）在 while 循环之前！
```

Phase 1 对监控目录做 `Get-ChildItem -Recurse`，逐个同步上传（每个约 10~30 秒）。
当监控目录里有 2500 个媒体文件时，Phase 1 需要 **数小时**。在这段时间里：

- 主循环根本没开始 → **重试 flush 一次都没跑过** → 重试队列冻结
- 安全扫也没跑过
- 你看到的每一条上传日志都来自 **FileSystemWatcher 事件处理器**（异步、独立于主循环），
  所以“看起来在传”，但重试队列纹丝不动

**这就是“为什么它一直不更新”的答案**，而不是队列逻辑本身坏了。

**验证方法（3 步定位）**：

```bash
# 1) 看重试条目的时间戳是否在推进
sqlite3 gphotos.db "SELECT COUNT(*), MAX(last_attempt) FROM retry_queue;"
#    若 MAX(last_attempt) 停住不动 → 确认重试流程没被触发

# 2) 看有没有 “Phase 1 完成” 的记录
grep -c "Phase 1" logs/activity.log
#    或在 logs 表里查
sqlite3 gphotos.db "SELECT * FROM logs WHERE message LIKE '%Phase%' OR message LIKE '%Startup%';"
#    查不到 → Phase 1 还没结束

# 3) 对比磁盘文件数与已上传数
find ~/Pictures -type f | wc -l          # 磁盘上的媒体数
sqlite3 gphotos.db "SELECT COUNT(*) FROM uploads;"   # 已入库数
#    差值大 → Phase 1 还在跑
```

**修复方案（Windows 端已实施，macOS 端照搬）**：

把“每 30 秒重试 flush” 和 “每 15 分钟安全扫” 抽成两个函数，并让 Phase 1
**每上传一批文件就主动让出一次**，这样重试队列在启动扫描期间也能正常消化。

1. 抽出 `invoke_retry_flush` 函数：

```bash
# 每次最多处理 N 个文件，避免长时间阻塞调用方
invoke_retry_flush() {
    local max_files="${1:-10}"
    local processed=0
    local qf
    # 用数组快照遍历，避免边遍历边修改关联数组
    for qf in "${RETRY_PATHS[@]}"; do
        [ "$processed" -ge "$max_files" ] && break
        is_in_flight "$qf" && continue

        if already_uploaded "$qf"; then
            remove_retry "$qf"
            continue
        fi
        [ -f "$qf" ] || { remove_retry "$qf"; continue; }

        upload_file "$qf"
        processed=$((processed + 1))
    done
}
```

2. 抽出 `invoke_safety_sweep` 函数（带 `max_files` 限制）：

```bash
# 注意：bash 管道里用 return 只能跳出当前管道，
# 必须先收集候选再 for 循环，才能真正 break
invoke_safety_sweep() {
    local max_files="${1:-0}"
    local found=0 dir f
    for dir in "${WATCH_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        while IFS= read -r f; do
            [ "$max_files" -gt 0 ] && [ "$found" -ge "$max_files" ] && break 2
            is_eligible_media "$f" || continue
            is_duplicate "$f" && continue
            log INFO "Sweep detected new file: $(basename "$f")"
            upload_file "$f"
            found=$((found + 1))
        done < <(list_media_files "$dir")
    done
}
```

3. 启动扫描**分批让出**：

```bash
# Phase 1: 启动扫描
i=0
for f in "${UNRECORDED[@]}"; do
    i=$((i + 1))
    upload_file "$f"
    # 每 20 个文件让出一次，让重试队列和安全扫有机会运行
    if [ $((i % 20)) -eq 0 ]; then
        invoke_periodic_maintenance
    fi
done
```

4. **Phase 0：重试队列优先**（新加）

已经失败过的文件应该优先于“从未见过”的文件：

```bash
# Phase 0: 先冲重试队列
if [ ${#RETRY_PATHS[@]} -gt 0 ]; then
    log INFO "Flushing ${#RETRY_PATHS[@]} retry-queued file(s) first..."
    guard=0
    while [ ${#RETRY_PATHS[@]} -gt 0 ] && [ "$guard" -lt 500 ]; do
        before=${#RETRY_PATHS[@]}
        invoke_retry_flush 10
        guard=$((guard + 1))
        # 一轮下来数量没减少 → 停止，避免死循环
        [ ${#RETRY_PATHS[@]} -ge "$before" ] && break
    done
fi
```

5. 主循环统一调用：

```bash
last_sweep=0
last_retry_flush=0
while true; do
    sleep 1
    now=$(date +%s)
    if [ $((now - last_retry_flush)) -ge 30 ]; then
        last_retry_flush=$now
        invoke_retry_flush 10
    fi
    if [ $((now - last_sweep)) -ge "$SWEEP_INTERVAL" ]; then
        last_sweep=$now
        invoke_safety_sweep 50
    fi
done
```

**修复后的实测效果**（Windows 端）：

```
修复前： retry count = 33，attempts 恒为 1，last_attempt 停在 19:10（完全冻结）
修复后： retry count = 32 → 28 → 22 → …  持续消化
        日志出现 SUCCESS | IMG_20160917_153943.jpg 等之前卡住的文件
```

**补充：另一个容易误判的现象**

即使修好了，`retry_queue` 也不会瞬间清空。`attempts` 恒为 1 是**正常**的——
它表示“这些文件只失败过一次，失败原因还没重试到”。
`attempts` 会累加到 `MAX_RETRY`（默认 3）后文件才被移出队列，
所以**看到 attempts=1 且 last_attempt 在更新 = 修复生效**；
**attempts 不变且 last_attempt 不动 = 仍未生效**。

### 12.2 排障方法论：给 watcher 加临时诊断

Windows 端排查时最有效的手段是**在 watcher 里临时加日志，看它走到哪一步**。macOS 端同样适用：

```bash
# 在 google-unlimited.sh 里定位上传函数，临时插入诊断输出
# 例如在调用 CLI 前后打印实际传参：
echo "DIAG launch: $GOTOHP_BIN ${args[*]}" >> "$LOG_FILE"

# 在上传完成后打印退出码与 stdout/stderr 的前 200 字符
echo "DIAG result: exit=$? out=$(echo "$out" | head -c 200)" >> "$LOG_FILE"
```

Windows 端用等价做法（在 `Invoke-Upload` 里插入 `Write-Log "DIAG ..."`），
通过 `SELECT * FROM logs WHERE message LIKE '%DIAG%'` 查库定位。

**排查顺序**（Windows 端实测有效）：

1. CLI 直传是否成功？→ `gotohp-cli-custom --config gotohp.config upload --no-tui <file>`
   成功则问题在 watcher 层；失败则问题在网络/凭据层
2. watcher 是否调用了 CLI？→ 看进程列表 / DIAG 日志
3. watcher 传的参数是否正确？→ DIAG 打印完整 argv（含 `--proxy`）
4. 是否卡在文件就绪检测？→ 打印 `Wait-ForFileReady` 的返回值
5. 是否被去重误判？→ 对比 `uploads` 表的 path / file_name+file_size / content_hash
6. **重试队列是否在消化？** → `SELECT attempts, COUNT(*), MAX(last_attempt) FROM retry_queue GROUP BY attempts`
   - `last_attempt` 在更新 → 流程正常，只是慢
   - `last_attempt` 冻结 → 见 12.1，检查 Phase 1 是否阻塞了主循环
7. **日志里有没有 “Phase 1 完成”** → 没有 = 主循环还没开始



---

---

## 12.5 第二轮实测修正（Windows 端已落地，macOS 请必看）

以下问题在 Windows 端第二轮验证中被发现并修复，**macOS 端如果已经按旧版文档实施，请对照检查**。

### 12.5.1 凭据里的设备参数必须与身份一致（最容易漏、也最硬的指纹）

上游 `core/googleauth.go` 的 `buildGooglePhotosCredential` 写死：

```go
"device_country":               {"us"},
"operatorCountry":              {"us"},
"lang":                         {"en_US"},
"sdk_version":                  {"33"},          // ← Android 13
"google_play_services_version": {"240913000"},
```

**问题一：全局相同。** 全世界所有 gotohp 用户都发 `sdk_version=33`，这比 UA 更硬 ——  UA 好歹能改，这个字段藏在凭据里。

**问题二：与机型自相矛盾。** 声称 Pixel 1（最高 Android 10 / API 29），却上报 Android 13（API 33）。
这台设备**不可能存在**，是最强的破绽。

这份凭据在**每次刷新 token 时都原样 POST 给 `android.googleapis.com/auth`**，所以矛盾会反复暴露。

**修复：把 5 个字段身份化 + 提供一个只改这 5 个字段的 normalize 命令。**

```go
// core/identity.go 追加
func IdentityDeviceCountry() string        { return envOr("GOTOHP_DEVICE_COUNTRY", "us") }
func IdentityOperatorCountry() string      { return envOr("GOTOHP_OPERATOR_COUNTRY", "us") }
func IdentityPlayServicesVersion() string  { return envOr("GOTOHP_PLAY_SERVICES_VERSION", "240913000") }
func IdentitySdkVersion() string           { return envOr("GOTOHP_SDK_VERSION", DefaultDeviceAndroidAPI) }

func CredentialLanguage() string {
    lang := strings.ReplaceAll(IdentityLanguage(""), "-", "_")
    if lang == "" { lang = "en_US" }
    return lang
}
```

```go
// core/googleauth.go
func buildGooglePhotosCredential(email, masterToken, androidID string) string {
    values := url.Values{
        // ... androidId / app / callerSig / client_sig / Email / Token 保持不变
        "device_country":               {IdentityDeviceCountry()},
        "google_play_services_version": {IdentityPlayServicesVersion()},
        "lang":                         {CredentialLanguage()},
        "operatorCountry":              {IdentityOperatorCountry()},
        "sdk_version":                  {IdentitySdkVersion()},
        // ...
    }
    return values.Encode()
}

// NormalizeCredential 只改上述 5 个字段，
// Token / androidId / Email / callerSig / client_sig 原样保留 → 无需重新登录。
func NormalizeCredential(credential string) (string, bool, error) {
    values, err := url.ParseQuery(credential)
    if err != nil { return credential, false, err }
    if values.Get("androidId") == "" || values.Get("Token") == "" {
        return credential, false, fmt.Errorf("credential is missing androidId or Token")
    }
    wanted := map[string]string{
        "device_country":               IdentityDeviceCountry(),
        "operatorCountry":              IdentityOperatorCountry(),
        "lang":                         CredentialLanguage(),
        "sdk_version":                  IdentitySdkVersion(),
        "google_play_services_version": IdentityPlayServicesVersion(),
    }
    changed := false
    for k, v := range wanted {
        if values.Get(k) != v { values.Set(k, v); changed = true }
    }
    if !changed { return credential, false, nil }
    return values.Encode(), true, nil
}
```

配一个 `creds normalize` 子命令（支持 `--dry-run`，写盘前**自动备份** config）：

```bash
./gotohp-cli-custom creds normalize --dry-run
#   user@gmail.com:
#     before: sdk_version=33 device_country=us operatorCountry=us lang=en_US gms=240913000
#     after : sdk_version=29 device_country=us operatorCountry=us lang=zh_CN gms=240913000

./gotohp-cli-custom creds normalize
#   Credentials normalized (a .bak copy of the config was written).
```

**Windows 端实测结果**：normalize 后上传照常成功（拿到 mediaKey）；
三处一致性核对通过 —— 身份档案 `android_api=29` / 凭据 `sdk_version=29` / UA `Android 10`。

> ⚠️ `exchangeEmbeddedSetupToken`（首次添加账号的一次性交换）里还有 `sdk_version=17`，
> 那是一次性请求，**可以不动**（macOS 端的判断是对的）。

### 12.5.2 uTLS 失败回退会绕过代理（真实 bug，会导致 30 秒超时）

`applyTLSFingerprint` 里的回退分支如果写成：

```go
// ❌ 错误：直连目标，绕过了代理隧道
d := &tls.Dialer{Config: transport.TLSClientConfig, NetDialer: &net.Dialer{Timeout: timeout}}
return d.DialContext(ctx, network, addr)
```

那么在「Google 只能经代理访问」的网络下，**只要 uTLS 握手偶发失败一次**，
回退路径就会直连 Google，得到：

```
dial tcp 142.251.215.74:443: i/o timeout
```

表现是「大部分时候成功，偶尔整个上传失败 3 次」。Windows 端实测踩到了。

**修复：让回退也走代理隧道。**

```go
transport.DialTLSContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
    if conn, err := dialTLS(ctx, network, addr); err == nil {
        return conn, nil
    }
    // 回退必须仍然经过代理
    var raw net.Conn
    var err error
    if proxyURL != nil {
        raw, err = dialThroughProxy(ctx, proxyURL, addr, timeout)
    } else {
        raw, err = (&net.Dialer{Timeout: timeout}).DialContext(ctx, network, addr)
    }
    if err != nil { return nil, err }
    host, _, splitErr := net.SplitHostPort(addr)
    if splitErr != nil { raw.Close(); return nil, splitErr }
    tlsConn := tls.Client(raw, &tls.Config{
        ServerName: host,
        MinVersion: tls.VersionTLS12,
        NextProtos: []string{"http/1.1"},
    })
    if err := tlsConn.HandshakeContext(ctx); err != nil { raw.Close(); return nil, err }
    return tlsConn, nil
}
```

**判据**：日志里出现 `dial tcp <Google IP>:443: i/o timeout` = 回退绕过了代理。

### 12.5.3 watcher 扩展名白名单必须与引擎一致（否则空转重试）

`WatchAndUpload.ps1` / `google-unlimited.sh` 的白名单与引擎 `core/upload.go` 的
`supportedFormats` **不一致**，产生两类浪费：

| 类别 | 扩展名 | 后果 |
|---|---|---|
| watcher 有、引擎**没有** | `svg` `jfif` `raw` `flv` `vob` | 引擎静默丢弃 → watcher 看不到 success → **重试 3 次** |
| 两边都有、但 Google **拒收** | `ico` | commit 阶段失败 → **重试 3 次** |
| 引擎有、watcher **漏了** | `sr2` `asf` `divx` `m2t` `mmv` `mod` `tod` | 文件**永远不被上传** |

**修复：白名单以引擎 `supportedFormats` 为准，去掉 Google 拒收的 `ico`，补上漏掉的格式。**

```powershell
$extList = @(
    # Standard Photos & Images
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".bmp", ".tiff", ".tif", ".avif",
    # Camera RAW
    ".dng", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".pef", ".srw", ".raf", ".sr2",
    # Video
    ".mp4", ".mov", ".mkv", ".avi", ".m4v", ".3gp", ".3g2", ".wmv", ".webm", ".mpg", ".mpeg",
    ".mts", ".m2ts", ".m2t", ".ts", ".asf", ".divx", ".mmv", ".mod", ".tod"
)
```

清理历史残留：

```sql
DELETE FROM retry_queue
WHERE lower(path) LIKE '%.svg'  OR lower(path) LIKE '%.ico'
   OR lower(path) LIKE '%.jfif' OR lower(path) LIKE '%.raw'
   OR lower(path) LIKE '%.flv'  OR lower(path) LIKE '%.vob';
```

**Windows 端实测**：`.ico` 上传返回
`upload rejected by API: media key is empty or missing`（确认 Google 拒收）。

---

## 13. 交付物清单

改造完成后请产出：

1. `~/GoogleUnlimited/gotohp-cli-custom`（或 `-amd64`）
2. `~/GoogleUnlimited/identity.profile`（内容即本机身份）
3. `~/GoogleUnlimited/gotohp.config`（含 proxy，注意不要提交到 git）
4. **改造说明**：`~/src/gotohp-custom/` 的完整 diff（`git diff > ~/src/gotohp-custom/patch.diff`）
5. **指纹摘要**：`./gotohp-cli-custom --config gotohp.config identity` 的输出
6. **二进制哈希**：`shasum -a 256 gotohp-cli-custom`
7. **验证截图**：Google Photos 网页端显示"不占用存储空间"的截图

---

## 14. 安全与合规提醒

- 本项目通过**伪装第一代 Pixel 身份**绕过 Google Photos 的配额判定，属于**违反 Google 服务条款**的行为。
- 服务端可能随时调整策略（尤其是加入设备证明 / Play Integrity 校验），**无法保证长期有效**。
- **务必**：用独立小号运行、本地保留原始副本、不要把它当作唯一备份。
- 差异化改造降低的是"被单独针对"的概率，**降低不了"整类被一刀切"的风险**。
