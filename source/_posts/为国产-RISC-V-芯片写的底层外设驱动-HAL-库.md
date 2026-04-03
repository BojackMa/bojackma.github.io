---
title: 为国产 RISC-V 芯片写的底层外设驱动/HAL 库
date: 2026-04-02 20:35:12
tags:
    - rust
---



## 背景：我参与的是什么生态？

### RustSBI 是什么

RustSBI 是一个开源组织，目标是用 **Rust 语言**为 **RISC-V 架构**的芯片提供底层固件支持。

理解它需要先知道几个概念：

- **RISC-V**：一种开源的处理器指令集架构（ISA），近年来在国产芯片领域非常活跃，类似于 ARM，但完全开放免授权费。
- **SBI（Supervisor Binary Interface）**：RISC-V 体系中规定的一套接口标准，位于硬件和操作系统内核之间，类似于 x86 平台的 BIOS/UEFI。它负责启动、中断委托、时钟等底层功能，让 Linux 这样的操作系统可以不关心具体硬件细节。
- **RustSBI**：用 Rust 语言实现的 SBI 固件库，被用于多款国产 RISC-V 开发板，包括全志 D1、博流 BL808 等。

**一句话总结：RustSBI 就是国产 RISC-V 芯片的"固件/BIOS 层"，用 Rust 写。**


---

## 项目一：RustSBI/blri

### 项目是干什么的

**blri = Bouffalo ROM Image helper**

这是一个运行在**开发者电脑（PC）上**的命令行工具，用于在固件烧录到芯片之前，**验证固件文件（.bin）是否合法**。

针对的芯片是**博流智能（Bouffalo Lab）的 BL808**，这是一款 RISC-V SoC，搭载 64 位 C906 核，支持 WiFi/BLE，甚至可以跑 Linux，出现在 Pine64 Ox64、Sipeed M1s Dock 等开发板上。

**使用流程：**

```
开发者在电脑上写代码
       ↓
编译成固件 .bin 文件
       ↓
用 blri 在电脑上检查这个 .bin 文件合不合法   ← 这个工具的作用
       ↓
没问题，再烧录到 BL808 芯片上
       ↓
芯片上电运行
```

类比：就像快递验货——先检查包装和签条对不对，再决定要不要收货。

### 工具做了哪些检查

1. **文件头魔数校验**：偏移 `0x00`，检查是否为 `0x42464e50`，确认"这是博流格式的固件"
2. **Flash 配置段魔数**：偏移 `0x08`，检查 `0x46434647`
3. **时钟配置段魔数**：偏移 `0x64`，检查 `0x50434647`
4. **文件长度检查**：文件头至少要有 `0x160`（352）字节
5. **镜像偏移边界检查**：固件内容的起始位置 + 长度不能超过文件总大小
6. **SHA256 哈希校验**：从文件头 `0x90` 处读出期望哈希，与实际计算值比对，验证固件完整性

### 我做的贡献


