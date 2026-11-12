#!/usr/bin/env node
/**
 * dsh-gateway —— 给一个 dsh web 实例加一层「本机免登录」网关。
 *
 * 为什么需要：dsh web（>= 0.2.x）对每个页面/API 请求都要求签名 Cookie，而换发
 * Cookie 只能用**当前进程**的启动令牌（每次重启都会换）。于是每个新客户端
 * （VS Code 插件面板、浏览器、另一个 VS Code 窗口）都得手工粘一次带 token 的
 * 链接，且 dsh 一重启就全部失效。
 *
 * 本网关的做法：用 DSH 持久化在 $DSH_HOME/.credentials.yaml 里的
 * client-connection/browser-session 签名密钥，为**请求自己的 Host authority**
 * 现签一个会话 Cookie 注入上游。密钥是持久的，所以 dsh 重启后仍然有效；
 * 任意多个客户端可以同时接入（上游的 browser Peer 本来就是共享的）。
 *
 * 安全边界：
 *   - 只监听回环地址；能连上这个端口 = 本机同一用户 = 与直接持有 dsh 启动链接同等权限。
 *   - 只为本机回环 authority（127.0.0.1 / localhost / ::1，或 DSH_GATEWAY_ALLOW_HOSTS
 *     里显式列出的主机）签发 Cookie，其他 Host 一律 403，不给外域反向代理做跳板。
 *   - 上游的安全检查（Host/Origin 栅栏、跨站拦截）原样保留，本网关只补一张 Cookie。
 *
 * 用法：
 *   node dsh-gateway.mjs                      # 127.0.0.1:3090 -> 127.0.0.1:3080
 *   DSH_GATEWAY_PORT=3091 DSH_UPSTREAM=http://127.0.0.1:3080 node dsh-gateway.mjs
 *   DSH_HOME=/home/builder/.dsh node dsh-gateway.mjs
 *   DSH_GATEWAY_ALLOW_HOSTS=my-box.lan node dsh-gateway.mjs   # 额外放行的主机名
 *
 * 然后把 VS Code 插件的 dshPanel.url 指到 http://127.0.0.1:3090。
 */
import http from 'node:http';
import { readFileSync, statSync } from 'node:fs';
import { createHash, createHmac } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';

const UPSTREAM = new URL(process.env.DSH_UPSTREAM || 'http://127.0.0.1:3080');
const LISTEN_HOST = process.env.DSH_GATEWAY_HOST || '127.0.0.1';
const LISTEN_PORT = Number(process.env.DSH_GATEWAY_PORT || 3090);
const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh');
const CREDENTIALS_FILE = join(DSH_HOME, '.credentials.yaml');
const COOKIE_MAX_AGE_DAYS = 29; // 略小于 dsh 默认的 30 天，避开边界过期
const EXTRA_HOSTS = new Set(
  String(process.env.DSH_GATEWAY_ALLOW_HOSTS || '')
    .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean),
);
const LOOPBACK_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

if (!LOOPBACK_HOSTNAMES.has(LISTEN_HOST)) {
  console.error('dsh-gateway: 拒绝在非回环地址上监听（该网关等价于 dsh 的启动令牌）');
  process.exit(1);
}

/** 从 dsh 的凭据文件读出 browser-session 的签名密钥（32 字节）。 */
function readSecret() {
  const text = readFileSync(CREDENTIALS_FILE, 'utf8');
  const at = text.indexOf('client-connection/browser-session:');
  if (at < 0) throw new Error(`${CREDENTIALS_FILE} 中没有 client-connection/browser-session 记录`);
  const m = /secret:\s*([A-Za-z0-9_-]{40,})/.exec(text.slice(at));
  if (!m) throw new Error(`${CREDENTIALS_FILE} 中的 browser-session 记录缺少 secret`);
  const secret = Buffer.from(m[1], 'base64url');
  if (secret.byteLength !== 32) throw new Error('browser-session secret 长度异常');
  return secret;
}

/** 密钥按文件 mtime 缓存：dsh 轮换密钥后，下一次请求即自动跟上。 */
let secretCache = null;
function secret() {
  let mtimeMs = 0;
  try {
    mtimeMs = statSync(CREDENTIALS_FILE).mtimeMs;
  } catch (e) {
    throw new Error(`读不到 ${CREDENTIALS_FILE}: ${e.message}`);
  }
  if (secretCache === null || secretCache.mtimeMs !== mtimeMs) {
    secretCache = { mtimeMs, value: readSecret() };
  }
  return secretCache.value;
}

