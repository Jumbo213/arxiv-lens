# Arxiv Lens

Arxiv Lens 是一个原生 macOS 论文翻译与阅读器。粘贴 arXiv 链接，可以只保存原版 PDF，或下载对应版本的 TeX 源码、翻译成学术简体中文并用本机 XeLaTeX 排版。历史按论文原始标题显示，可以按标题或 arXiv 编号搜索。同一 arXiv 论文的译本合并显示，默认打开最新译本；可以从「文件 → 此文献的记录」切换。

## 安装和使用

1. 在 [GitHub Releases](https://github.com/Jumbo213/arxiv-lens/releases) 下载 DMG。打开后将 **Arxiv Lens** 拖到 **Applications**。初版 DMG 为 Apple Silicon（arm64）构建，最低要求 macOS 13。
2. 安装 [MacTeX](https://www.tug.org/mactex/) 或 [TinyTeX](https://yihui.org/tinytex/)。需要 XeLaTeX、latexmk、xeCJK、etoolbox 和 setspace。精简的 TeX Live 可以使用 `tlmgr install xetex latexmk xecjk etoolbox setspace` 补齐，部分论文还需要额外宏包。
3. 打开「翻译与 TeX 设置」，在 API URL 旁可用「服务商预设」切换 DeepSeek、OpenAI、Gemini 等地址，也可以填写自己的 Base URL。点「新增 Key」添加主 Key 和备用 Key，再选择模型或输入模型 ID。保存后，每个 API 地址会记住自己的 Key 和模型。请求遇到余额不足或限流时，应用会按顺序尝试同一地址下的备用 Key，本次任务继续使用成功的 Key。TeX bin 留空时自动检测常见安装目录，也可以手动选择。
4. 粘贴链接或编号，例如 `https://arxiv.org/abs/1706.03762v7`，可选「仅下载」保存原版 PDF，或点「下载并翻译」生成中文版。原版 PDF 下载后会先加入左侧文献库，后续翻译或编译失败时，可以打开原文并从「翻译这篇论文」重试。仅下载无需配置 API 或安装 TeX。完成翻译后可以并排对照、联动翻页、单独阅读或导出任一 PDF。默认收起标题和地址栏，点击「展开顶部」可显示。

API 支持 OpenAI 兼容的 Chat Completions 协议。URL 可以是 `https://服务地址/v1`，也可以是完整的 `https://服务地址/v1/chat/completions`。本机服务可用 `http://127.0.0.1:端口/v1`，并可留空 Key。内置术语表覆盖机器学习、大模型、后训练和神经符号，按当前段落匹配。设置中可以浏览词表，也可添加 `attention mechanism = 注意力机制` 格式的自定义词条来覆盖内置译法。Key 存在 macOS 钥匙串。论文文本片段与术语表会发送给配置的翻译服务。

首版采用 ad-hoc 签名，尚未通过 Apple 公证。若 macOS 拦截首次启动，可在尝试打开后进入「系统设置 → 隐私与安全性」，对 Arxiv Lens 选择「仍要打开」。

## 文献分类与检索

- 左侧可按时间、标题首字母、主题或类型分组。同一篇论文的不同版本和译本共用分类。
- 通过「整理 → AI 分类未整理文献」整理已有记录。API 根据标题、摘要和公开出版信息建议主题、关键词及会议、期刊、综述等类型。「整理」菜单可关闭新入库文献的自动分类。
- 左侧「类型」视图会在论文旁显示有公开依据的会议或期刊及年份。用「整理 → 刷新缺少发表信息的文献」检查最新 arXiv 记录，存在正式出版 DOI 时会核对 Crossref。已有会议或期刊名称的文献会跳过。也可以右键刷新单篇待补全论文。
- 右键文献可编辑主题、关键词、类型、会议或期刊名称及年份，或重新翻译。也可从阅读器的「文件」菜单重新翻译当前版本，新旧译本都可从同一条记录中打开。
- 在「自然语言」模式输入问题并按回车，例如「找出讨论可验证奖励与后训练的论文」。API 使用查询和库内的标题、摘要、标签等元数据返回相关记录和匹配依据。常规关键词查找在本机完成。
- 分类保存在本机的 `catalog.json`。自动分类和自然语言检索调用「翻译与 TeX 设置」配置的 API。

## 译文排版

- 在原 TeX 项目上替换识别到的可译文本，保留文档类、作者、公式、图表文件、引用键、标签和参考文献。支持常见的多文件正文、标题、图表标题和行内格式。
- 对段内的 TeX 结构和数值使用受保护的占位符。模型改动占位符时会重试，仍失败的段落保留原文，阅读器显示保留段数。术语表和上文片段帮助保持术语一致。
- 摘要按句翻译。中文版默认使用舒展行距，也可在设置中选择贴近原稿或宽松行距。更改行距后重新生成 PDF 即可生效。中文换行、字宽和行距会影响分页。对照模式优先按两份 PDF 的书签结构对齐，缺少匹配书签时按页数比例定位。图中的嵌字与部分自定义 TeX 宏参数保留源文件内容。
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