```rust
// ===== 常量定义：固件文件各段的"暗号"（魔数）=====
// 这些是博流芯片规定的固定数字，就像身份证号一样
// 如果文件里对应位置的数字不对，说明这个文件不是合法的博流固件

const HEAD_LENGTH: u64 = 0x160;        // 文件头必须至少有这么长（352字节）
const HEAD_MAGIC: u32 = 0x42464e50;    // 文件开头的暗号，标志"我是博流固件"
const FLASH_MAGIC: u32 = 0x46434647;   // Flash配置段的暗号
const CLK_MAGIC: u32 = 0x50434647;     // 时钟配置段的暗号

// ===== 错误类型定义 =====
// 你用 thiserror 库定义了所有可能出错的情况
// 这比原来直接 println!("error...") 要专业得多

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("I/O error")]
    Io(#[from] io::Error),             // 读文件失败

    #[error("Wrong magic number")]
    MagicNumber { wrong_magic: u32 },  // 文件头暗号不对

    #[error("File is too short...")]
    HeadLength { wrong_length: u64 },  // 文件太短，连头部都不完整

    #[error("Wrong flash config magic")]
    FlashConfigMagic,                  // Flash配置段暗号不对

    #[error("Wrong clock config magic")]
    ClockConfigMagic,                  // 时钟配置段暗号不对

    #[error("Image offset overflow...")]
    ImageOffsetOverflow { ... },       // 固件内容超出文件范围

    #[error("Wrong sha256 checksum")]
    Sha256Checksum,                    // SHA256哈希校验失败（内容被篡改或损坏）
}

// ===== 核心校验函数 =====
pub fn process(f: &mut File) -> Result {

    // 第一步：检查文件总长度
    let file_length = f.metadata()?.len();

    // 第二步：跳到文件开头（偏移0x00），读取4字节，检查"文件头暗号"
    f.seek(SeekFrom::Start(0x00))?;
    let head_magic = f.read_u32::<BigEndian>()?;  // BigEndian = 大端序读取
    if head_magic != HEAD_MAGIC {
        return Err(Error::MagicNumber { wrong_magic: head_magic });
        // 暗号不对，直接返回错误，后面不用看了
    }

    // 第三步：检查文件是否够长（至少要有完整的头部）
    if file_length < HEAD_LENGTH {
        return Err(Error::HeadLength { wrong_length: file_length });
    }

    // 第四步：跳到偏移0x08，检查"Flash配置段暗号"
    f.seek(SeekFrom::Start(0x08))?;
    let flash_magic = f.read_u32::<BigEndian>()?;
    if flash_magic != FLASH_MAGIC {
        return Err(Error::FlashConfigMagic);
    }

    // 第五步：跳到偏移0x64，检查"时钟配置段暗号"
    f.seek(SeekFrom::Start(0x64))?;
    let clk_magic = f.read_u32::<BigEndian>()?;
    if clk_magic != CLK_MAGIC {
        return Err(Error::ClockConfigMagic);
    }

    // 第六步：读取固件内容的"起始位置"和"长度"
    f.seek(SeekFrom::Start(0x84))?;
    let group_image_offset = f.read_u32::<LittleEndian>()?; // 小端序读取，固件内容从哪里开始
    f.seek(SeekFrom::Start(0x8C))?;
    let img_len_cnt = f.read_u32::<LittleEndian>()?;        // 固件内容有多长

    // 第七步：检查固件内容有没有超出文件范围
    // （起始位置 + 长度）不能超过文件总大小
    if group_image_offset as u64 + img_len_cnt as u64 > file_length {
        return Err(Error::ImageOffsetOverflow { ... });
    }

    // ===== 重点：这是你新增的SHA256校验部分 =====

    // 第八步：从文件偏移0x90处，读出固件头里存的"期望哈希值"（32字节）
    // 这个哈希值是打包固件时写进去的，相当于固件的"指纹"
    f.seek(SeekFrom::Start(0x90))?;
    let mut hash = vec![0; 32];
    f.read(&mut hash)?;

    // 第九步：自己重新计算固件内容的SHA256哈希值
    f.seek(SeekFrom::Start(group_image_offset as u64))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; img_len_cnt as usize];
    loop {
        let n = f.read(&mut buffer)?;
        if n == 0 { break; }
        hasher.update(&buffer[..n]);  // 把固件内容喂给哈希计算器
    }
    let hash2 = hasher.finalize();   // 得出实际哈希值

    // 第十步：比对两个哈希值
    if vec1 != hash {
        // 特殊情况：有些固件用 0xdeadbeef 做占位符，表示"我不需要校验"
        // 这种情况要豁免，不算错误
        let vec2 = ...; // [0xef, 0, 0, 0, 0, 0, 0, 0] 
        let vec3 = ...; // [0xef, 0xef, 0xef, ...] 全是0xef
        if hash != vec2 && hash != vec3 {
            return Err(Error::Sha256Checksum); // 哈希不匹配，固件损坏或被篡改！
        }
    }

    Ok(()) // 所有检查都通过，固件合法！
}

```

