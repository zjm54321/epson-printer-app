# Epson LQ-1600KIII 针式打印机应用容器

本项目基于 [OpenPrinting Ghostscript Printer Application](https://github.com/OpenPrinting/ghostscript-printer-app) 与 Ubuntu 24.04 (linux/amd64)，用于将连接在 Linux 主机上的爱普生 Epson LQ-1600KIII（非 H 型）24 针点阵打印机接入局域网。打印机通过 USB 转并口适配器（识别为 `USB2.0-Print`，VID/PID `1a86:7584`）连接，由 Linux 服务端将文档转换为针打控制指令，局域网内的 Windows PC 与 Android 手机均已确认可直接进行标准 IPP 打印。

集群部署与 GitOps 清单由独立仓库管理：[homelab-gitops](https://github.com/zjm54321/homelab-gitops)（位于 `home-services` 命名空间）。

## 功能与打印配置

- **服务名称与型号**：mDNS / DNS-SD 广播名称为 `Epson LQ-1600KIII`，设备型号为 `Epson LQ-1600KIII`，IEEE-1284 设备 ID 回退为 `MFG:EPSON;MDL:LQ-1600KIII;CMD:ESCP24K,PRPXL24,BDC;CLS:PRINTER;`。硬件序列号依用户要求保持未填。
- **访问端点**：
  - 公共 IPP 打印端点：`ipp://<IP>:8000/ipp/print/epson_lq-1600kiii`
  - 内置 Web 状态界面：`http://<IP>:8000/epson_lq-1600kiii/`
  - 内部管理队列名：`epson-lq1600kiii-epson`（保持持久化状态与任务历史连续）
- **打印选项默认值**：
  - 页面介质：A4（`iso_a4_210x297mm`，自动纸源）
  - 打印质量：正常（`normal` / 180×180 dpi）
  - 颜色模式：单色灰度（`print-color-mode monochrome`）
  - 标称速率：4 页/分钟（基于用户提供的 300 cps @ 10 cpi 参考值 × 60 / (A4 页面 75 字 × 60 行) 换算约为 4 ppm；纯文本估算值，非栅格性能测算）
- **客户端兼容分辨率映射**：
  针对 Windows IPP 栈过滤非对称 DPI 的特性，服务端暴露 4 档标准方点分辨率，后端由 Ghostscript `epson` 驱动透明映射至打印机物理针打精度：

| 客户端显示选项 | 服务端 Ghostscript 实际渲染 | 对应质量级别 |
|---|---|---|
| **60 × 60 dpi** | 60 × 60 dpi | 草稿（Draft） |
| **120 × 120 dpi** | 120 × 72 dpi | 手动选择 |
| **180 × 180 dpi** | 180 × 180 dpi（默认） | 正常（Normal） |
| **360 × 360 dpi** | 360 × 216 dpi | 高质量（High） |

> **说明**：客户端界面方点仅用于逻辑协商，映射至 Ghostscript 实际输出分辨率，并不代表打印机硬件支持 360×360 点阵或各项硬件模式已全量实测。客户端原生选项支持单面打印、标准纸型选择、页面方向、打印份数、逆序输出与缩放；特殊功能（机载字库切换、单/双向机械控制、硬件半色调、N-up 或连续走纸微调）不在此范围。

## 安全与运行边界

- **非特权用户与权限剥离**：镜像默认以非 root 用户 `584792:584792` 运行，内部剥离 SUID/SGID 与文件特权能力，CUPS USB 后端固定为 `0755` 权限。
- **部署环境加固**：通过 Kubernetes/容器编排强制配置 `no-new-privileges`、`cap-drop: ALL` 及只读根文件系统（`readOnlyRootFilesystem: true`）。
- **存储持久化**：挂载持久卷至 `/state` 保留队列状态与未完成任务；容器重启或更新绝不会自动提交测试打印任务，仅恢复既有未完成作业。
- **局域网安全界限**：服务监听受信任局域网（使用 hostNetwork 配合 Avahi 广播），严禁通过路由器端口映射暴露至公网。
- **开源许可证与源码**：项目打包组件及许可证声明见 [THIRD_PARTY.md](THIRD_PARTY.md)。发布镜像包含对应的 `epson-printer-app-sources` 源码包。

## 镜像构建与发布

本项目通过 GitHub Actions 自动化构建并发布容器镜像至 GitHub Packages (GHCR)：

1. **运行时镜像**：`ghcr.io/zjm54321/epson-printer-app`
2. **发现广播镜像**：`ghcr.io/zjm54321/epson-printer-discovery`
3. **源码伴随镜像**：`ghcr.io/zjm54321/epson-printer-app-sources`

本地使用 Docker 构建：
```bash
# 构建运行时镜像
docker build --platform linux/amd64 --target runtime -t epson-printer-app:latest .

# 构建广播发现镜像
docker build --platform linux/amd64 --target discovery -t epson-printer-discovery:latest .

# 构建对应源码归档镜像
docker build --platform linux/amd64 --target sources -t epson-printer-app-sources:latest .
```
