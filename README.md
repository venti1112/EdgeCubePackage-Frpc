# frpc-android-lib

把 [frp](https://github.com/fatedier/frp) 客户端（frpc）编译成 Android 可用的
**c-shared 库 `libfrpc.so`**，并打包成可热更的运行时分发包。

本仓库只负责**产出 `libfrpc.so`**：frp 作为 Go module 依赖，构建时自动拉取最新
release 并交叉编译各 ABI。配套的 native 加载器由宿主 App 自行内置，不在此仓库内。

主要用途：frp 发布新版本时，跑一下 `scripts/build.sh` 即可得到新的引擎包，
作为引擎独立下发/热更新，无需重新打包 App。

## 原理

- frpc 被编译成自包含的 c-shared 库 `libfrpc.so`，导出 `RunFrpc` / `StopFrpc`。
- 它放在 App 的**可写数据目录**里，由 App 内置的小加载器 `dlopen` 后调用。
- Android API 29+ 禁止从数据目录 `execve`，但仍允许 `dlopen` 其中的 `.so`，
  因此引擎可以放在数据目录、独立于 APK 热更新。

## 目录结构

```
frplib/frplib.go   frpc 的 c-shared 包装（//export RunFrpc / StopFrpc）
scripts/build.sh   自动构建脚本（拉取 frp@latest → 多 ABI 交叉编译 → 打包）
go.mod / go.sum    依赖（require frp + 镜像 frp 的 yamux replace）
dist/              构建产物（git 忽略）
```

## 构建

前置要求：

- Go 1.25+
- Android NDK（默认 `/d/AndroidSDK/ndk/28.2.13676358`，可用 `ANDROID_NDK_HOME` 覆盖）
- Windows 下用 **Git Bash** 运行（脚本会自动选用 NDK 的 `.cmd` 编译器包装）

```bash
# 全部 ABI（arm64-v8a / armeabi-v7a / x86_64），frp 最新 release
./scripts/build.sh

# 仅某个 ABI
./scripts/build.sh arm64-v8a

# 固定 frp 版本（可复现）
FRP_VERSION=v0.69.1 ./scripts/build.sh

# 不联网更新，用 go.mod 已锁定的版本
FRP_VERSION=keep ./scripts/build.sh
```

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `FRP_VERSION` | `latest` | frp 模块版本；`vX.Y.Z` 固定、`keep` 用 go.mod 现锁定值 |
| `ANDROID_NDK_HOME` | `/d/AndroidSDK/ndk/28.2.13676358` | NDK 路径 |
| `ANDROID_API` | `24` | 最低 API 级别 |

## 产物

```
dist/packages/bin_arm64.tgz     # 内含 lib/libfrpc.so + version
dist/packages/bin_arm.tgz
dist/packages/bin_x86_64.tgz
dist/packages/version           # 独立版本文件（= 所用 frp 版本）
dist/<abi>/libfrpc.so           # 各 ABI 的裸库（含 libfrpc.h）
```

`bin_<arch>.tgz` 内部布局：

```
lib/libfrpc.so
version
```

## 接入 App

把 `bin_<arch>.tgz` 与 `version` 放进 App 的运行时资源目录（例如
`assets/runtimes/frpc/`），由 App 在运行时解压到私有数据目录，再用其内置加载器
`dlopen` 解压出的 `lib/libfrpc.so` 并调用 `RunFrpc`。`version` 用于让 App 比对、
决定是否需要重新解压（即引擎热更）。

### C ABI（`libfrpc.so` 导出，供加载器调用）

```c
// 加载配置并运行 frpc，阻塞直到服务停止；0 表示正常退出，非 0 表示失败。
int  RunFrpc(const char *configPath);

// 优雅停止由 RunFrpc 启动的服务（也可直接向进程发 SIGINT/SIGTERM）。
void StopFrpc(void);
```

约定：加载器以独立子进程运行，`dlopen(libfrpc.so)` 后调用 `RunFrpc(configPath)`；
停止时向该进程发 `SIGTERM`，`libfrpc.so` 内部已监听并执行 graceful close。

## 关于 frp 依赖

- 通过 Go module 依赖 `github.com/fatedier/frp`，默认构建拉取 `@latest` release；
  仓库提交了一份锁定基线（`go.mod` / `go.sum`），`clone` 后即可复现构建。
- frp 自身用 `replace` 指向一个打了补丁的 yamux fork。被 `require` 模块的
  `replace` **不会**被继承，因此 `build.sh` 会在拉取 frp 后**自动从 frp 的 go.mod
  镜像其 `replace` 指令**到本项目，随 frp 演进保持正确。
- 编译使用 `-checklinkname=0`：frp 在 `GOOS=android` 下编入的 `wlynxg/anet`
  （Android 网卡适配库）用 `//go:linkname` 引用了 `net.zoneCache`，Go 1.23+ 默认
  拒绝，此标志放行。

## 许可

Apache License 2.0