我实现了 process() 这个核心校验函数，对博流固件文件做了六道顺序检查：文件头魔数、头部完整性、Flash段魔数、时钟段魔数、内容偏移边界，以及 SHA256 完整性校验。过程中正确处理了固件格式里大端/小端混用的字段读取，以及开发版固件用 0xdeadbeef 跳过哈希校验的边界情况。


**0. 做了什么检查**
校验文件头魔数（偏移 0x00）

校验文件长度

校验 Flash 配置段魔数

校验时钟配置段魔数

读固件内容的位置和长度

偏移边界检查

SHA256 校验

**1. 库/二进制分离（lib.rs + main.rs）**

把核心校验逻辑抽取到 `lib.rs`，暴露 `process()` 函数。这样 blri 既是命令行工具，也是可以被其他 Rust 项目 `cargo add` 引入的库。

**2. 引入结构化错误类型（thiserror）**

用 `thiserror` 定义枚举错误类型，每种错误都有清晰的语义：

```rust
pub enum Error {
    Io(#[from] io::Error),
    MagicNumber { wrong_magic: u32 },
    HeadLength { wrong_length: u64 },
    FlashConfigMagic,
    ClockConfigMagic,
    ImageOffsetOverflow { file_length, wrong_image_offset, wrong_image_length },
    Sha256Checksum,
}
```

替换了原来粗糙的 `println!("error: ...")` 风格。

**3. 新增 SHA256 完整性校验（原版没有）**

从固件头读出"期望哈希"，对固件内容段重新计算 SHA256，比对两者。还特殊处理了用 `0xdeadbeef` 做占位符的固件（表示"不需要校验"，需要豁免）。

**4. 编写集成测试**

新增 `tests/file_process.rs`，用真实的 `blinky-bl808.bin` 固件文件作为测试素材，覆盖了错误场景。

### 为什么用 Rust 而不是 C

- **二进制解析场景下，C 很容易带着脏数据继续跑**：`fread` 失败了不检查就继续，后续所有校验结果都是错的。Rust 的 `?` 运算符强制处理每一个可能的错误，漏掉一个编译不过。
- **作为库被复用时，调用方必须处理错误**：Rust 的 `Result` 类型配合 `match`，调用方无法忽略错误。C 的返回码经常被忽略。
- **整个 RustSBI 生态都是 Rust**：作为库发布，`cargo add blri` 即可无缝集成。

---

## 项目二：RustSBI/010-editor-scripts

### 项目是干什么的

**010 Editor** 是一款商业十六进制编辑器。它最核心的功能是 **Binary Template（二进制模板）**：你用一个类 C 语法的脚本文件（`.bt`），描述某种二进制文件的数据结构，010 Editor 就能把一堆看不懂的十六进制数据，解析并可视化显示成有名字、有层次的结构。

**没有模板时看到的：**
```
42 46 4E 50 00 00 00 00 46 43 46 47 ...
```

**有模板后看到的：**
```
jump_instruction = 0x00000297   // 跳转指令
magic            = 0x3054422E4E4F4765  // 魔数 ✓
checksum         = 0xABCD1234   // 校验和
total_length     = 0x00001000   // 固件总长度
```

**RustSBI/010-editor-scripts** 这个项目就是为各款**国产 RISC-V 芯片固件**提供这样的解析模板，方便开发者调试固件文件内部结构。

### .bt 语言是什么

不是新语言。`.bt` 文件的语法基本就是 **C 语言的 struct + 简单控制流（if/for/while）**，会 C/C++ 就能直接上手。它不是在"运行程序"，而是在"描述二进制文件的结构"，类似于 HTML 描述网页结构。

### 我做的贡献

我修改的文件是 `D1Image.bt`，针对的是**全志 D1 芯片**（另一款国产 RISC-V 芯片，搭载玄铁 C906 核，可运行 Linux）的固件格式。

**背景知识：**

RISC-V 有一个扩展叫 **RVC（RISC-V Compressed Instructions）**，允许把某些常见指令从 32 位压缩成 16 位，节省代码体积。D1 芯片支持 RVC。

