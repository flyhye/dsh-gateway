# 给 VS Code 扩展仓库的issue草稿

> 用法：到扩展仓库（Vithrive/Deepseek-Harness-for-VS-Code）开一个
> Feature Request / Discussion，把下面内容粘贴进去。附上 dsh-gateway.mjs
> 作为概念验证。

---

标题：建议：扩展内置「持久密钥签发 Cookie」，彻底去掉粘贴认证链接 / 重启认证流程

## 现状

dsh web（0.2.x）的一次性启动令牌只存在于 `dsh web` 进程内存，每次重启都会更换。
当前扩展获取令牌只有两条路：

1. 由扩展自己启动 dsh，从 stdout 抓 `dsh web: ...?token=`
2. 用户手动点「粘贴认证链接」

这导致一个高频冲突：**dsh 由外部启动时（命令行 / 快捷方式 / 开机自启），
扩展拿不到令牌，只能引导用户「重启并自动认证」——而 `restartDsh()` 会
`freePort()` 强杀端口上正在运行的实例**，中断浏览器里进行中的会话。

另外令牌缓存按 `cache.target === getUrl()` 匹配：`dshPanel.url` 若带
`?token=`（用户从浏览器地址栏复制），token 一变缓存即永久失效。

## 建议

dsh 把 browser-session 的签名密钥持久化在 `~/.dsh/.credentials.yaml`
（`client-connection/browser-session.secret`），且认证端接受**用该密钥现场
签发**的会话 Cookie（这正是浏览器登录一次保持 30 天的机制）。密钥跨进程
持久不变——扩展完全可以跳过令牌交换，直接按请求的 Host authority 现签
Cookie 注入认证代理：

- Cookie 格式：`v1.<base64url(payload)>.<base64url(HMAC-SHA256(secret, body))>`，
  payload = `{version:1, authority, issuedAt, expiresAt}`，
  Cookie 名 = `dsh-auth-` + base64url(sha256(authority))
- 密钥 32 字节 base64url，按 `.credentials.yaml` mtime 缓存（轮换自动跟上）
- 29 天有效期（略小于 dsh 默认 30 天，避开边界）

## 效果

- 删除「粘贴认证链接」整个流程与相关弹窗
- 外部启动的 dsh 不再需要重启扩展才能用
- `freePort()` 强杀路径在正常流程中不再触发
- 多 VS Code 窗口 / 浏览器同时接入互不影响

## 概念验证

一个约 200 行的独立实现（纯 Node，无依赖），已在 dsh 0.2.1-rc.3 +
扩展 1.1.1 上验证：页面 200、`/api/remote.mux` WebSocket 101 升级、
dsh 重启后无需任何操作、非回环 Host 403。代码见附件 `dsh-gateway.mjs`。

## 安全考量

网关/扩展等价于持有启动令牌：应只监听回环、只为回环（或显式声明的）
authority 签发，非本机 Host 一律拒绝。扩展已有 `isLocalLoopbackTarget`
等判定，直接沿用即可。
