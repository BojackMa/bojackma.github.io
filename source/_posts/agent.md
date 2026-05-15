---
title: agent
date: 2026-05-08 13:38:05
tags:
    - agent
---

# AI Agent、Tool Use 与 LLM 辅助逆向分析

---

## 一、AI Agent 的理解

### 最核心的一句话

> 普通 LLM 是"问答机"，Agent 是"能自主完成任务的执行者"。

### LLM vs Agent 的区别

| 维度 | 普通 LLM | AI Agent |
|------|----------|----------|
| 交互模式 | 单轮/多轮对话 | 自主规划、多步执行 |
| 能否使用工具 | 否 | 是（搜索、代码执行、API调用） |
| 能否感知环境 | 否 | 是（读文件、看结果、调整策略） |
| 有无记忆 | 仅上下文窗口 | 可接外部记忆（向量库等） |

### Agent 的核心循环

最经典的是 **ReAct 框架**（Reasoning + Acting）：

```
观察（Observe）
    ↓
思考（Think）：我需要做什么，下一步怎么办？
    ↓
行动（Act）：调用工具 / 执行代码
    ↓
观察结果 → 继续思考 → 直到任务完成
```

举个例子：让 Agent 分析一个 APK

```
任务：分析 com.example.app.apk 是否有数据外发行为

步骤1 Think：我需要先反编译这个 APK
步骤1 Act：调用 jadx 工具 → 得到 Java 代码

步骤2 Think：现在搜索网络相关代码
步骤2 Act：搜索 OkHttp/Retrofit/URL 关键字 → 找到几个可疑类

步骤3 Think：需要分析这些类的具体行为
步骤3 Act：读取并分析代码 → 发现有加密上传逻辑

步骤4 Think：需要确认上传地址
步骤4 Act：追踪字符串常量 → 找到 C2 域名

最终输出报告
```

这就是 Agent 的价值：**自主拆解任务、调用工具、根据中间结果调整方向**。

---

## 二、Tool Use 是如何工作的

### 本质

Tool Use（也叫 Function Calling）是让 LLM 输出**结构化的工具调用指令**，由外部代码执行后再把结果返回给 LLM。

**LLM 本身不执行任何工具**，它只负责"决定调什么、传什么参数"。

### 完整流程

```
① 系统提示中告诉 LLM：你有以下工具可以使用
   {
     "name": "run_jadx",
     "description": "反编译APK，返回Java源码",
     "parameters": {"apk_path": "string"}
   }

② 用户输入任务 → LLM 思考后输出：
   {
     "tool": "run_jadx",
     "parameters": {"apk_path": "/tmp/target.apk"}
   }

③ 你的程序（Agent框架）捕获这个输出，真正执行 jadx

④ 把执行结果塞回对话上下文，LLM继续思考

⑤ 循环直到 LLM 输出最终答案（不再调用工具）
```

### 关键点

- LLM 的"工具能力"本质是**训练出来的格式能力**，它学会了在合适时机输出结构化 JSON
- 工具的描述（description）写得好不好，直接影响 LLM 是否会正确调用
- 工具执行失败时，要把错误信息也返回给 LLM，让它自行纠错重试

### 常见框架怎么封装这件事

```python
# LangChain 风格（概念示意）
@tool
def run_frida_script(script: str, package: str) -> str:
    """在目标APP上运行frida脚本，返回输出结果"""
    # 实际执行 frida 命令
    result = subprocess.run(["frida", "-U", "-f", package, "-l", script])
    return result.stdout

agent = create_react_agent(llm, tools=[run_frida_script, decompile_apk, search_code])
agent.invoke({"input": "分析微信的消息加密方式"})
```

---

## 三、用 LLM 辅助逆向分析

这是这个岗位最有意思的部分，也是当前业界真正在做的方向。

### 场景1：代码理解与反混淆

逆向最痛苦的事之一是读混淆代码：

```java
// 混淆后
public String a(String b, int c) {
    return d.a(b) + e.b(c, this.f);
}
```

把这段扔给 LLM + 上下文（这个类的其他方法、字符串常量、调用链），LLM 能推断出：

```java
// LLM 分析结果
public String encryptData(String plainText, int keyIndex) {
    return Base64Encoder.encode(plainText) + KeyManager.getKey(keyIndex, this.secretSeed);
}
```

**实际做法**：不是直接把整个 smali 扔进去，而是先用传统工具定位关键函数，再用 LLM 做语义理解。

---

### 场景2：自动生成 Frida Hook 脚本

告诉 LLM：

> "这是目标 APP 的登录函数签名和类结构，帮我生成一个 frida 脚本，hook 这个函数并打印入参和返回值"

LLM 可以生成可用的 frida 脚本，大幅减少手写模板代码的时间。

---

### 场景3：加密算法识别

黑产 APP 常用自定义加密，传统方法靠经验人眼识别。LLM 可以：

- 看到一段操作字节数组的代码 → 判断是 AES/RC4/自定义XOR
- 结合常数（如 `0x9e3779b9` 是 TEA 算法特征）做辅助判断
- 给出解密的思路和对应的 Python 实现

---

### 场景4：行为报告自动生成

Agent 串联多个工具后，可以自动产出结构化分析报告：

```
输入：一个待分析的 APK
输出：
  - 网络请求列表及目标域名
  - 敏感权限使用情况
  - 可疑加密/混淆行为
  - 风险评分
```

这正是这个岗位说的"拿结果、做真东西"。

---

### LLM 辅助逆向的局限（面试时说出来会加分）

| 局限 | 原因 |
|------|------|
| 上下文窗口有限 | 大型 APP 代码量远超 LLM 处理能力，需要精准定位后再喂入 |
| 幻觉问题 | LLM 可能"自信地"给出错误的函数语义，需要验证 |
| native 层较弱 | LLM 对 ARM 汇编的理解不如 Java/Python 准确 |
| 无法动态执行 | 必须结合 frida 等动态工具才能完整分析 |

---

## 面试时的表达建议

如果被问到这几个问题，可以这样组织语言：

1. **先说本质**（Agent = 能自主规划和使用工具的系统）
2. **举一个具体场景**（APK 分析 Agent 的执行流程）
3. **说清楚边界**（LLM 的局限，以及如何和传统工具结合）

这样的回答显示你既理解原理，又有落地思维，符合这个岗位"做真东西"的导向。

---

需要我进一步展开哪个部分，或者帮你模拟一下面试问答吗？