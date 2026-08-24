/**
 * dsh-desktop-bridge — DSH 桌面桥接插件（宿主侧）
 *
 * 让 DSH 生态里的任何插件都能与 macOS 桌面应用通信：
 *   GET  /api/desktop/status   服务器状态（pid、版本、运行时长）
 *   POST /api/desktop/notify   通过 osascript 触发 macOS 原生通知
 *
 * 这是"桌面集成即插件"的示例：桌面应用只是 DSH 插件生态的一个普通消费者，
 * 与工具卡片、子代理面板等 UI 插件处于同一条 Cordis 插件流水线上。
 */
import { execFile } from "node:child_process";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);

/**
 * 解析 **dsh 后端** 的版本号（不是本插件的！）。
 *
 * 【语义陷阱备忘】Swift 侧 BridgeClient 把这个字段渲染成 “dsh v…”，
 * 因此这里绝不能读本插件自己的 package.json——0.1.0 会冒充后端版本，
 * 错误信息比缺失信息更有害。
 *
 * 【为什么不能用 npm_package_version】该环境变量只在 npm 执行
 * package.json scripts（run-script/生命周期钩子）时由 npm 注入；
 * dsh 经 npx 缓存里的 bin.js 被 node 直接启动，全程没有 script 上下文，
 * 变量必然不存在——旧实现因此在所有真实部署形态下恒为 "unknown"。
 *
 * 数据源：从本插件位置向上做模块解析。profile 的 node_modules 里那棵
 * @deepseek-ai 树是 dsh 安装时同步出的镜像，与实际运行的副本版本一致。
 */
function resolveDSHVersion() {
  // @deepseek-ai/dsh 目前没有 exports 映射，package.json 深层导入直接放行；
  // 兜底路径防它未来加上 exports 封锁。
  try {
    return require("@deepseek-ai/dsh/package.json").version ?? null;
  } catch {
    for (const entry of ["@deepseek-ai/dsh/lib/bin.js", "@deepseek-ai/dsh"]) {
      try {
        let dir = dirname(require.resolve(entry));
        for (let i = 0; i < 6; i++) {
          try {
            return JSON.parse(readFileSync(join(dir, "package.json"), "utf8")).version ?? null;
          } catch {}
          const parent = dirname(dir);
          if (parent === dir) break;
          dir = parent;
        }
      } catch {}
    }
    return null;
  }
}

export const name = "dsh-desktop-bridge";
export const inject = ["webServer"];

export function apply(ctx) {
  const startedAt = Date.now();
  // 进程存续期内后端版本不变，启动时解析一次即可；失败回退 "unknown"
  const dshVersion = resolveDSHVersion() ?? "unknown";

  // 服务器状态：供桌面应用健康检查 / 状态栏展示
  // 注意：ctx.effect(callback) 会立即执行 callback 并把其返回值当作
  // disposer 保存，因此必须把 register 调用包在箭头函数里返回。
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/desktop/status",
    handler: async (_req, res) => {
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      res.end(JSON.stringify({
        ok: true,
        pid: process.pid,
        uptimeMs: Date.now() - startedAt,
        version: dshVersion,
        profile: process.env.DSH_PROFILE ?? "web",
      }));
    },
  }));

  // 原生通知：通过 osascript 触发（无需额外权限）
  ctx.effect(() => ctx.webServer.register({
    kind: "exact",
    path: "/api/desktop/notify",
    handler: async (req, res) => {
      let body = "";
      for await (const chunk of req) body += chunk;
      let payload = {};
      try {
        payload = JSON.parse(body || "{}");
      } catch {
        // 忽略非法 JSON，走默认文案
      }
      const title = String(payload.title ?? "DSH Desktop");
      const message = String(payload.message ?? "");
      const script = `display notification ${JSON.stringify(message)} with title ${JSON.stringify(title)}`;
      execFile("/usr/bin/osascript", ["-e", script], (error) => {
        res.writeHead(error ? 500 : 200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: !error, error: error ? error.message : null }));
      });
    },
  }));

  ctx.logger.info(`dsh-desktop-bridge: /api/desktop/status + /api/desktop/notify ready (dsh v${dshVersion})`);
}
