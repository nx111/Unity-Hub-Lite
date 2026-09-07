# Unity Hub Lite

## Unity Hub Lite（Tauri 桌面版）

仓库同时包含一个轻量的 Unity Hub Lite 桌面安装器。它从 Unity 发布接口读取 Windows x86_64 Editor 版本和组件树，支持组件选择、断点续传、完整性校验，以及复用本地缓存的离线安装。

```powershell
npm install
npm run tauri dev
```

发布安装包：

```powershell
npm run tauri build
```

生成免安装 portable 压缩包（需先完成构建）：

```powershell
npm run portable
```

如果 Tauri CLI 报 `called Option::unwrap() on a None value`，通常是 Rust 工具链未完成安装。项目脚本会先检查工具链并给出具体错误；修复后重试：

```powershell
rustup toolchain install stable --profile minimal
npm run tauri build
```

缓存按 `缓存目录/<Unity版本>/` 保存，未完成的下载保留为 `.part` 文件。勾选“仅使用本地缓存（离线安装）”后不会访问网络；Editor 元数据也会从同一目录的 `release.json` 回退读取。

## 用途

脚本用于准备并安装 Windows 版 Unity 离线安装包。默认以脚本所在目录作为包目录：

```text
E:\Games\Unity\
```

使用 `-Version`（别名 `-DownloadVersion`）时，脚本会从 Unity 发布接口读取指定版本，检查包目录中是否已有目标文件；缺失或文件大小不符的文件会重新下载到该目录。

## 前置条件

- Windows PowerShell 5.1 或 PowerShell 7。
- 下载模式需要网络访问 Unity 下载地址和发布接口。
- 安装模式需要管理员权限或目标目录的写入权限。
- Unity 安装目录应包含 `Editor\Unity.exe`。未显式传入 `-EditorRoot` 时，脚本会优先读取注册表中的 Unity 安装路径。

## 最常用的命令

### 只下载离线包

```powershell
Set-Location E:\Games\Unity
.\Install-Unity-Offline.ps1 -Version 6000.3.21f1 -DownloadOnly
```

默认下载：

- Unity Editor
- Android Build Support
- Android SDK/NDK、JDK 及其工具包
- Linux Build Support (IL2CPP)
- Windows Build Support (IL2CPP)

Unity 6 的 Windows Mono 通常已经包含在 Editor 中，不一定存在独立的 Windows Mono 安装包；脚本遇到这种版本会给出提示。

### 查看下载或安装计划

```powershell
.\Install-Unity-Offline.ps1 -Version 6000.3.21f1 -ListOnly
```

`-ListOnly` 只显示文件状态，不会下载或安装。

### 下载后继续安装

省略 `-DownloadOnly` 即会在文件准备完成后继续安装：

```powershell
.\Install-Unity-Offline.ps1 -Version 6000.3.21f1
```

如果 Editor 尚未安装，脚本会启动 Editor 安装程序，并等待安装路径写入注册表；模块随后安装到同一 Unity 根目录。

### 只给已有 Editor 安装模块

```powershell
.\Install-Unity-Offline.ps1 `
    -Version 6000.3.21f1 `
    -SkipEditor `
    -EditorRoot 'D:\Unity\6000.3.21f1'
```

`-EditorRoot` 必须指向包含 `Editor\Unity.exe` 的 Unity 根目录。

## 参数

| 参数 | 说明 |
| --- | --- |
| `-Version` | 指定 Unity 版本并启用按版本检查、补齐下载。可用别名 `-DownloadVersion`。例如 `6000.3.21f1`。 |
| `-DownloadOnly` | 只下载并校验文件，不执行安装。通常与 `-Version` 一起使用。 |
| `-EditorRoot` | 已安装 Unity 的根目录，目录中必须有 `Editor\Unity.exe`。 |
| `-SetupExe` | 指定本地 Editor 安装程序。未指定时，脚本会在包目录寻找最新的 `UnitySetup64-*.exe`。 |
| `-Modules` | 指定要安装的模块 ID。传入后只处理列出的 ID；不传入时，版本下载模式使用默认组件，传统本地模式只安装目录中已有的模块。 |
| `-SkipEditor` | 跳过 Editor 下载和安装，只处理模块。需要已有 Editor 根目录。 |
| `-ListOnly` | 只显示计划，不下载、不安装。 |
| `-ConfigJson` | 使用指定的发布配置 JSON，通常不需要传入。 |

## 模块 ID

常用 ID 如下：

```text
android
android-open-jdk-17.0.18+8
android-sdk-ndk-tools
android-ndk-r27c
cmake-3.22.1
android-sdk-build-tools-36.0.0
android-sdk-platform-tools-36.0.0
android-sdk-platforms-34
android-sdk-platforms-35
android-sdk-platforms-36
android-sdk-command-line-tools-16.0
linux-il2cpp
windows-il2cpp
```

例如，只安装本地已有的 Linux IL2CPP 和 Windows IL2CPP：

```powershell
.\Install-Unity-Offline.ps1 `
    -SetupExe '.\UnitySetup64-6000.3.21f1.exe' `
    -EditorRoot 'D:\Unity\6000.3.21f1' `
    -Modules linux-il2cpp,windows-il2cpp
```

## 目录与缓存

- 所有下载文件保存到脚本所在目录，不是 PowerShell 当前工作目录。
- 发布配置缓存文件名为 `unity-release-<version>-windows-x86_64.json`。
- 下载过程中使用 `<文件名>.download` 临时文件；下载完成并通过大小校验后才替换目标文件。
- 已存在且大小正确的文件会直接复用；大小不符的文件会重新下载。

## 常见问题

### 找不到 Editor 安装路径

使用 `-EditorRoot` 指定包含 `Editor\Unity.exe` 的目录，或先完成 Editor 安装后再执行模块安装。

### 选中的模块提示本地文件缺失

传统本地模式不会自动下载模块。需要按版本下载时使用 `-Version <版本>`；也可以先执行：

```powershell
.\Install-Unity-Offline.ps1 -Version 6000.3.21f1 -DownloadOnly
```

### 下载中断

重新执行相同命令即可。脚本会重新检查文件大小，只补齐缺失或不完整的文件。