const cookies = new Map(); // authority -> Cookie 头值

/** 按 dsh 的算法为某个 authority 现签一个 v1 会话 Cookie。 */
function cookieFor(authority) {
  const hit = cookies.get(authority);
  if (hit) return hit;
  const issuedAt = Date.now();
  const expiresAt = issuedAt + COOKIE_MAX_AGE_DAYS * 864e5;
  const payload = { version: 1, authority, issuedAt, expiresAt };
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const sig = createHmac('sha256', secret()).update(body).digest('base64url');
  const name = 'dsh-auth-' + createHash('sha256').update(authority).digest('base64url');
  const value = `${name}=v1.${body}.${sig}`;
  cookies.set(authority, value);
  return value;
}

/** Host 是否允许签发 Cookie：回环，或显式放行的主机名。 */
function allowedAuthority(authority) {
  let hostname;
  try {
    hostname = new URL(`http://${authority}`).hostname.toLowerCase();
  } catch {
    return false;
  }
  return LOOPBACK_HOSTNAMES.has(hostname) || EXTRA_HOSTS.has(hostname);
}

const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailers', 'transfer-encoding', 'upgrade',
]);

function upstreamHeaders(req, authority, forUpgrade) {
  const headers = { ...req.headers };
  for (const name of Object.keys(headers)) if (HOP_BY_HOP.has(name)) delete headers[name];
  if (forUpgrade) {
    headers.connection = 'Upgrade';
    headers.upgrade = req.headers.upgrade;
  }
  headers.host = authority;
  headers.cookie = cookieFor(authority);
  return headers;
}

function requestUpstream(req, authority, forUpgrade) {
  return http.request({
    host: UPSTREAM.hostname,
    port: Number(UPSTREAM.port) || 80,
    path: req.url,
    method: req.method,
    headers: upstreamHeaders(req, authority, forUpgrade),
  });
}

function reject(res, status, message) {
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8' });
  res.end(`dsh-gateway: ${message}\n`);
}

const server = http.createServer((req, res) => {
  const authority = req.headers.host || `${LISTEN_HOST}:${LISTEN_PORT}`;
  if (!allowedAuthority(authority)) return reject(res, 403, `不为此 authority 签发 Cookie: ${authority}`);

  // 只有无请求体的方法可以安全重放：POST/PUT 的流已经消费，重试会丢 body。
  const replayable = req.method === 'GET' || req.method === 'HEAD';

  const forward = (retried) => {
    const up = requestUpstream(req, authority, false);
    up.on('response', (r) => {
      if (r.statusCode === 401 && replayable && !retried) {
        r.resume();
        cookies.delete(authority); // 密钥可能已轮换：清缓存后按当前密钥重签一次
        forward(true);
        return;
      }
      const headers = { ...r.headers };
      delete headers['set-cookie']; // Cookie 由网关持有，不下发给客户端
      res.writeHead(r.statusCode, headers);
      r.pipe(res);
    });
    up.on('error', (e) => {
      if (!res.headersSent) return reject(res, 502, `上游不可达 (${e.message})`);
      res.destroy();
    });
    req.pipe(up);
  };
  forward(false);
});

server.on('upgrade', (req, socket, head) => {
  const authority = req.headers.host || `${LISTEN_HOST}:${LISTEN_PORT}`;
  if (!allowedAuthority(authority)) {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  const up = requestUpstream(req, authority, true);
  up.on('upgrade', (r, upstreamSocket, upstreamHead) => {
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n'
      + Object.entries(r.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n')
      + '\r\n\r\n',
    );
    if (upstreamHead?.length) socket.write(upstreamHead);
    upstreamSocket.pipe(socket);
    socket.pipe(upstreamSocket);
    upstreamSocket.on('error', () => socket.destroy());
    socket.on('error', () => upstreamSocket.destroy());
  });
  up.on('response', (r) => {
    r.resume();
    socket.end(`HTTP/1.1 ${r.statusCode} Rejected\r\n\r\n`);
  });
  up.on('error', () => socket.destroy());
  up.end();
});

server.on('error', (e) => {
  console.error(`dsh-gateway: 监听 ${LISTEN_HOST}:${LISTEN_PORT} 失败: ${e.message}`);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`dsh-gateway: http://${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM.origin}`);
  console.log('dsh-gateway: 使用 $DSH_HOME/.credentials.yaml 的签名密钥，dsh 重启后无需重配');
});