# CiteStudio

**[English](README.md)** | **简体中文**

**面向 LaTeX 与 Typst 的引文核查、撤稿筛查与学术行文体检工具（macOS 原生 Swift 6 + Crossref + OpenAlex + MCP）**

> **版本与能力边界说明（请先阅读）**
> - **已发布 `v0.2.0`（`main`）与未发布改动（`main / v0.2.0 之后`）**：已发布的 `v0.2.0` 包含 `--cli status`、`--cli lint`、`--cli compile`、`--mcp` 与 `--lang en|zh`。下文中标注 **未发布（`main` / `v0.2.0` 之后）** 的入口与行为——包括 `--cli verify`、`--cli clear-cache`、`--cli help` / `--help`、`--cache-dir`、`--demo`、默认空白桌面工作区，以及 `Unverified`（未验证）与 `GhostPaper`（确认不存在）的三态分离——位于 `main` 之后的开发分支，尚未打标签发布。
> - **真实用户文件请通过 CLI 与 MCP 处理**：支持命令行核验 `.bib` 参考文献（`--cli verify`，未发布 / `main` 之后）、清理本地核验缓存（`--cli clear-cache`，未发布 / `main` 之后）、检查 `.tex`/`.typ` 行文与图表引用（`--cli lint`）、调用外部编译器生成 PDF（`--cli compile`），以及通过 stdio MCP 服务（`--mcp`）拦截未通过核验的参考文献写入。
> - **桌面 GUI 当前限制**：不带 `--demo` 启动 `CiteStudio` 桌面窗口时（未发布 / `main` 之后；已发布的 `v0.2.0` 启动即载入内置示例），默认进入干净的**空白工作区**（`0` 字文稿、`0` 条参考文献、`0` 条诊断）。桌面端打开本地任意项目文件夹、编辑器与 PDF 之间的 SyncTeX 双向点击跳转、以及桌面端自动扫描 `pdfs/` 并在 PDF 预览中高亮证据坐标框均属于**计划中、当前尚未实现**的功能（详见文末[计划中（当前未实现）](#计划中当前未实现)）。如需查看界面排版，请点击工具栏 **“载入演示”** 按钮或传入 `--demo` 查看带 **`[DEMO · 演示数据]`** 标识的内置示例。

---

## 界面预览（`[DEMO · 演示数据]` 内置示例工作区）

> **截图说明（`[DEMO · 演示数据]`）**：以下截图均由 `CiteStudio --demo`（`--export-screenshots`）基于内置示例文稿与示例 `.bib` 渲染，顶部带有醒目的 **`[DEMO]` / `[DEMO · 演示数据]`** 标识，并非打开用户真实项目目录后的界面。

### 简体中文界面 (`--lang zh` · `[DEMO · 演示数据]`)

| 三栏示例工作区（`[DEMO · 演示数据]`） | 引文防火墙与行文体检抽屉（`[DEMO · 演示数据]`） |
| :---: | :---: |
| ![CiteStudio 中文主工作区（演示数据）](docs/screenshot-main-zh.png) | ![CiteStudio 中文引文防火墙与写作体检（演示数据）](docs/screenshot-firewall-zh.png) |
| *`[DEMO · 演示数据]` 内置示例工作区（通过“载入演示”或 `--demo` 载入）。* | *`[DEMO · 演示数据]` 示例文献核验卡片与确定性去 AI 套话体检结果。* |

### 英文界面 (`--lang en` · `[DEMO]`)

| Three-Pane `[DEMO]` Sample Preview | Citation Firewall & Prose Lint Drawer (`[DEMO]`) |
| :---: | :---: |
| ![CiteStudio Main Workspace (DEMO)](docs/screenshot-main.png) | ![CiteStudio Citation Firewall Drawer (DEMO)](docs/screenshot-firewall.png) |
| *`[DEMO]` Built-in sample workspace (`Load Demo` / `--demo`).* | *`[DEMO]` Sample citation statuses and deterministic prose lint cards.* |

---

## 功能说明（除注明 `v0.2.0` 外均为未发布 / `main` 之后）

### 1. 引文核查与三态查询结果分离（`ScholarTriangulator` — 未发布，`main` 之后）
通过 `URLSession` 查询 **Crossref** 与 **OpenAlex** 文献元数据，并将上游查询结果拆分为三种状态：

1. **已命中记录（`Verified` / `PreprintUpgrade` / `MetadataMismatch` / `Retracted`）**：
   - **DOI 元数据一致性比对**：按 DOI 取回记录（若 Crossref 返回 HTTP `404`，例如 DataCite 注册的 arXiv `10.48550/...` DOI，会继续查询 OpenAlex），并核对**归一化标题相似度**（Jaccard 词项重合度 `>= 0.60`）、**去除 LaTeX 重音符号后的第一作者姓氏**与**发表年份**（`|Δyear| <= 1`）。真实 DOI 若配上了错误标题、错误作者或错误年份，会被判定为 **`MetadataMismatch`（元数据不符）**。
   - **撤稿识别（`Retracted`）**：检查 Crossref `update-to` 与 `updated-by` 中 `type` 或 `label` 含 `retract` 或 `withdraw` 的记录、Crossref `relation.is-retracted-by`、标题 `"RETRACTED:"` / `"WITHDRAWN:"` 前缀，以及 OpenAlex `is_retracted == true`。
   - **预印本转正提示（`PreprintUpgrade`）**：当文稿引用 `arXiv` / `bioRxiv` / `medRxiv` 预印本且上游检出同行评审正式版时，给出正式版 BibTeX 替换建议。
2. **确认不存在 / 库中未查到（`GhostPaper`）**：
   - **仅当** Crossref 与 OpenAlex 对所查 DOI **均**明确返回 HTTP `404`（未找到），或在无 DOI 条目的前 3 条标题检索均正常返回 HTTP `200` 且没有任何候选同时满足标题归一化相似度（`>= 0.78`）、发表年份差（`|Δyear| <= 1`）、第一作者姓氏一致及非书评类型（`book-review`）时（`C5`），才归入 **`GhostPaper`（`NOT FOUND`）**。对无 DOI 条目，诊断标题明确标注为“未在 Crossref / OpenAlex 中查到匹配记录”，不宣称文献系编造。
3. **查询失败 / 未验证（`Unverified` / `未验证`）**：
   - 断网、DNS/连接拒绝、请求超时、HTTP `429` 限流、HTTP `5xx` 服务端故障或响应解析失败——包括其中一方返回 `404` 而另一方查询失败的情形——一律返回 **`Unverified`（未验证）**。
   - **`Unverified`（未验证）不写入本地 SQLite 缓存**，也不会归入 `GhostPaper`。网络恢复后再次运行会立即重新请求上游。
   - SQLite 缓存条目带有明确的过期时间（TTL）：命中记录默认缓存 `7 天`，确认不存在记录默认采用更短的 `24 小时` TTL；读取时自动剔除过期缓存，也可执行 `--cli clear-cache` 手动清空。

> **当前已知局限**：
> - **早期无 DOI 专著未被收录**：Crossref 与 OpenAlex 主要收录期刊与会议论文，对早期无 DOI 专著、学位论文及技术报告覆盖有限。对于 Knuth 1968 *The Art of Computer Programming* 这类在上游检索结果中仅出现他人书评（如 `Odeh` 1969、`MacLaren` 1969、`Wells` 1973）的无 DOI 专著，`C5` 候选过滤会排除作者/年份/书评类型不符的条目并返回“未在 Crossref / OpenAlex 中查到匹配记录”（`GhostPaper` / `NOT FOUND`，不再误报 `MetadataMismatch`），在接入 Open Library 等图书源前不会自动放行。
> - **未标为 `book-review` 的书评在写成书评作者时会被当成原书放行**：不少期刊书评在 OpenAlex 中类型为普通 `article`（Crossref 中为 `journal-article`）且标题不带 `"Book Review:"` 前缀（例如 *Journal of the American Statistical Association* 1969 年 Robert E. Odeh 对 *The Art of Computer Programming* 的书评，OpenAlex `"type"` 为 `"article"`）。仅靠类型与标题前缀无法拦截这类记录：若输入引文恰好将作者写成书评人（如 `Odeh`）且年份差在 `±1` 以内，该书评会被当成原书判为 `Verified`。为此，产品在命令行、JSON（`matchedVenue` / `matchedWorkType`）、MCP 与界面诊断中均显式列出命中记录的刊物与上游类型（缺失时显示“未知”）。

### 2. MCP 权威元数据写入门禁（`CiteStudio --mcp`）
通过标准输入/输出（`stdio`）运行 JSON-RPC 2.0 MCP 服务，提供 6 个工具：

| MCP 工具 | 实际行为与当前限制 |
| :--- | :--- |
| `verify_citation` | 对单条 BibTeX 引用执行核验，返回结构化 JSON 诊断结果（`Verified`、`PreprintUpgrade`、`MetadataMismatch`、`Retracted`、`GhostPaper`、`Unverified`；其中 `Unverified` 分离为未发布 / `main` 之后）。 |
| `add_verified_bibtex` | 写入 `.bib` 前先执行引文核验。遇到 `GhostPaper`、`MetadataMismatch`、`Retracted` 或 `Unverified` 时直接返回 `ERR_UNVERIFIED_CITATION` 并保持目标 `.bib` 不变；当结果为 `Verified` 或 `PreprintUpgrade` 时，**使用上游权威记录的 `title`、`author`、`year`、`journal`/`booktitle`、`doi` 生成规范 BibTeX 条目**（未发布 / `main` 之后），并对已存在的 `citeKey` 去重（`SKIPPED_DUPLICATE_KEY`）。 |
| `search_local_pdfs` | 基于 SQLite FTS5 BM25 查询 `pdf_fts5.sqlite`。**当前限制**：`--cli` 与 `--mcp` 目前均未提供建立 PDF 索引的命令或工具入口，除非已通过库接口调用 `LocalPDFIndexer.indexPDF` 写入数据，否则新工作区下始终返回空结果。 |
| `get_claim_evidence` | 基于关键词 BM25 在 `pdf_fts5.sqlite` 中检索相近文本块（不核对数字与否定语气）。**当前限制**：返回的 `rect` 只是按 `\n\n` 粗切分的页面/大文本块级 `PDFKit` 范围（选区失败时回退到固定默认矩形），并非逐行或逐句精确定位框；且当前同样没有 CLI/MCP 建索引入口。 |
| `audit_manuscript` | 对传入的 LaTeX / Typst 文本执行确定性去 AI 套话与图表引用检查（`WritingQualityLinter`）。 |
| `compile_pdf` | 调用本机安装的 `tectonic --synctex` 或 `typst compile` 编译指定 `.tex` / `.typ` 文件（文件不存在时返回 `ERR_FILE_NOT_FOUND`，未发布 / `main` 之后；未安装编译器或编译失败时返回诊断信息）。 |

### 3. 确定性学术行文与图表规范体检（`WritingQualityLinter` — `v0.2.0` 已含）
纯本地正则与行级扫描，不调用大模型：
- **英文 AI 高频套话检测（`anti-ai-vocab`）**：标记 *delve into*、*pivotal role*、*tapestry*、*underscore*、*it is worth noting that*、*comprehensive overview* 等空泛套话。
- **破折号密度检查（`polish-emdash-density`）**：提示单段过多使用 `---` / `—` 插入语。
- **未引用图表检测（`polish-uncited-float`）**：检查定义了 `\label{fig:...}` 或 `\label{tab:...}` 却从未在正文中通过 `\ref` / `\autoref` / `\cref` 引用的悬浮体。
- **未定义缩略语检查（`polish-undefined-acronym`）**：标记首次出现前未给出全称的大写缩略语（排除 `CPU`、`GPU`、`LLM`、`PDF`、`API`、`DOI`、`URL`、`SQL` 等通用词）。

---

## 快速开始与命令行用法

### 环境要求
- **macOS 14.0+**（Apple Silicon `arm64`）
- **Swift 6.0+**（Xcode 16+ 或 Command Line Tools，用于源码构建）
- 可选外部排版编译器（供 `--cli compile` 调用）：`brew install tectonic typst`

### 构建与测试
```bash
git clone https://github.com/zxu756/CiteStudio.git
cd CiteStudio

# 编译调试版可执行文件
swift build

# 运行 M0 里程碑单元测试与验收脚本（纯本地闭环，零外部网络请求）
./Scripts/test.sh milestone 0
```

### CLI 命令行工具（`--cli`）
所有 `--cli` 子命令与 MCP 服务共用同一套核验与体检引擎，并支持 `--lang zh` / `--lang en`（及 `--cache-dir <目录>`，未发布 / `main` 之后）：

```bash
# 1. 查看本机外部编译器路径状态（v0.2.0 已含）
.build/debug/CiteStudio --cli status

# 2. 逐条核验 .bib 文件中的全部参考文献（未发布，main / v0.2.0 之后）
#    仅当全部条目严格为 Verified 时退出码为 0；
#    只要存在任何非 Verified 条目（含 PreprintUpgrade、GhostPaper、MetadataMismatch、Retracted 或 Unverified），退出码均为 1。
.build/debug/CiteStudio --cli verify path/to/references.bib
.build/debug/CiteStudio --cli verify path/to/references.bib --json
.build/debug/CiteStudio --cli verify path/to/references.bib --lang zh

# 3. 清空本地 SQLite 引文核验缓存（未发布，main / v0.2.0 之后）
.build/debug/CiteStudio --cli clear-cache
.build/debug/CiteStudio --cli clear-cache --lang zh

# 4. 对 .tex 或 .typ 文稿运行确定性行文与图表体检（v0.2.0 已含；缺失文件退出码 2 为未发布 / main 之后）
.build/debug/CiteStudio --cli lint path/to/main.tex
.build/debug/CiteStudio --cli lint path/to/main.tex --lang zh

# 5. 调用 Tectonic 或 Typst 编译 .tex / .typ 文件（v0.2.0 已含）
.build/debug/CiteStudio --cli compile path/to/main.tex

# 6. 查询 stdio MCP 服务器工具列表（v0.2.0 已含）
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | .build/debug/CiteStudio --mcp

# 7. 启动桌面窗口（默认空白工作区为未发布 / main 之后；加 --demo 载入演示数据）
.build/debug/CiteStudio
.build/debug/CiteStudio --demo --lang zh
```

### 环境变量说明（未发布，`main` / `v0.2.0` 之后）
| 环境变量 | 作用 |
| :--- | :--- |
| `CITESTUDIO_CACHE_DIR` | 指定 `scholar_cache.sqlite` 与 `pdf_fts5.sqlite` 的存放目录（也可通过 `--cache-dir <路径>` 传入）。 |
| `CITESTUDIO_CROSSREF_BASE_URL` | 覆盖 Crossref API 基础地址（默认 `https://api.crossref.org`；供本地录制样本回放使用）。 |
| `CITESTUDIO_OPENALEX_BASE_URL` | 覆盖 OpenAlex API 基础地址（默认 `https://api.openalex.org`；供本地录制样本回放使用）。 |
| `CITESTUDIO_HTTP_TIMEOUT` | 单次 HTTP 请求超时秒数（默认 `8` 秒，即 `8.0` 秒）。 |
| `CITESTUDIO_REAL_TECTONIC` | 设为 `1` 时启用真实 `tectonic` 编译测试（默认跳过，避免空 `HOME` 或离线环境下因下载 TeX 宏包挂起）。 |
| `CITESTUDIO_RECORD` | 设为 `1`（须经用户明确同意）后运行 `./Scripts/acceptance/record-fixtures.sh`，将 Crossref / OpenAlex 原始响应录制到 `Tests/Fixtures/recorded/`。 |

---

## 计划中（当前未实现）

以下能力**不包含在当前 M0 版本中**，请勿将其视为现有功能：

- **桌面 GUI 打开与编辑本地项目目录（`M3`）**：通过菜单打开任意 `.tex` / `.typ` / `.bib` 文件夹、保存修改回磁盘及 `FSEvents` 文件变更自动刷新。
- **桌面 GUI 编辑器与 PDF 双向 SyncTeX 跳转（`M3`）**：在编辑器点击代码行跳转到 PDF 对应位置，或按住 `⌘` 点击 PDF 跳回源码行（当前 `SyncTeXMapper` 仅作为底层解析库存在，尚未接入界面交互）。
- **CLI/MCP PDF 建索引入口与句子级证据核验（`M2` / `M3`）**：在命令行与 MCP 提供 `pdfs/*.pdf` 建索引入口，按句子粒度切分并精确定位坐标框、核对数字与否定词一致性，以及在桌面 PDF 面板绘制高亮框。
- **共用 460 条评测集回放与无 DOI 专著图书源回退（`M1` / `M2`）**：在 ScholarOS 共用 460 条评测集（待评测集建成）上执行离线回放评测，并接入 Open Library 等专著数据源以降低早期无 DOI 书籍的未命中率。

---

## 开源许可

本项目基于 [MIT License](LICENSE) 开源发布。