固件文件的开头有一条"跳转指令"，告诉处理器"代码段从哪里开始"。这条指令可能是：
- **标准 32 位 JAL 指令**（opcode = `0x6f`）
- **压缩 16 位 C.J 指令**（`c_op == 0x1 && c_funct3 == 0x5`）

**原来的模板只支持 32 位 JAL，遇到用 C.J 指令的固件就解析错了。**

**我新增的逻辑：**

```c
// 取低16位，判断是否为压缩指令 C.J
local uint16 c_ins   = head.jump_instruction & 0xffff;
local uint16 c_op    = c_ins & 0x3;       // 最低2位
local uint16 c_funct3 = c_ins >> 13;      // 最高3位

if (c_op == 0x1 && c_funct3 == 0x5) {    // 这是 C.J 压缩跳转指令
    // RISC-V 压缩指令的跳转偏移量被故意打散在16位中的11个不连续位置
    // 需要按规范一位一位提取，再重新拼装成完整偏移量
    local uint16 imm11 = (c_ins >> 12) & 0x1;
    local uint16 imm4  = (c_ins >> 11) & 0x1;
    local uint16 imm98 = (c_ins >>  9) & 0x3;
    // ... 共11个位域
    local uint16 offset = (imm11 << 11) | (imm4 << 4) | (imm98 << 8) | ...;

    // 安全检查：代码段不能越界，不能超过文件末尾
    if (offset < FileSize() && head.total_length <= FileSize()) {
        FSeek(offset);
        ubyte code[head.total_length - offset] <bgcolor=cLtGreen>;  // 绿色高亮代码段
    } else {
        Warning("code appears to either overlap with header or exist after end of file!");
    }
}
```

**一句话总结：我让这个模板能正确解析使用 RISC-V 压缩跳转指令（C.J）的全志 D1 固件，并加了越界安全检查。**



"RISC-V 为了让硬件解码器能复用电路、降低功耗，规定了几种固定的指令格式，不同格式之间某些字段的位置是相同的。副作用是跳转指令的目标地址被拆散存在几个不连续的位置。我的代码就是按照 RISC-V 规范，把这些散落的位逐个提取出来，再按正确顺序拼回完整的偏移量，从而找到固件里代码段的起始位置。"




---

## 面试常见追问 & 参考回答

### 关于 Rust

**Q：你为什么选 Rust，C/C++ 不也能做吗？**

> Rust 的核心优势是"内存安全，但没有 GC"。在嵌入式和系统工具场景，C 的常见问题是 use-after-free、越界访问这类内存错误，运行时才崩，很难排查。Rust 的所有权系统把这类错误提前到编译期，根本跑不起来。同时它没有垃圾回收，性能和 C 一个量级，适合这类场景。

**Q：Rust 的所有权是什么意思？**

> 每一块内存同时只有一个"主人"，主人的作用域结束了内存自动释放，不用手动 free，也不需要 GC。转移所有权之后原变量就失效了，编译器会直接报错，所以根本不可能出现 use-after-free。

**Q：Rust 的错误处理和 C/C++ 有什么不同？**

> C 用返回码，调用方可以忽略；C++ 用异常，在嵌入式里经常被禁用。Rust 用 `Result<T, E>` 类型，不处理编译器给警告，用 `match` 强制穷举所有情况，漏掉一种错误类型编译直接报错。

### 关于 blri

**Q：SHA256 校验的具体逻辑是什么？**

> 固件在打包时会把内容的 SHA256 哈希值写进文件头的 `0x90` 偏移处。我的代码从这里读出"期望哈希"，然后重新对固件内容段（从 `group_image_offset` 开始，长度 `img_len_cnt`）计算 SHA256，两者比对。如果不一致说明固件损坏或被篡改。有个特殊情况：有些固件开发阶段会用 `0xdeadbeef` 填充哈希字段，表示"不需要校验"，这种要豁免掉。

**Q：为什么要做库/二进制分离？**

> 分离之后 blri 既可以作为命令行工具直接用，也可以作为 Rust 库被其他项目 `cargo add blri` 引入，复用校验逻辑。如果都堆在 main.rs 里，别人就没法把它当库用了。

