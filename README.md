# EdgeCubePackage-Frpc

把 [frp](https://github.com/fatedier/frp) 客户端 frpc 编译成 Android 可用的
`c-shared` 库 `libfrpc.so`，并打包成 EdgeCube 可导入的 `.ecpkg`
运行时包。

本仓库只负责产出 frpc 运行时包。配套的 native 加载器
`libfrpcloader.so` 由宿主 EdgeCube APK 内置；App 导入 `.ecpkg` 后，
运行时会被安装到私有数据目录，并由加载器 `dlopen` 其中的
`lib/libfrpc.so`。

## 原理

- frpc 被编译成自包含的 `c-shared` 库 `libfrpc.so`，导出
  `RunFrpc` / `StopFrpc`。
- `.ecpkg` 是 ZIP 容器，根目录包含 `edgecube-package.json`，各架构文件
  位于 `arm64/`、`arm/`、`x86_64/` 等目录。
- EdgeCube 导入包时会读取清单，提取当前设备架构目录到
  `filesDir/runtimes/<id>/`，并写入安装完成标记 `version`。
- Android API 29+ 禁止从数据目录直接 `execve`，但允许 `dlopen` 其中的
  `.so`，所以 frpc 引擎可以独立于 APK 热更新。

## 目录结构

```text
frplib/frplib.go   frpc 的 c-shared 包装，导出 RunFrpc / StopFrpc
scripts/build.sh   自动构建脚本：解析 frp 版本、交叉编译、生成 .ecpkg
go.mod / go.sum    Go 依赖
dist/              构建产物，已被 git 忽略
```

## 构建

前置要求：

- Go 1.25+
- Android NDK，默认路径为 `/d/AndroidSDK/ndk/28.2.13676358`
- Windows 下请使用 Git Bash 运行
- `zip` 命令，或可用的 `python3` / `python` 作为 ZIP 打包后备

```bash
# 全部支持的 ABI：arm64-v8a / armeabi-v7a / x86_64
./scripts/build.sh

# 仅构建某个 ABI
./scripts/build.sh arm64-v8a

# 固定 frp 版本，便于复现
FRP_VERSION=v0.69.1 ./scripts/build.sh

# 不联网更新，使用 go.mod 已锁定的版本
FRP_VERSION=keep ./scripts/build.sh
```

环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FRP_VERSION` | `latest` | frp 模块版本，`vX.Y.Z` 固定，`keep` 使用 go.mod 当前版本 |
| `ANDROID_NDK_HOME` | `/d/AndroidSDK/ndk/28.2.13676358` | NDK 路径 |
| `ANDROID_API` | `24` | 最低 Android API |
| `ECPKG_ID` | `frpc` | 运行时 id，会作为 EdgeCube 的安装目录名 |
| `ECPKG_NAME` | `FRP Client` | 运行时显示名称 |
| `ECPKG_AUTHOR` | `EdgeCube` | 包作者 |
| `ECPKG_MIN_APP_VERSION` | `6` | 最低 EdgeCube `versionCode` |

## 产物

```text
dist/packages/frpc-arm64.ecpkg
dist/packages/frpc-arm.ecpkg
dist/packages/frpc-x86_64.ecpkg
dist/packages/frpc-multi.ecpkg
dist/<abi>/libfrpc.so
dist/<abi>/libfrpc.h
```

单架构包内部布局：

```text
edgecube-package.json
arm64/
  lib/
    libfrpc.so
```

多架构包内部布局：

```text
edgecube-package.json
arm64/lib/libfrpc.so
arm/lib/libfrpc.so
x86_64/lib/libfrpc.so
```

`edgecube-package.json` 使用 `type: "frpc"`，启动器配置为：

```json
{
  "launcher": {
    "type": "frpc",
    "lib": "lib/libfrpc.so"
  }
}
```

当前包清单不写入 `updateUrl`，因为 EdgeCube 的运行时更新功能尚未实现。

## 接入 App

在 EdgeCube 的“运行环境”页面导入任意 `.ecpkg` 包即可。App 会按设备架构
提取对应目录，安装后目录形态为：

```text
filesDir/runtimes/frpc/
  edgecube-package.json
  version
  lib/
    libfrpc.so
```

隧道启动时，EdgeCube 会执行 APK 内置的 `libfrpcloader.so`，并通过环境变量
`EC_FRPC_LIB` 指向已安装的 `lib/libfrpc.so`。

## C ABI

```c
// 加载配置并运行 frpc，阻塞直到服务停止；0 表示正常退出，非 0 表示失败。
int RunFrpc(const char *configPath);

// 优雅停止由 RunFrpc 启动的服务。
void StopFrpc(void);
```

停止时宿主进程会向加载器子进程发送 `SIGTERM`，`libfrpc.so` 内部监听信号并
执行 graceful close。

## 关于 frp 依赖

- 默认通过 Go module 拉取 `github.com/fatedier/frp@latest`。
- 被 `require` 的模块不会继承其 `replace` 指令，因此 `build.sh` 会读取 frp
  自身的 `go.mod`，并把其中的单行 `replace` 镜像到本项目。
- 构建使用 `-checklinkname=0`，以兼容 frp 在 Android 下依赖的网络适配代码。

## 许可

Apache License 2.0
