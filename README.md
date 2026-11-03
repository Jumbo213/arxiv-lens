# Arxiv Lens

Arxiv Lens 是一个原生 macOS 论文翻译与阅读器。粘贴 arXiv 链接，应用会获取对应版本的 TeX 源码和 arXiv 发布的 PDF，通过你配置的模型将论文正文译成简体中文，再用本机 XeLaTeX 排版。历史按论文原始标题显示，可以按标题或 arXiv 编号搜索。

## 安装和使用

1. 在 [GitHub Releases](https://github.com/Jumbo213/arxiv-lens/releases) 下载 DMG。打开后将 **Arxiv Lens** 拖到 **Applications**。初版 DMG 为 Apple Silicon（arm64）构建，最低要求 macOS 13。
2. 安装 [MacTeX](https://www.tug.org/mactex/) 或 [TinyTeX](https://yihui.org/tinytex/)。需要 XeLaTeX、latexmk 和 xeCJK。精简的 TeX Live 可以使用 `tlmgr install xetex latexmk xecjk` 补齐，部分论文还需要额外宏包。
3. 打开「翻译与 TeX 设置」，填入 API URL、模型 ID、API Key，然后测试 API 和 TeX。TeX bin 留空时自动检测常见安装目录，也可以手动选择。
4. 粘贴链接或编号，例如 `https://arxiv.org/abs/1706.03762v7`，点击「开始翻译」。完成后可以并排对照、联动翻页、单独阅读或导出任一 PDF。

API 支持 OpenAI 兼容的 Chat Completions 协议。URL 可以是 `https://服务地址/v1`，也可以是完整的 `https://服务地址/v1/chat/completions`。本机服务可用 `http://127.0.0.1:端口/v1`，并可留空 Key。设置里可添加 `attention mechanism = 注意力机制` 形式的术语表。Key 存在 macOS 钥匙串。论文文本片段与术语表会发送给配置的翻译服务。

首版采用 ad-hoc 签名，尚未通过 Apple 公证。若 macOS 拦截首次启动，可在尝试打开后进入「系统设置 → 隐私与安全性」，对 Arxiv Lens 选择「仍要打开」。

## 译文排版

- 在原 TeX 项目上替换识别到的可译文本，保留文档类、作者、公式、图表文件、引用键、标签和参考文献。支持常见的多文件正文、标题、图表标题和行内格式。
- 对段内的 TeX 结构和数值使用受保护的占位符。模型改动占位符时会重试，仍失败的段落保留原文，阅读器显示保留段数。术语表和上文片段帮助保持术语一致。
- 中文换行、字宽和引擎差异会影响分页。对照模式优先按两份 PDF 的书签结构对齐，缺少匹配书签时按页数比例定位。图中的嵌字与部分自定义 TeX 宏参数保留源文件内容。
- 含特殊模板、自定义构建步骤或缺失宏包的论文可能无法直接编译。失败详情提供 XeLaTeX 日志。源码只提供 PDF 的论文无法通过此流程转换。
- 论文、译后 TeX、PDF 和编译日志位于 `~/Library/Application Support/ArxivLens/Papers/`。编译子进程限制写入任务的构建目录，禁用网络访问和 LaTeX shell escape。

## 构建与测试

使用 Xcode Command Line Tools（Swift 5.9 或更新版本）。

```sh
./scripts/test.sh
./scripts/build-dmg.sh
```

脚本默认构建当前架构的 DMG 与 SHA-256 文件到 `dist/`。可使用 `ARXIV_LENS_ARCH=x86_64` 构建 Intel 版本，并通过 `SIGN_IDENTITY` 指定 Developer ID。

可选的端到端测试会实际访问 arXiv，调用本机 TeX，并用测试服务模拟 Chat Completions。先启动 `python3 scripts/mock-api.py`，再运行以下命令。

```sh
ARXIV_LENS_TEST_ENDPOINT=http://127.0.0.1:8765/v1 \
  ARXIV_LENS_TEST_PAPERS=1706.03762,2103.00020v1 ./scripts/test.sh
```

## 参考

[kaixindelele/chinarxiv](https://github.com/kaixindelele/chinarxiv) 提供了源码获取、LaTeX 保护分段、模型翻译、回填与编译的工作流参考。Arxiv Lens 使用独立的 SwiftUI、PDFKit 和本机编译实现。