**Q：这个工具是跑在芯片上的吗？**

> 不是，它跑在开发者的电脑上，是开发阶段的辅助工具。在把固件烧录到芯片之前，先用 blri 检查文件格式和完整性，避免把损坏的固件刷进去（刷坏了可能变砖）。

### 关于 010-editor-scripts

**Q：.bt 是什么语言，你专门学过吗？**

> .bt 不是新语言，语法基本就是 C 的 struct 加上 if/for/while，我有 C/C++ 基础可以直接上手，没有额外的学习成本。

**Q：为什么 RISC-V 压缩指令的位域是打散的？**

> 这是 RISC-V 规范有意为之的设计，目的是让不同格式的指令在相同的位域位置上有相同的含义，减少解码器的硬件复杂度，即使增加了软件解析时的位拼装工作。

**Q：你具体做了什么测试验证你的改动是正确的？**

> 用 010 Editor 对真实的 D1 固件文件跑模板，对比解析出的跳转地址和固件实际代码段起始地址是否一致，以及代码段的内容是否被正确高亮。

---

## 简历一行版（可直接复制）

- **RustSBI/blri**：将博流 BL808 芯片固件校验工具从单文件脚本重构为库+二进制分离架构，新增 SHA256 固件完整性校验，引入结构化错误处理（thiserror），补充集成测试，PR 已合并至主仓库。
- **RustSBI/010-editor-scripts**：为全志 D1 芯片的 010 Editor 固件解析模板新增 RISC-V 压缩指令（RVC C.J）支持，实现跳转偏移量的位域拼装解析，并加入越界安全检查，PR 已合并至主仓库。




版本一：30秒版（自我介绍时顺带提一句）

"我参与过 RustSBI 社区的开源贡献，这是一个为国产 RISC-V 芯片提供底层固件支持的项目。我做了两块：一个是用 Rust 实现了博流芯片固件文件的校验工具，包括格式校验和 SHA256 完整性校验；另一个是为全志 D1 芯片的固件调试工具扩展了对 RISC-V 压缩指令集的支持。两个 PR 都已经合并进了主仓库。"


版本二：2分钟版（被问到"介绍一下你的项目经历"）
分三段说，逻辑是：背景 → 我做了什么 → 有什么价值。
第一段：背景（20秒）

"RustSBI 是一个开源社区，目标是用 Rust 为国产 RISC-V 芯片做底层固件支持，类似于 x86 平台的 BIOS 层。我参与了其中两个子项目。"

第二段：两个项目各一句话（40秒）

"第一个是 blri，是一个在烧录前检查固件文件是否合法的命令行工具。我把原来堆在 main 函数里的逻辑重构成了库和二进制分离的架构，加了结构化错误处理，并新增了 SHA256 完整性校验——这是原版没有的，也是唯一能发现固件内容被篡改的手段。
第二个是 010 Editor 的固件解析模板。这个工具能把看不懂的固件二进制文件可视化成有结构的字段。我扩展了全志 D1 芯片的模板，让它支持 RISC-V 压缩指令集——原来只能处理标准 32 位跳转指令，有些固件用的是 16 位压缩跳转指令，解析就会出错，我按照 RISC-V 规范把压缩指令里打散的位域重新拼装，实现了正确解析。"

第三段：价值收尾（20秒）

"这两个贡献让我对 RISC-V 指令编码、二进制文件格式解析，以及 Rust 的工程实践有了比较直接的理解。不是应用层的业务代码，更偏底层工具链这个方向。"



介绍完之后面试官大概率会追问，最常见的两个问题是：

"SHA256 校验具体怎么做的？" → 答：从文件头读期望哈希，重新计算实际哈希，比对，处理 deadbeef 占位符豁免。
"压缩指令为什么要打散位域？" → 答：RISC-V 为了让硬件解码器复用电路，不同指令格式的相同字段放在相同位置，代价是立即数被打散，软件解析时要手动拼回来。