# dsh-gateway — 让浏览器和 VS Code 同时免登录使用 dsh web

一个约 200 行的 Node.js 反向代理。它解决 dsh web 0.2.x 的一个高频痛点：
**浏览器和 VS Code 面板无法同时免登录使用 dsh**。

- 只依赖 Node.js（无第三方包）
- 只监听 127.0.0.1
- dsh 重启后依然免登录，无需重新粘贴任何令牌链接
- 任意多个客户端同时接入

## 背景：为什么会有这个问题

dsh web（>= 0.2.x）对每个页面/API 请求都要求签名 Cookie，而换取 Cookie
必须持有一个**一次性启动令牌**（`dsh web` 每次启动随机生成，只打印一次）。

于是每个新客户端都会遇到同一连串问题：

```
VS Code 面板拿不到 token
  → 提示「无法认证」
  → 用户点「重启并自动认证」
  → 扩展杀掉端口上正在运行的 dsh 并自己重启
  → 浏览器里正在进行的会话全部断开
```

「粘贴认证链接」也只能撑到 dsh 下一次重启。

## 原理

dsh 在 `~/.dsh/.credentials.yaml` 里持久化了一把 browser-session 签名密钥
（32 字节，安装后不变）。dsh 的认证端同时接受**用这把密钥现场签发**的
会话 Cookie——这正是浏览器登录一次后能保持 30 天的机制。

本网关把这把密钥利用起来：收到请求时，按请求自己的 Host authority
现签一个会话 Cookie 注入上游，再转发。密钥持久 ⇒ 网关签出的 Cookie
永远有效 ⇒ **dsh 随便重启，客户端零感知**。

```
 浏览器 ──────┐
              ▼
        网关 127.0.0.1:3090 ──现签 Cookie──► dsh web 127.0.0.1:3080
              ▲
 VS Code 面板 ┘
```

上游的全部安全检查（Host/Origin 栅栏、跨站拦截）原样保留，网关只补一张 Cookie。

## 安装

前提：已安装 Node.js 和 `@deepseek-ai/dsh`（`npm install -g`）。

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

它会：

1. 把脚本装到 `~/.dsh/bin`
2. 在桌面创建「DeepSeek Harness」快捷方式（启动 dsh + 网关 + 浏览器）
3. 打印需要写进 VS Code `settings.json` 的一行配置
4. 立即启动并自检

## VS Code 设置

`settings.json` 里只需要这一行：

```json
{ "dshPanel.url": "http://127.0.0.1:3090" }
```

注意**不要带 token**、也不要 `autoStart`：扩展探测网关得到 200，
会跳过整个认证流程，不再弹窗、更不会去杀正在运行的 dsh。

## 日常使用

| 场景 | 操作 |
|---|---|
| 启动 | 双击桌面快捷方式（或运行 `~/.dsh/bin/start-dsh.ps1`） |
| 用 VS Code 面板 | 打开面板即可，免登录 |
| 用浏览器 | 打开 `http://127.0.0.1:3090`，免登录 |
| dsh 重启后 | 什么都不用做 |
| 停止 | `powershell -File ~/.dsh/bin/stop-dsh.ps1` |

端口可自定义：`start-dsh.ps1 -Port 3080 -GatewayPort 3090`。

## 安全边界

- **只监听回环地址**：非回环启动会被拒绝。能连上这个端口 = 本机同一用户，
  与持有 dsh 启动链接同等权限。
- **只为本机 authority 签发 Cookie**：`127.0.0.1` / `localhost` / `::1`，
  其余 Host 一律 403（可用 `DSH_GATEWAY_ALLOW_HOSTS=my-box.lan` 显式放行）。
- 不给外域反向代理做跳板；上游安全检查原样保留。
- **不要把 `~/.dsh/.credentials.yaml` 分享给任何人**——它就是你账号的钥匙。

## 兼容性

- 针对 dsh 0.2.x 的 Cookie 格式（`v1` 载荷 + HMAC-SHA256 + base64url，
  Cookie 名 = `dsh-auth-` + sha256(authority)）。dsh 后续版本若改动该格式，
  需要同步更新 `cookieFor()`。
- 密钥按文件 mtime 缓存：dsh 轮换密钥（重新生成 credentials）后，下一次
  请求自动跟上，不用重启网关。

## 常见问题

**网关报 502？** 上游 dsh 还没起来或端口不对。看 `~/.dsh/gateway-<端口>.log`，
确认 `dsh web` 真的在运行：`curl -I http://127.0.0.1:3080/`（401 也算在运行）。

**VS Code 面板白屏？** 确认 `dshPanel.url` 指向**网关端口**（3090）而不是
3080，且不带 `?token=`。然后命令面板执行 `Developer: Reload Window`。

**端口被占用？** 换端口即可：`start-dsh.ps1 -GatewayPort 3091`，
同步修改 `dshPanel.url`。

**多台机器/远程服务器？** 网关只服务本机。远程场景建议用 SSH 端口转发，
不要放行非回环 Host。

## 卸载

删除桌面快捷方式和 `~/.dsh/bin` 里这几个文件即可：
`dsh-gateway.mjs`、`start-dsh.ps1`、`start-dsh.vbs`、`stop-dsh.ps1`，
再把 `dshPanel.url` 改回你原来的值。
