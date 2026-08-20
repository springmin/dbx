# DBX 移植到 OpenHarmony(OHOS)技术文档

> 版本:2026-08-20 | 基于 dbx v0.5.88 (t8y2/dbx) 源码
> 产物:OHOS 原生运行的 DBX Web 版(数据库管理工具,支持 80+ 数据库)

---

## 1. 概述

### 1.1 目标

将 [DBX](https://github.com/t8y2/dbx)(Rust + Tauri 2 的数据库管理工具,80+ 数据库驱动、20MB 级单二进制)移植为可以在 OpenHarmony 设备上**直接运行**的版本。

### 1.2 结果

| 项 | 值 |
|---|---|
| 运行形态 | DBX **Web 版**(`dbx-web` 后端 + Vue 前端) |
| 后端二进制 | `dbx-web`,67.8MB,aarch64-unknown-linux-ohos,原生编译 |
| 前端 | Vue 3 构建产物,21MB,静态文件由后端托管 |
| 端口 | 4224(可用 `DBX_PORT` 覆盖) |
| 验证 | 前端页面 200 ✓ 认证 API ✓ SQLite 连接 ✓ SQL 查询返回正确结果 ✓ |
| 部署目录 | `~/dbx-ohos/`(dbx-web + static/ + data/ + start.sh) |

### 1.3 为什么是 Web 版而不是桌面版

DBX 桌面版基于 Tauri 2,依赖系统 WebView(GTK/WebKit2GTK)。OHOS 上没有这些组件,桌面壳无法运行。DBX 仓库本身提供 Web 版(Rust `dbx-web` Axum 后端 + 同一套 Vue 前端,即 Docker 镜像使用的形态),功能与桌面版一致,是 OHOS 上唯一可行的运行形态。

---

## 2. 构建环境

| 项 | 值 |
|---|---|
| 系统 | HarmonyOS NEXT(内核 "HongMeng Kernel 1.13.0"),aarch64 |
| 工具链 | harmonybrew:cargo/rustc 1.97.1(host = `aarch64-unknown-linux-ohos`)、node v26.5.0、pnpm、gcc/clang(llvm@21)、cmake、perl、openssl |
| 硬件 | 20 核 / 32GB RAM / 50GB swap |
| libc | musl(`/lib/ld-musl-aarch64.so.1`) |

关键点:本机 rustc 的 host triple 就是 `aarch64-unknown-linux-ohos`,因此 **cargo 直接原生构建即为 OHOS 目标**,无需交叉编译。

---

## 3. 总体架构

```
┌─────────────────────────────────────────────┐
│  dbx-web (Rust/Axum, 0.0.0.0:4224)          │
│  ├── /api/*  REST(连接、查询、schema 等)     │
│  ├── /       Vue 前端静态资源(DBX_STATIC_DIR)│
│  └── data/   数据库文件+插件(DBX_DATA_DIR)   │
└─────────────────────────────────────────────┘
```

构建流程(与上游 Dockerfile 一致):
1. 前端:`pnpm build` → `dist/`(Vite/Rolldown)
2. 后端:`cargo build --release -p dbx-web`
3. 运行:`DBX_STATIC_DIR=<dist> DBX_DATA_DIR=<data> dbx-web`

---

## 4. 前端构建

### 4.1 流程

```sh
# 必须使用 pnpm 11.19.0(见 4.2)
/storage/Users/currentUser/npm/bin/pnpm install --frozen-lockfile   # 实际委托到 packageManager 声明的 pnpm 10.27.0
pnpm build   # 产出 dist/
```

### 4.2 pnpm 引擎身份校验失败

**现象**

```
[ERROR] Cannot verify the identity of the @pnpm/exe.openharmony-arm64 native binary:
it is missing from pnpm-lock.yaml.
```

**根因**:pnpm ≥ 11.20 新增"引擎身份校验",运行时会用环境锁文件(`pnpm-lock.env.yaml`)校验自身原生二进制;`openharmony-arm64` 平台没有对应的 `@pnpm/exe` 平台包,校验硬失败(与 Alpine/musl/FreeBSD 上的已知问题同源,pnpm/pnpm#13622)。

**解法**:降级到 pnpm 11.19.0(该校验在 11.20 引入):

```sh
npm install -g pnpm@11.19.0
# 直接用绝对路径调用,避免 PATH 里 harmonybrew 的 11.21.0
/storage/Users/currentUser/npm/bin/pnpm --version   # 11.19.0
```

仓库 `package.json` 声明 `packageManager: pnpm@10.27.0`,11.19 会自动委托到 10.27.0(纯 JS 版,无此校验)。

### 4.3 Rolldown 原生绑定 dlopen 失败(核心问题)

**现象**:`pnpm build` 报 `Cannot find native binding`,错误链底层是

```
Error loading shared library ...rolldown-binding.openharmony-arm64.node: Permission denied
```

**排查过程**(这是整个移植最深的坑,详见第 6 节"OHOS 代码签名机制"):任何 `@rolldown/binding-openharmony-arm64`、`@oxlint/...` 等 npm 原生绑定都无法被 dlopen,而本机工具链编译的 `.so` 全部正常。逐一排除:文件权限、挂载 noexec、SELinux 标签、ELF note 结构、PT_NOTE/节表、PT_TLS、段布局、文件大小……最终确认是 **OHOS 内核的 fs-verity 代码签名校验**:可执行映射(PROT_EXEC)要求文件携带有效的 `.codesign` 节(Merkle 树),本机 lld 链接时默认 `--code-sign` 自动签名,而 GitHub CI 构建的 npm 包没有(或用别的 key 签的)。

**解法**:用 OHOS SDK 自带的签名工具给所有原生绑定补签:

```sh
SIGN=/storage/Users/currentUser/.harmonybrew/bin/binary-sign-tool   # 来自 ohos-sdk/26.0.0.18_1
for f in $(find node_modules/.pnpm -name "*.node"); do
  $SIGN sign -selfSign 1 -inFile "$f" -outFile "$f"
done
```

注意:
- 签名后文件会被置为**不可写**(hmfs 密封),需再修改时用"复制到新文件 → 修改/签名 → `os.replace` 覆盖"的方式。
- 本机 Rust 产物不需要此步骤(lld 默认已签名)。

### 4.4 WASI 回退方案的 preopen 补丁(备选路径)

在签名方案之前,曾用 WASI 回退让 rolldown 跑起来(保留参考):

- `@rolldown/binding-wasm32-wasi` 需手动安装并在 rolldown 包内建符号链接(见 4.6)。
- Node WASI 初始化报 `UVWASI_EACCES, uvwasi_init`:binding 预打开文件系统根目录 `/` 被沙箱拒绝。补丁:`rolldown-binding.wasi.cjs` 与 `wasi-worker.mjs` 中

```js
preopens: {
  [process.cwd()]: process.cwd(),
  [__rootDir]: '/data/storage/el2/base/tmp/opencode',   // 原为 [__rootDir]: __rootDir
}
```

### 4.5 lightningcss / tailwindcss-oxide:平台包伪装 + libgcc_s + PT_TLS

构建推进中先后遇到 lightningcss、tailwind oxide 的原生依赖缺失:

**(a) 平台包伪装**

两者都没有 `*-openharmony-arm64` 平台包。方案:安装 linux-arm64-musl 版本,符号链接伪装为 openharmony 平台包:

```sh
pnpm add -D lightningcss-linux-arm64-musl@1.32.0 lightningcss-linux-arm64-musl@1.33.0 @tailwindcss/oxide-linux-arm64-musl@4.3.0

# 在对应 lightningcss 包的 node_modules 下建链接(注意相对深度:包在 .pnpm 下,用两级 ../..)
ln -sfn ../../lightningcss-linux-arm64-musl@1.32.0/node_modules/lightningcss-linux-arm64-musl \
  node_modules/.pnpm/lightningcss@1.32.0/node_modules/lightningcss-openharmony-arm64
# 1.33.0 同理;oxide 在 @tailwindcss/ 子目录,用三级 ../../..
mkdir -p node_modules/.pnpm/@tailwindcss+oxide@4.3.0/node_modules/@tailwindcss
ln -sfn ../../../@tailwindcss+oxide-linux-arm64-musl@4.3.0/node_modules/@tailwindcss/oxide-linux-arm64-musl \
  node_modules/.pnpm/@tailwindcss+oxide@4.3.0/node_modules/@tailwindcss/oxide-openharmony-arm64
```

**(b) libgcc_s.so.1**

lightningcss 的 musl 包 `NEEDED libgcc_s.so.1`,系统没有。用 llvm 自带 libunwind + compiler-rt 现编:

```sh
LLVM=/storage/Users/currentUser/.harmonybrew/opt/llvm@21
cc -shared -o libgcc_s.so.1 \
  -Wl,--whole-archive $LLVM/lib/aarch64-linux-ohos/libunwind.a \
                    $LLVM/lib/clang/21/lib/aarch64-linux-ohos/libclang_rt.builtins.a \
  -Wl,--no-whole-archive
# 放置于 LD_LIBRARY_PATH 可达目录(如 ~/.harmonybrew/lib)
```

构建前端时需:`export LD_LIBRARY_PATH=/storage/Users/currentUser/.harmonybrew/lib`

**(c) PT_TLS 导致 musl 加载崩溃**

`dlopen` 直接 SIGSEGV(非 EACCES)。逐一隔离(清零 `.init_array` 无效)后定位到 **PT_TLS** 段:该 .node 有 14 个 `R_AARCH64_TLSDESC` 重定位,OHOS musl 加载此 TLS 布局时崩溃;而 rolldown(无 PT_TLS)正常。

**解法**:移除 PT_TLS 程序头(置为 PT_NULL)后重新签名,功能验证通过:

```python
# 对每个 .node:遍历 phdr,e_type==7 (PT_TLS) → 置 0
# 然后 binary-sign-tool sign -selfSign 1 重新签名(先复制到新文件,再 os.replace 覆盖)
```

实测移除 TLS 后 lightningcss 的 `transform()` 正常工作(TLS 变量实际未被使用)。

### 4.6 pnpm 严格 node_modules 缺符号链接

rolldown 的 WASI 回退与平台包解析要求 `@rolldown/binding-wasm32-wasi` 可从 rolldown 包内 require 到,pnpm 严格模式不建该链接:

```sh
ln -sfn ../../../@rolldown+binding-wasm32-wasi@1.2.3/node_modules/@rolldown/binding-wasm32-wasi \
  node_modules/.pnpm/rolldown@1.2.3/node_modules/@rolldown/
```

(符号链接相对路径必须按 `.pnpm/<pkg>/node_modules/` 的真实深度计算,多一级 `..` 就会指向项目根而解析失败。)

### 4.7 前端构建完成

```sh
LD_LIBRARY_PATH=/storage/Users/currentUser/.harmonybrew/lib pnpm build
# ✓ built in 34.42s → dist/(21MB)
```

---

## 5. 后端构建(cargo)

### 5.1 流程

```sh
cd ~/springsources/dbx
cargo build --release -p dbx-web \
  --config 'profile.release.lto=false' \
  --config 'profile.release.codegen-units=16'
# 产物:target/release/dbx-web (67.8MB)
```

> 上游默认 release profile 为 `lto=true, codegen-units=1, opt-level=s`,对 aws-lc-sys 会链接失败(见 5.4),且极慢;本移植用 `lto=false + codegen-units=16`。

### 5.2 zstd-sys:`qsort_r` 未声明

**现象**

```
zstd/lib/dictBuilder/cover.c:332:5: error: call to undeclared function 'qsort_r'
```

**根因**:OHOS musl 的 `libc.so` **导出** `qsort_r`(GNU 签名),但 SDK 头文件没有声明它(与 musl 上游不同)。

**解法**:补丁 `~/.cargo/registry/src/.../zstd-sys-2.0.16+zstd.1.5.7/zstd/lib/dictBuilder/cover.c`,在 include 后加:

```c
#if !defined(__GLIBC__) && !defined(__ANDROID__) && defined(_GNU_SOURCE)
extern void qsort_r(void *__base, size_t __nmemb, size_t __size,
                    int (*__compar)(const void *, const void *, void *),
                    void *__arg);
#endif
```

> 注意:**不要**用全局 `CFLAGS=-D_GNU_SOURCE` 来解决,那会让 openssl 的 `strerror_r` 走 GNU 分支而 OHOS libc 是 XSI 签名(`int strerror_r(...)`),编译报错。zstd 只需局部 extern 声明即可(无 `_GNU_SOURCE` 时 zstd 会走 C90 fallback 分支)。

### 5.3 openssl-sys:strerror_r 签名冲突

`-D_GNU_SOURCE` 下 OpenSSL 期望 GNU 版 `char* strerror_r(...)`,OHOS 头文件声明 XSI 版 `int strerror_r(...)` → `-Wint-conversion` 错误。解法:去掉全局 `-D_GNU_SOURCE`(见 5.2)。

### 5.4 aws-lc-sys:OHOS 目标汇编缺失(最大后端坑)

**现象**:链接失败,大量未定义符号,全部是 ARM 汇编加密函数:

```
undefined symbol: aws_lc_0_43_0_aes_hw_ctr32_encrypt_blocks
undefined symbol: aws_lc_0_43_0_bignum_mul
undefined symbol: aws_lc_0_43_0_edwards25519_decode_alt
... (aesv8/bn_mul_mont/vpaes/s2n-bignum/MLDSA 等)
```

**根因链条**:
1. `aws-lc-sys` 对 `aarch64-unknown-linux-ohos` 强制走 **CMake 构建器**(`CcBuilder::check_dependencies` 对 `target_env()=="ohos"` 直接 `Err("OpenHarmony targets must be built with CMake.")`),试图用 `AWS_LC_SYS_CMAKE_BUILDER=0` 强走 cc 构建器会触发该 panic。
2. CMake 构建时,本机 cmake(harmonybrew)无法识别 HarmonyOS 主机:
   - `CMAKE_SYSTEM_PROCESSOR = "unknown"`(而非 aarch64)→ aws-lc 架构检测落到 `generic` 分支 → `OPENSSL_NO_ASM`,perlasm 汇编全部禁用;
   - `UNIX` 变量为假(cmaven 不认识该系统)→ s2n-bignum、MLDSA 等汇编源列表的 `AND UNIX` 门控全部跳过。

**解法**:补丁 aws-lc 的 CMakeLists(registry 源码内):

`aws-lc/CMakeLists.txt` — 处理器检测回退:

```cmake
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" CMAKE_SYSTEM_PROCESSOR_LOWER)
# OHOS (harmonybrew) cmake 可能检测不到主机处理器(值为 "unknown"),回退到实际架构
if(CMAKE_SYSTEM_PROCESSOR_LOWER STREQUAL "" OR CMAKE_SYSTEM_PROCESSOR_LOWER STREQUAL "unknown")
  execute_process(COMMAND uname -m OUTPUT_VARIABLE CMAKE_SYSTEM_PROCESSOR_LOWER OUTPUT_STRIP_TRAILING_WHITESPACE)
  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR_LOWER}" CMAKE_SYSTEM_PROCESSOR_LOWER)
  if(CMAKE_SYSTEM_PROCESSOR_LOWER MATCHES "aarch64|arm64")
    set(CMAKE_SIZEOF_VOID_P 8)
  endif()
endif()
```

`crypto/fipsmodule/CMakeLists.txt` — 两处 `AND UNIX` 门控加 OHOS 豁免(s2n-bignum 源列表与 MLDSA/ML-KEM 源列表):

```cmake
# 原:... ARCH STREQUAL "aarch64") AND UNIX)
# 改:... ARCH STREQUAL "aarch64") AND (UNIX OR DEFINED OHOS_ARCH))
# 以及:if((ARCH STREQUAL "aarch64") AND (UNIX OR DEFINED OHOS_ARCH))
```

> aws-lc-sys 构建脚本调用 cmake 时自带 `-DOHOS_ARCH=arm64-v8a`,可作豁免标志。

**验证**:修复后归档中汇编对象从 21 个 → 97 个(含 s2n-bignum 全套与 MLDSA),链接通过。

**注意**:每次改完这些补丁必须删除旧构建缓存,否则 cmake 复用旧配置:

```sh
rm -rf target/release/build/aws-lc-sys-* target/release/deps/libaws_lc_sys-* target/release/deps/aws_lc_sys-*
```

### 5.5 thin-LTO 与 aws-lc-sys 不兼容

即使汇编齐全,`lto="thin"` 下链接仍报同样的未定义符号(asm 符号在 LTO 归档解析时丢失)。解法:该移植构建统一 `lto=false`。

### 5.6 构建完成

```sh
# cargo check -p dbx-web --release 通过(22m41s)
# cargo build --release(32m54s)
Finished `release` profile [optimized] target(s) in 32m 54s
# 产物 67.8MB,ELF aarch64,自带 .codesign 节(lld 默认签名)
```

---

## 6. OHOS 代码签名机制(核心发现)

这是本移植最关键的逆向结论,值得单独记录。

### 6.1 现象

- 本机工具链编译/链接的任何可执行文件与 `.so` 都能运行、能被 dlopen;
- 任何"外来"ELF(从 npm/GitHub 下载的二进制)都报 `Permission denied`,无论权限、挂载、SELinux 标签如何;
- 对文件**翻转任意一个字节**(头部、代码、note、文件尾)后,原本可加载的文件立即被拒。

### 6.2 机制

OHOS 内核(hmfs + fs-verity 风格)在 **PROT_EXEC 映射**(mmap/dlopen/exec)时校验文件携带的 `.codesign` 节:

- `.codesign` 节 = fs-verity 风格 Merkle 树(4096 字节块,SHA-256,根哈希写在节头),覆盖整个文件;
- 本地 lld 链接器默认启用 `--code-sign`(可 `--no-code-sign` 关闭),自动计算并嵌入该节——这就是本机产物"天生可用"的原因;
- 内核按节内根哈希校验文件内容,任何字节修改都会失配 → EACCES。

> 实验证据:同一文件仅把 PT_NOTE 尺寸从 48 改 28 字节即被拒;把能加载的 libz 复制后翻转 1 字节也被拒;而 `binary-sign-tool` 补签后的文件(内容未变)即可加载。ELF note、段布局、TLS、文件大小等均不是判定条件。

### 6.3 对外来二进制的处理

```sh
/storage/Users/currentUser/.harmonybrew/bin/binary-sign-tool sign \
  -selfSign 1 -inFile <输入 ELF> -outFile <输出 ELF>
```

- 工具位于 `ohos-sdk/26.0.0.18_1/bin/binary-sign-tool`(harmonybrew Cellar);
- `-selfSign 1` 为自签名模式,无需证书/keystore;
- 签名后文件在 hmfs 上被**密封**(不可写);需再次修改时先复制出新文件、修改、签名,再 `os.replace` 覆盖。

### 6.4 衍生问题

- **PT_TLS 崩溃**:部分 musl 预编译绑定(lightningcss)带 TLS 段,OHOS musl dlopen 时 SIGSEGV;移除 PT_TLS 后正常(见 4.5c)。
- **libgcc_s 缺失**:gcc 工具链构建的绑定需要 `libgcc_s.so.1`,系统没有;用 llvm libunwind + compiler-rt 现编(见 4.5b)。

---

## 7. 部署与运行

### 7.1 目录结构

```
~/dbx-ohos/
├── dbx-web          # 67.8MB 后端二进制(已签名)
├── static/          # 前端构建产物(21MB)
├── data/
│   ├── dbx.db       # DBX 自身配置库(首次启动自动创建)
│   ├── plugins/dialects/   # 方言插件(35 个)
│   └── test.db      # 验证用 SQLite
└── start.sh         # 启动脚本
```

### 7.2 启动

```sh
sh ~/dbx-ohos/start.sh            # 默认 4224
sh ~/dbx-ohos/start.sh 8080       # 自定义端口
```

start.sh 内容:

```sh
#!/bin/sh
PORT="${1:-4224}"
export DBX_DATA_DIR="$HOME/dbx-ohos/data"
export DBX_STATIC_DIR="$HOME/dbx-ohos/static"
export DBX_DISABLE_PASSWORD=true
export RUST_LOG=info
exec env DBX_PORT="$PORT" "$HOME/dbx-ohos/dbx-web"
```

### 7.3 访问

- 本机浏览器:`http://localhost:4224`
- 局域网其他设备:`http://<设备IP>:4224`
- API 示例:

```sh
# 健康检查
curl http://localhost:4224/api/auth/check
# → {"authenticated":true,"required":false,"setup_required":false}

# 连接 SQLite
curl -X POST http://localhost:4224/api/connection/connect \
  -H "Content-Type: application/json" \
  -d '{"config":{"id":"t1","db_type":"sqlite","host":"/storage/Users/currentUser/dbx-ohos/data/test.db","name":"test","username":"","password":"","port":0}}'
# → "t1"

# 执行 SQL
curl -X POST http://localhost:4224/api/query/execute \
  -H "Content-Type: application/json" \
  -d '{"connectionId":"t1","database":"","sql":"select 1 as answer, '\''dbx-on-ohos'\'' as tag"}'
# → {"columns":["answer","tag"],"rows":[[1,"dbx-on-ohos"]],...}
```

### 7.4 关键环境变量

| 变量 | 说明 | 默认 |
|---|---|---|
| `DBX_PORT` | 监听端口 | 4224 |
| `DBX_DATA_DIR` | 数据/插件目录 | `~/.dbx-web` |
| `DBX_STATIC_DIR` | 前端静态资源目录 | 无(仅 API) |
| `DBX_DISABLE_PASSWORD` | 关闭登录密码 | false |
| `DBX_PASSWORD` / `DBX_PUBLIC_BASE_PATH` | 密码 / 反向代理前缀 | — |

> 注意:连接(connection)是服务进程内存态,重启后需在前端/API 重新连接。

---

## 8. 验证清单

- [x] `cargo check -p dbx-web --release` 零错误
- [x] `pnpm build` 34.42s 产出 dist/
- [x] 二进制含 `.codesign` 节
- [x] 服务启动:注册 35 个核心方言 + 35 个插件方言,监听 0.0.0.0:4224
- [x] `GET /` 返回前端 index.html(HTTP 200)
- [x] `GET /api/auth/check` 返回 authenticated
- [x] `POST /api/connection/connect`(SQLite)成功
- [x] `POST /api/query/execute` 返回正确结果 `[[1,"dbx-on-ohos"]]`

---

## 9. 已知限制与后续工作

1. **前端 node_modules 已打本地补丁**(二进制签名、平台包符号链接、WASI preopen 补丁),`pnpm install` 重新安装后会丢失,需按第 4 节重做。建议后续封装为 `scripts/ohos-prepare-frontend.sh`。
2. **cargo 补丁在 `~/.cargo/registry` 源码内**(zstd-sys cover.c、aws-lc CMakeLists×3),属"脏补丁"。长期方案:
   - 为 aws-lc-sys 提交 OHOS 目标支持(处理器检测回退 + `UNIX OR OHOS_ARCH` 门控);
   - 为 zstd-sys 提交 qsort_r 声明兼容;
   - 或用 `[patch.crates-io]` 指向本地 fork。
3. **lightningcss 移除了 PT_TLS**:若未来版本实际使用 TLS 变量会崩溃,需跟踪。
4. **构建参数**:本移植使用 `lto=false + codegen-units=16`,产物 67.8MB;如需体积优化可尝试 `opt-level=s` + 非 thin LTO(但需解决 aws-lc 符号问题)。
5. 未验证项:MySQL/PostgreSQL 等远程数据库连接(需真实服务器)、MCP/CLI 组件、JDBC agent(需 Java 运行时)。
6. 桌面版 Tauri 壳在 OHOS 上不可行,如需原生窗口形态需另做 ArkUI 壳或使用系统 WebView 封装。

---

## 附录 A:补丁清单汇总

| # | 位置 | 问题 | 补丁 |
|---|---|---|---|
| 1 | pnpm 全局 | 引擎身份校验(11.20+) | 降级 11.19.0 |
| 2 | rolldown wasi cjs/worker | preopen `/` EACCES | preopens 指向 cwd + 临时目录 |
| 3 | rolldown/binding-wasm32-wasi | pnpm 不建链接 | 手动符号链接 |
| 4 | node_modules 全部 *.node | 无 codesign 签名 | binary-sign-tool -selfSign 1 |
| 5 | lightningcss/oxide 平台包 | 无 openharmony 平台包 | 装 linux-arm64-musl + 伪装链接 |
| 6 | lightningcss .node | NEEDED libgcc_s.so.1 | libunwind+builtins 现编 libgcc_s.so.1 |
| 7 | lightningcss .node | PT_TLS 加载崩溃 | 移除 PT_TLS + 重签名 |
| 8 | zstd-sys cover.c | qsort_r 未声明 | extern 声明(禁全局 _GNU_SOURCE) |
| 9 | aws-lc CMakeLists.txt | CMAKE_SYSTEM_PROCESSOR=unknown | uname -m 回退 |
| 10 | aws-lc fipsmodule CMakeLists | `AND UNIX` 门控跳过汇编 | `(UNIX OR DEFINED OHOS_ARCH)` ×2 |
| 11 | cargo profile | thin-LTO 与 aws-lc 冲突 | `--config profile.release.lto=false` |

## 附录 B:复现命令速查

```sh
# 环境准备
npm install -g pnpm@11.19.0

# 前端
cd ~/springsources/dbx
/storage/Users/currentUser/npm/bin/pnpm install --frozen-lockfile
# …按附录 A #2-#7 打补丁后:
LD_LIBRARY_PATH=/storage/Users/currentUser/.harmonybrew/lib pnpm build

# 后端(补丁 #8-#10 后)
cd ~/springsources/dbx
cargo build --release -p dbx-web \
  --config 'profile.release.lto=false' \
  --config 'profile.release.codegen-units=16'

# 部署
mkdir -p ~/dbx-ohos/{static,data/plugins}
cp target/release/dbx-web ~/dbx-ohos/
cp -r dist/* ~/dbx-ohos/static/
cp -r plugins/dialects ~/dbx-ohos/data/plugins/
sh ~/dbx-ohos/start.sh
```
