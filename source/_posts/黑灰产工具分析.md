---
title: 黑灰产人脸注入工具分析
date: 2026-03-30 16:04:50
tags:
    - 黑灰产
    - 人脸
---


1、技术实现与注入原理

劫持原理？

需要的权限级别（root/越狱 vs. 免root方案）？

是否针对app有优化？

如何实现推流？

防御思路？


## 黑灰产人脸注入工具分析
Android平台上的人脸注入工具，核心目标就是一件事：让目标App的摄像头API返回的不是真实画面，而是攻击者指定的视频流。这类工具经过几年发展，大致经历了三代技术演进，从应用层沙盒、到Xposed框架Hook、再到直接注入系统级cameraserver进程，攻击层级越来越深，检测难度也越来越大。



第一代：应用层沙盒（2022年左右，以VCamera为代表）最早的思路是利用虚拟化框架，代表项目是基于WaxMoon/opensdk的VCamera。它的原理并不复杂——把目标App整个跑在一个虚拟运行时环境里，类似VirtualApp的沙盒技术。在这个沙盒里，App去请求camera service的时候，拿到的其实是一个假的服务指针，从native层就把通信对象换掉了。这个方案最大的优点是不需要root，普通用户就能用。opensdk相比老的VirtualApp有一个改进：它放弃了Java动态代理的方式。原来VirtualApp用Java动态代理拦截App和系统服务之间的Binder通信，但如果目标App自己也用了动态代理，两者会互相覆盖导致崩溃。opensdk改为在native层直接替换service指针，还利用eBPF在系统调用入口做拦截，来对抗360加固之类的反Hook检测。但这个方案的局限性很明显：它本质上是用户态的"骗局"，App可以通过路径检测判断自己是否在沙盒中运行，比如检查/proc/self/maps里有没有可疑路径、向真正的PackageManagerService查询UID做对比、检查调用栈里有没有宿主应用的特征。而且随着Android 9之后系统权限越来越严格，这类沙盒方案的兼容性急剧下降，现在基本不太好用了。


好，我来按照面试中系统介绍的方式讲一遍。你可以当作是模拟面试官提问"请介绍一下你对黑灰产人脸注入工具的研究"之后的回答。

开场概括
Android平台上的人脸注入工具，核心目标就是一件事：让目标App的摄像头API返回的不是真实画面，而是攻击者指定的视频流。这类工具经过几年发展，大致经历了三代技术演进，从应用层沙盒、到Xposed框架Hook、再到直接注入系统级cameraserver进程，攻击层级越来越深，检测难度也越来越大。

第一代：应用层沙盒（2022年左右，以VCamera为代表）
最早的思路是利用虚拟化框架，代表项目是基于WaxMoon/opensdk的VCamera。它的原理并不复杂——把目标App整个跑在一个虚拟运行时环境里，类似VirtualApp的沙盒技术。在这个沙盒里，App去请求camera service的时候，拿到的其实是一个假的服务指针，从native层就把通信对象换掉了。
这个方案最大的优点是不需要root，普通用户就能用。opensdk相比老的VirtualApp有一个改进：它放弃了Java动态代理的方式。原来VirtualApp用Java动态代理拦截App和系统服务之间的Binder通信，但如果目标App自己也用了动态代理，两者会互相覆盖导致崩溃。opensdk改为在native层直接替换service指针，还利用eBPF在系统调用入口做拦截，来对抗360加固之类的反Hook检测。
但这个方案的局限性很明显：它本质上是用户态的"骗局"，App可以通过路径检测判断自己是否在沙盒中运行，比如检查/proc/self/maps里有没有可疑路径、向真正的PackageManagerService查询UID做对比、检查调用栈里有没有宿主应用的特征。而且随着Android 9之后系统权限越来越严格，这类沙盒方案的兼容性急剧下降，现在基本不太好用了。

第二代：Xposed框架Hook（2021-2024年，主线演进）
第二代是目前开源社区里最活跃的技术路线，需要root加上LSPosed框架。核心思路是在目标App的进程内，通过Xposed的Hook机制拦截Camera API调用，把真实帧替换成假帧。
这条线上有几个关键项目，它们之间是明确的迭代关系。
最早的是com.example.vcam（2021年），这是一个非常经典的实现。它同时Hook了Camera1和Camera2两套API，而且覆盖了画面链和数据链两条路径。所谓画面链就是给人看的预览画面，数据链是给算法用的帧数据，比如人脸识别用的。
对Camera1，它做了三件事：第一，Hook setPreviewTexture和setPreviewDisplay，把App传入的Surface换成自己创建的假SurfaceTexture，截断真实画面；第二，Hook startPreview，用MediaPlayer把本地视频渲染到App原本的Surface上，让用户看到假画面；第三，Hook setPreviewCallback，拦截onPreviewFrame回调，把YUV数据替换成视频解码出来的假帧，让算法拿到假数据。
对Camera2更复杂一些，因为Camera2引入了Session和Request的概念。核心是在createCaptureSession的时候，把App提供的Surface列表整个替换成假Surface，真实摄像头的数据被丢弃，然后用MediaPlayer渲染视频到预览Surface，同时用自研的VideoToFrames类做硬解码，把每一帧转成NV21或JPEG格式写入ImageReader的Surface。
但这个版本很粗糙，它用的是MediaPlayer播放本地mp4文件，不支持网络推流，对native层直接访问摄像头的场景也无能为力。我当时基于这个做了一个模块在微信上跑通了实时传输，一开始用adb协议传文件，只能单向传640×480的画面，后来改成TCP协议才做到4K双向传输。
接下来是XVirtualCamera（2023年11月），这是一个质的提升。最大的改进有两点：
第一是架构设计上，它采用"纵向链式拦截"而不是"多点散布式拦截"。vcam同时Hook了十几个方法，逻辑散乱。XVirtualCamera只抓两个关键节点：在openCamera时替换整个StateCallback，在createCaptureSession时直接替换outputSurface列表。这样相机Session直接建立到ijkplayer解码输出的Surface上，不需要两套渲染管线并行，减少了帧同步问题。
第二是引入了bilibili开源的ijkplayer作为播放器内核。ijkplayer底层是FFmpeg，天然支持HTTP、RTSP、RTMP、RTP等几乎所有流媒体协议，可以直接拉取OBS推出的RTMP流。这让工具从"只能播放本地视频"升级到了"可以实时推流"。代价是放弃了逐帧的YUV控制权——ijkplayer直接渲染到Surface，插件对帧内容没有控制权，分辨率、格式、帧率全由ijkplayer决定。
它还做了JNI层的颜色空间转换，在encoder.cpp里实现ARGB到NV21的转换，专门为Camera1的onPreviewFrame回调路径服务，并且针对拼多多、抖音、微信视频号、快手做了特别适配。
我当时也花了大量时间尝试用RTMP方案，试过轻量级RTMP服务器、用ijkplayer拉流，但始终有0.5秒以上的延迟，开销主要卡在视频的编解码环节上，这个问题在这一代技术框架下很难根本解决。
之后是VCAMSX（2023年11月），它在vcam的基础上做了工程化封装：用Kotlin重写、提供完整的App UI、做了Android 11权限适配、引入ExoPlayer替代MediaPlayer获得更好的格式兼容性。它Hook了更多的createCaptureSession变体，包括Android P统一接口的SessionConfiguration版本。本质上VCAMSX把一个面向开发者的PoC变成了普通用户可以使用的产品。
VCAMPRO（2024年10月）则是VCAMSX的兼容性增强版，完整继承了代码架构，主要做适配和稳定性改进，没有底层架构重构。
这一代方案的共同局限是：所有Hook都发生在目标App的Java层。如果App的摄像头调用走的是native层（C++直接访问camera，比如WebRTC），Xposed就拦截不到。而且每个App的Camera使用方式不同，需要逐个适配。



第三代：Native层cameraserver注入（CHMP4系列，商业化黑产）
第三代是真正意义上的"终极形态"，以vcames.xyz售卖的商业工具为代表，包名伪装成com.telegram.a1064。这个方案跳过了应用层，直接在Android系统的cameraserver进程里做手脚。
整体架构分五个组件协同工作。启动时分两条路线并行：
路线A是推流进程。CHMP4-1364这个可执行文件内嵌了完整的FFmpeg静态库（.text段约12MB），启动后持续解码视频源——可以是本地mp4，也可以是RTMP或RTSP流。解码出的I420格式帧写入全局FrameBuffer，同时注册一个叫Video2CameraService的Binder服务到Android ServiceManager，等待取帧请求。
路线B是注入路线。CHMP4-1364通过ptrace附加到cameraserver进程，远程调用mmap分配内存，然后dlopen加载libhookProxy.so。这里有一个精巧的工程设计：为什么不直接加载libCHMP4.so？因为ptrace远程dlopen一次只能加载一个so且无法控制顺序，而libCHMP4依赖libshadowhook必须先加载。所以用一个proxy做代理，libhookProxy通过.init_array机制在dlopen时自动执行，按顺序先加载字节跳动开源的ShadowHook框架，再加载libCHMP4，最后调用main_hook安装9个camera hook。这样把多步初始化从ptrace层移到了so内部，整个注入流程只需要一次ptrace操作。
注入完成后，libCHMP4在cameraserver内部用ShadowHook做inline hook，核心目标是Camera3OutputStream的returnBufferCheckedLocked函数。这个函数是摄像头帧即将返回给App之前的最后一站。Hook函数拦截后，通过Binder向Video2CameraService请求当前视频帧，做格式转换——根据HAL pixel format可能是I420转NV21、NV12、JPEG，甚至处理高通专有的UBWC压缩格式——然后直接写入GraphicBuffer的内存。App从Camera2 API拿到的帧已经是假的了，完全不知情。
这个方案相比第二代有几个根本性优势：第一，它在系统服务层做替换，对所有App透明生效，不需要逐个适配；第二，native层的WebRTC、自定义camera实现全部被覆盖；第三，检测难度大幅提升，App层面基本无法感知。
但它需要的权限也最高：root、关闭SELinux（ptrace跨进程注入的前提）、足够高的系统权限来操作cameraserver。

商业化与反分析对抗
CHMP4系列还展示了完整的黑产产品化体系。License验证逻辑用nmmp虚拟机保护——Java方法体被抽取为自定义字节码，运行时通过虚拟机解释执行，Frida无法直接hook到实现。chmp4.sh脚本AES加密存储，运行时解密执行，可以随时更新逻辑而不更新APK。被hook的函数名用逐字节XOR混淆，命令名称用push_back逐字符拼接，防止strings命令扫描。整个系统有在线授权服务器、到期时间控制、设备信息上报，是一个成熟的商业产品。



防御体系
针对这三代工具，防御也需要分层：
对第一代沙盒方案，应用层检测即可——路径检测、UID校验、调用栈检查、/proc/self/maps扫描。
对第二代Xposed方案，需要检测Xposed框架本身的特征，以及把关键验证逻辑下沉到native层，不依赖Java API返回的数据。
对第三代cameraserver注入，就需要系统级的检测了：检查cameraserver的/proc/pid/maps里有没有非系统路径的so、ServiceManager里有没有异常服务名（比如Video2CameraService）、SELinux是否处于Permissive状态、Camera3OutputStream关键函数的地址是否还在libcameraservice.so的地址范围内。同时在帧数据层面可以做统计分析，检测异常的帧重复率或时间戳规律。







## 1、andvipgroup/VCamera
 Dec 12, 2022

https://github.com/andvipgroup/VCamera?tab=readme-ov-file

原理：

使用了一个黑灰产WaxMoon/opensdk 虚拟化框架，本质上是类似 VirtualApp 的应用级沙盒技术，因此不需要root。


根据作者的介绍，opensdk的原理是：把整个“目标 App”运行在一个虚拟的运行时环境里。和老 VirtualApp、BlackBox 等同类思路，不同的是放弃了java动态代理，service、receiver、provider等Binder组件全部由MultiApp引擎自己维护。VirtualApp 类方案依赖 Java 动态代理的方案来保证虚拟进程正常运行。这样的问题是：如果被虚拟的第三方 App 也使用了 Java 动态代理，两者就会相互覆盖，导致目标 App 的运行时逻辑被意外篡改。

> Java 动态代理：Android 系统里，App 和系统服务（比如摄像头服务、Activity 管理服务）之间通过 Binder 通信。你可以把 Binder 想象成一根"电话线"，App 通过它打电话给系统服务。
Java 动态代理的作用就是：在这根电话线上接一个"中间人"，所有通话都先经过中间人，中间人可以偷听、修改、转发。
VirtualApp 就是这么干的——它在 App 和系统之间插入自己的代理，拦截所有系统调用，从而控制 App 的行为。


opensdk：在目标 App 跑起来之前，把目标app和要通信的camera server这个 service偷偷换掉，也就是确保其拿到的都是假服务的指针（native层）。同时，为了对抗 360 加固（ 360 加固会在 Native 层做反 Hook 检测），opensdk 利用bpf在系统调用入口（svc 指令）拦截，实现更加全面。


具体实现原理：

opensdk 在 attachBaseContext加载虚拟引擎HackRuntime.install();  

用 DexClassLoader 动态加载引擎moon.jar。

引擎接管后，使用 Pine（或类似 ART Hook 框架）对 Android Framework 关键部分进行 Hook。

Hook 的目标包括：

PackageManager（PMS）、ActivityManager（AMS）、文件系统相关的东西。



具体的camera service端是在virtual.camera.camera:camera:1.0.0（闭源 AAR）实现，目前没有开源，估计可以通过下载apk进行逆向来观察。


防御思路：

1、应用可以通过路径检测判断是否在沙盒运行，主动拒绝服务。

把验证逻辑放到系统服务那一侧，或者使用内核直接返回的数据，用户态沙盒就没有办法了，例如向真正的 PackageManagerService 询问当前包名对应的 UID，和 Process.myUid() 对比。

调用栈里面有没有宿主名

有没有特征文件路径

Maps 文件里是否有可疑路径

查看特定的文件路径，观察是否有异常：尝试打开某个文件或检查 /proc/self/maps、文件是否存在等，如果路径特征不对，就能判断

检查是否被hook

2、从摄像头本身以及文件的角度去出发。参数扰动：分辨率固定，切换后立刻回到原分辨率

局限性：

在安卓9之前比较好用，现在安卓系统权限更加严格，并且opensdk可能版本较早，现在已经不行了。

```
app/src/main/java/virtual/camera/app/
│
├── app/
│   ├── App.kt                    ← 应用入口，继承 HackApplication
│   └── AppManager.kt             ← SharedPreferences 管理
│
├── settings/
│   └── MethodType.java           ← 摄像头输入模式枚举（1/2/3）
│
├── bean/
│   ├── AppInfo.kt                ← 虚拟 App 数据模型
│   ├── InstalledAppBean.kt       ← 安装状态模型
│   ├── GmsBean.kt                ← GMS 包数据模型
│   └── XpModuleInfo.kt           ← Xposed 模块模型
│
├── data/
│   ├── AppsRepository.kt         ← App 发现/安装/排序（调用 HackApi）
│   ├── GmsRepository.kt          ← GMS 管理
│   └── XpRepository.kt           ← Xposed 模块管理
│
└── ...（UI/Utils 等）

opensdk/                          ← git submodule，核心虚拟化引擎
├── HackApplication.java          ← 宿主 App 必须继承的基类
├── HackApi.java                  ← 对外暴露的所有操作 API
├── HackRuntime.java              ← 引擎初始化入口
└── Cmd.java                      ← 命令分发系统
```

## 2、Xposed-Modules-Repo/com.example.vcam
Aug 13, 2021

https://github.com/Xposed-Modules-Repo/com.example.vcam

劫持原理？

需要的权限级别（root/越狱 vs. 免root方案）？

是否针对app有优化？

如何实现推流？

防御思路？


原理：

这是一个基于 Xposed/LSPosed 框架的 Android 虚拟摄像头模块，核心思想是在目标 App 的进程中拦截摄像头 API 调用，把真实摄像头画面偷偷替换成用户指定的视频文件。
模块实现 IXposedHookLoadPackage 接口，在每个被选中的目标 App 进程启动时注入。所有 Hook 均通过 XposedHelpers.findAndHookMethod() 完成

这个非常经典，它同时hook了预览流和捕获流（画面链（给人看的）或者数据链（给算法或者人脸识别用的））


针对 Camera1，主要劫持两个核心链路：画面链（Surface）和数据链（PreviewCallback / 拍照）

1、setPreviewTexture / setPreviewDisplay

作用：App 指定摄像头预览输出的目标 Surface。

Hook 行为：攻击者将 App 传入的 Surface 替换为一个自己创建的 fake SurfaceTexture。

效果：App拿不到真实画面。



2、startPreview

作用：启动摄像头预览数据流。

Hook 行为：启动 MediaPlayer、将本地视频（如 virtual.mp4）渲染到 App 原本的 Surface

效果：用户看到假视频



3、setPreviewCallback / setPreviewCallbackWithBuffer

作用：通过 onPreviewFrame(byte[] data) 向 App 提供每一帧原始数据（YUV）。

Hook 行为：拦截回调、将 data 替换为视频解码得到的假帧

效果：算法拿到假人脸数据



4、takePicture

作用：拍照并返回 JPEG 数据。

Hook 行为：替换返回的图片数据（如固定 bmp / jpeg）

效果：拍照结果假图片


Camera1 本质做了三件事：
	1.	截断真实画面（Surface）
	2.	用视频伪造显示
	3.	用视频帧伪造数据


针对camera2，hook了以下的东西
camera2稍微复杂一点，引入了 Session 和请求流（Request）


核心思路：控制所有 Surface 的流向


1、openCamera → onOpened

作用：打开摄像头，返回 CameraDevice

Hook 行为：动态 hook StateCallback.onOpened，获取 CameraDevice，为后续劫持做准备，注意：这里还没有 Session


2、createCaptureSession（核心）

作用：创建 Session，并绑定输出 Surface 列表

Camera → Surface列表

Hook 行为：将 App 提供的 Surface 列表替换为：fake Surface

效果：真实摄像头 → fake Surface → 无人消费 → 数据被丢弃

本质：截断真实数据流（画面链 + 数据链）

3、addTarget（CaptureRequest.Builder）

作用：指定每个请求的输出目标（Surface / ImageReader）

Hook 行为：记录 App 原始 Surface，替换为 fake Surface

同时：保存原始 previewSurface，用 MediaPlayer 渲染视频到该 Surface

效果：用户看到假视频

4、build / 提交请求（触发注入）

作用：正式启动数据流

Hook 行为：
画面链：MediaPlayer → 渲染到 preview Surface
数据链：使用 VideoToFrames 解码视频，转成 NV21 / JPEG，写入 ImageReader 的 Surface

效果：App 从 ImageReader 获取：假帧


视频解码管道
预览流：用系统 MediaPlayer 直接渲染到 Surface，性能最好。
捕获流（例如ImageReader）：调用自己研发的 VideoToFrames（H.264 硬解码），将每一帧解码为 NV21（YUV420sp）或 JPEG 格式，写入 ImageReader 的 Surface，这样 App 从 ImageReader.acquireLatestImage() 拿到的就是假帧。



我根据这个做了一个xposed模块，然后用在了微信上，实现实时传输，但是这个版本比较粗糙，用的是adb协议，然后数据之间是以文件的形式传递，只能够单向传递640x480像素的文件，也就是480p，后来我改成了tcp协议，能够实现4k的双向传输。


权限：
需要 root + Xposed/LSPosed 框架，属于「深度越狱」方案。具体依赖：
Android 设备已解锁 Bootloader
安装了 Magisk（root）
安装了 LSPosed 模块框架（基于 Zygisk）





不支持推流；系统相机大量使用 Native 层，也会失败；只是一个toy，对于真实的apk会遇到一些问题：native (C++) → 直接访问 camera，比如说webrtc，直接走native层

模块本身是通用的

防御方法：
1、检测xposed模块


## 3、sandyz987/XVirtualCamera
11月  2023

https://github.com/sandyz987/XVirtualCamera

本质上还是一个xposed模块。XVirtualCamera 是一个 Xposed 框架插件，其核心思想是：不替换真实摄像头驱动，而是在应用层的 Java API 调用链上做 方法 Hook（钩子），拦截目标 App 与摄像头之间的所有交互，将真实帧数据替换为解码后的视频帧。



只对白名单 App 生效，Android 9.0+，稳定优先。不支持拍照，因为没有适配，作者只关注视频流。


主要依赖了ijkplayer (FFmpeg)（HTTP/RTSP/RTMP/RTP/mp4）


共同点：

都用 ijkplayer 播放 RTMP/本地视频。
都通过 Xposed 在目标 App 进程里 Hook。
配置方式相同（stream.txt 或 virtual.mp4）。

不同点本质：

老 App（B站早期、快手、拼多多等）大量使用旧 Camera + onPreviewFrame 回调，需要“喂” YUV 数据。
新 App（抖音、WhatsApp、小米相机等）使用 Camera2 + Surface 管道，需要“偷梁换柱”把 Surface 替换/重定向。


路径 A（Surface 路径，给 Camera2 和不用 PreviewCallback 的 App）：
ijkplayer → 直接渲染 → previewSurface → App GL 消费
路径 B（PreviewCallback 路径，给用 Camera1 回调的 App）：
ijkplayer → SurfaceTexture → GL读像素 → Bitmap(ARGB) 
→ Java传入JNI → encoder.cpp ARGB转NV21 
→ 填入被Hook的onPreviewFrame byte[]回调 → App拿到假帧




优点在于：替换更加简单，在 createCaptureSession 里直接替换 outputSurface 列表，ijkplayer 渲染到原始 Surface，利用了ijkplayer，能够支持推流等所有的流媒体协议，把帧直接渲染到 Surface。

具体实现：

android_virtual_cam 的策略是"多点散布式拦截"。它同时 Hook 了十几个方法：Camera.setPreviewTexture、Camera.setPreviewDisplay、Camera.startPreview、Camera.setPreviewCallbackWithBuffer、Camera.addCallbackBuffer、Camera.takePicture、CameraManager.openCamera（两个签名）、CaptureRequest.Builder.addTarget、CaptureRequest.Builder.removeTarget、CaptureRequest.Builder.build，以及所有六种 createCaptureSession 变体。这种方式覆盖面广，但逻辑散乱。


XVirtualCamera 的策略是"纵向链式拦截"。它主要抓住两个关键节点：openCamera 和 CaptureRequest.Builder.build。在 openCamera 时替换整个 StateCallback，再在 onOpened 回调中 Hook CameraDevice 实例的 createCaptureSession，最后在 session 回调的 onConfigured 里启动 ijkplayer 渲染。在 createCaptureSession 时，直接把 outputSurface 列表替换掉，让相机 session 直接建立到 ijkplayer 解码输出的 Surface 上。App 拿到的 Surface 本身就是视频输出的 Surface，不需要两套渲染管线并行。这少了一个中间层，减少了帧同步问题。


android_virtual_cam 在 Camera2 路径下使用了自研的 VideoToFrames 类（基于 MediaCodec 硬解），将每一帧解码为 NV21 或 JPEG 格式，再通过 ImageWriter 写入 ImageReader 的 Surface。这对于拍照场景（需要 YUV 原始帧）是必要的，但对于流媒体协议完全无能为力，只能播放本地 mp4。
XVirtualCamera 引入了 bilibili/ijkplayer，这一步是质的升级。ijkplayer 基于 FFmpeg，天然支持 HTTP、RTSP、RTMP、RTP 等几乎所有流媒体协议，可以直接拉取 OBS 推出的 RTMP 流，延迟约 2~3 秒。但代价是放弃了逐帧的 YUV 控制权——ijkplayer 把帧直接渲染到 Surface，无法像 VideoToFrames 那样拦截每一帧做格式转换或注入 ImageReader，所以拍照功能的替换相对弱。



对这些软件有特别的优化：
1、拼多多、抖音、微信视频号、快手



优化：
app/src/main/jni/ 目录下 encoder.cpp、utils.c、utils.h 这些文件的作用，他们做了颜色空间转换（ARGB → YUV420SP）
 ijkplayer 的解码输出是 Surface，把这个 ARGB byte[] 传给 JNI 的 encoder.cpp 做颜色空间转换，需要转成 NV21（即 YUV420SP），填进 Hook 住的 onPreviewFrame 回调的 data 参数里



我的评价：

他只是将surface直接交给ijkplayer 渲染，而不是以帧级别进行hook，所以说完全由ijkplayer来控制，分辨率什么的都是依赖于ijkplayer。Surface 级别的替换本质上是把"水管接口"换了，管道里流什么完全交给 ijkplayer 决定，插件自己对帧内容毫无控制权，分辨率、格式、帧率全是 ijkplayer 的输出结果。


ijkplayer 是 bilibili（哔哩哔哩）开源 的一个跨平台视频播放器框架（Android + iOS），底层完全基于 FFmpeg（业界最强大的音视频处理库），支持很多协议，并且支持 MediaCodec（Android 硬件解码），性能极高。这里面真正的解码、协议解析、帧生成全部跑在 native 层（编译成 .so 动态库）。




这个项目我曾经也花了大量的时间去尝试，想要采用rtmp的方法，做了很多的尝试，包括但不限于尝试轻量级的rtmp服务器，使用简单的参数传递帧，并且也用过这个ijkplayer，但是发现还是有0.5s以上的延迟，这个主要开销难以解决，主要也是想提供一个全新的黑灰产手段。基本上开销都是花在这个视频的编码和解码上。



## 4、sudami/com.wangyiheng.vcamsx

11月  2023


可以利用元萝卜实现免root iiheng/vcamsx

https://github.com/sudami/com.wangyiheng.vcamsx


这个版本不如3，是在2 com.example.vcam上面的开发。VCAMSX 是一个基于 LSPosed/Xposed 框架的 Android 虚拟摄像头模块，用 Kotlin 编写。

<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260331193211.png" alt="20260331193211" /></p>


Android 内置的 MediaPlayer + VideoToFrames（基于 MediaCodec 的硬解）。MediaPlayer 协议支持极其有限，对 RTMP/RTSP 的支持依赖厂商实现，质量参差不齐。
VCAMSX 使用的是引入 ExoPlayer 替代 MediaPlayer，带来格式兼容性更广和软/硬解切换能力，并且存在Surface 生命周期和 ExoPlayer 的异步 buffer 之间存在竞态，会导致花瓶、黑屏、crash



XVirtualCamera 引入了 bilibili/ijkplayer 作为播放器内核。ijkplayer 底层是 FFmpeg，支持几乎所有流媒体协议——http、rtsp、rtmp、rtp——并且同样支持硬解（MediaCodec）和软解（FFmpeg 软解码）。这让 XVirtualCamera 的网络流支持质量从根本上高了一个层级。
ijkplayer 接入虚拟摄像头的方式和 MediaPlayer 类似：用 IjkMediaPlayer.setSurface(fakeSurface) 把解码输出渲染到虚拟 Surface 上，再注入给目标 App。关键区别是 ijkplayer 的 setDataSource() 可以接受任意 URL，包括 rtmp://、rtsp://、http://，而且内部有完整的缓冲和重连机制，不像 MediaPlayer 那样脆。


VCAMSX 则通过 LSPosed Scope 把作用域决定权交给用户，理论上可以对任意 App 生效，但遇到不兼容的 App 可能黑屏或崩溃。



com.example.vcam 意识到 Android 不同版本引入了不同的 createCaptureSession API，VCAMSX 同样实现了全部覆盖，VCAMSX hook了更多的函数，确保都能hook上

createCaptureSession(List, StateCallback, Handler) — 基础版本
createCaptureSessionByOutputConfigurations — Android N+，使用 OutputConfiguration
createConstrainedHighSpeedCaptureSession — 高速摄像
createReprocessableCaptureSession — 可复处理会话（Android M+）
createReprocessableCaptureSessionByConfigurations — Android N+
createCaptureSession(SessionConfiguration) — Android P+ 统一接口


更加零碎的改进：
1、VCAMSX 做了更完整的适配：在 callApplicationOnCreate 的 Hook 里，检查权限状态（同时检查 READ_EXTERNAL_STORAGE 和 Android 11 的 MANAGE_EXTERNAL_STORAGE），如果没有权限或存在 private_dir.jpg 强制标志文件，自动把视频路径切换到 App 的私有目录 getExternalFilesDir(null)/Camera1/（这个路径不需要额外权限），并创建目录、写入已提示标志文件避免重复弹 Toast。这个设计让 VCAMSX 在不授权的情况下也能工作，只是每个 App 用各自私有目录。

2、语言迁移到 Kotlin、提供完整的用户界面，更加产品化，做了很多工程化封装
但 Kotlin 的改写带来了更清晰的代码组织。不过从 README 来看，VCAMSX 更大的贡献是把 Hook 代码（来源于 com.example.vcam）和一个完整的用户界面 App 结合起来，提供视频选择、开关控制、解码方式切换（硬解/软解）等交互功能，这是前两个工具完全缺失的部分。前两个工具本质上是"放个文件进去就生效"的黑盒方案，VCAMSX 则是一个完整的产品化工具。

3、MediaPlayer 对 RTMP 的延迟和断线重连支持较弱，相比专用的 RTMP 客户端库更脆。

总结：VCAMSX 则是在这套成熟技术上做了工程化封装，加入了 Android 11 权限适配、Kotlin 重写、完整 App UI 和实验性 RTMP 支持，让普通用户可以使用，而不只是面向开发者的 PoC。本项目针对 Android 14 的相机权限变更、API 限制、进程隔离机制做了适配，支持最新的系统版本。




## 5、xiaobutiaoer/VCAMPRO（黑产）
2024年 10月10日
https://github.com/xiaobutiaoer/VCAMPRO/tree/master/app/release

两个项目均采用 100% Kotlin 开发，VCAMPRO 完整继承了 vcamsx 的代码架构，核心优化集中在功能实现与适配层，未做底层架构的重构，核心定位是 vcamsx 的 “兼容性与稳定性增强版”。











## 6、https://vcames.xyz 售卖的，这个版本高明，是VCAMMAX_1.1.3的后续

这款软件（包名：com.nvshen.chmp4）属于典型的商业化黑灰产工具，具备完善的产品形态与运营体系。其界面设计成熟，用户体验友好，拥有一定规模的用户群体及售后支持体系。
从实现层面来看，该软件集成了多种商业化特征，包括在线授权机制（如到期时间控制、使用次数限制）、内置 APK 热更新能力，以及基于 xnxi.xyz 的核心服务端与 vcames.xyz 的分发/售卖渠道。

包名伪装：该应用将包名伪装成 com.telegram.a1064，欺骗用户和安全检测工具，实际与 Telegram 无任何关联。

核心服务器https://xnxi.xyz

需要的权限：
CAMERA、ACCESS_FINE_LOCATION（GPS 位置）
INTERNET、READ/WRITE_EXTERNAL_STORAGE
SYSTEM_ALERT_WINDOW（悬浮窗）
READ_MEDIA_VIDEO、ACCESS_NETWORK_STATE


<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260401203719.png" alt="20260401203719" width="50%"/></p>



#### 整体架构
整个系统由五个核心组件协同工作，分布于 Java 层与 Native 层：
<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260401203811.png" alt="20260401203811" width="50%"/></p>



#### 完整的架构图
<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260401201009.png" alt="20260401201009" width="40%"/></p>


启动流程（从上到下）

libnmmp.so 解密 chmp4.sh，通过 root shell 执行 sh chmp4.sh initchmp4 W H /path/to.mp4 ...
chmp4.sh 把 libshadowhook、libhookProxy、libCHMP4 复制到 /data/camera/，然后分两路启动：

路线 A（推流进程）：启动 CHMP4-1364 play，FFmpeg 开始解码视频，解码帧持续写入全局 FrameBuffer，同时注册 Video2CameraService 到 Android ServiceManager，等待取帧请求。


路线 B（注入路线）：启动 CHMP4-1364 inject <cameraserver_pid>，通过 ptrace 把 libhookProxy.so 注入进 cameraserver。libhookProxy 被 dlopen 后 .init_array 自动触发 autoRunFunc()，按顺序 dlopen libshadowhook → dlopen libCHMP4 → dlsym main_hook → 调用，9 个 camera hook 全部安装完毕，ptrace detach。

运行时帧替换
cameraserver 内部的 libCHMP4.so 拦截 Camera3OutputStream::returnBufferCheckedLocked，在帧即将返回给 App 前：通过 Binder 向 Video2CameraService 发取帧请求，拿到 FrameBuffer 里的视频帧，格式转换（I420 → NV21/NV12/JPEG 等）后直接写入 GraphicBuffer，微信等 App 读到的就是这一帧假的摄像头画面。



#### apk文件结构

```
assets/
├── sh                          # 精简版 BusyBox shell 可执行文件
├── chmp4.sh                    # 核心 shell 脚本（AES 加密，运行时解密执行）
├── bin/                        # 32位 ARM 组件
│   ├── CHMP4-1032              # 注入器主程序（32位）
│   ├── libCHMP4-1032.so        # Camera hook 实现（32位）
│   ├── libhookProxy-1032.so    # 注入代理（32位）
│   └── libshadowhook-1032.so   # PLT/Inline hook 框架（32位）
└── bin64/                      # 64位 ARM 组件
    ├── CHMP4-1364              # 注入器主程序（64位，含 FFmpeg）
    ├── libCHMP4-1364.so        # Camera hook 实现（64位）
    ├── libhookProxy-1364.so    # 注入代理（64位）
    └── libshadowhook-1364.so   # PLT/Inline hook 框架（64位）

lib/arm64-v8a/
├── libnmmp.so                  # Java 代码保护壳（nmmp）
└── libnmmvm.so                 # nmmp 虚拟机解释器

```


#### Java层分析



Java 层关键的业务逻辑（包括 onClick、onCreate、onResume 等）（在线 License 验证，联网验证授权 token）均被 nmmp 壳保护，方法体被抽取为字节码存入 libnmmp.so 的 .rodata 段，运行时通过虚拟机解释执行。


MyApplication — 应用入口
```
// com.nvshen.chmp4.MyApplication
public class MyApplication extends Application {
    static {
        NativeUtil.classesInit0(40);  // 触发 nmmp 初始化，注册所有 native 方法
    }
    @Override
    public native void onCreate();   // 实现在 libnmmp.so 字节码中
}
```

SplashActivity — Root 检测 + SELinux 关闭

SplashActivity 是应用启动时执行的第一个 Activity，完成 Root 权限获取和 SELinux 临时关闭。以下为 nmmp 保护之外可直接分析的代码：
```
// com.nvshen.chmp4.SplashActivity
// 关键方法 m4539J() — Root Shell 建立完成后的回调
public void m4539J(AbstractC1084b abstractC1084b) {
    if (!abstractC1084b.m7362M()) {   // 检查 Root Shell 是否可用
        m4542M();                      // 无 Root 则提示并退出
        return;
    }
    // 检查当前 SELinux 状态
    if (AbstractC1084b.m7356I("getenforce")
            .mo7369i().mo7372c().contains("Enforcing")) {
        // 临时关闭 SELinux
        AbstractC1084b.m7356I("setenforce 0").mo7369i();
        // 验证关闭是否成功
        if (AbstractC1084b.m7356I("getenforce")
                .mo7369i().mo7372c().contains("Permissive")) {
            AbstractC1084b.m7356I("setenforce 1").mo7369i(); // 测试后恢复
        } else {
            Log.e("HOOK", "setenforce 0 fail!");
        }
    }
    startActivity(new Intent(this, MainActivity.class));
    finish();
}
```
setenforce 0 将 SELinux 从 Enforcing 模式切换到 Permissive 模式，这是 ptrace 跨进程注入的必要前提。注入完成后，CHMP4-1364 会在 ptrace detach 后 sleep(5) 再恢复 SELinux（setenforce 1）。



Root Shell 建立（libsu 库）

应用使用开源库 libsu 建立持久化 Root Shell，核心流程如下：

```
// libsu 库（未被 nmmp 保护，直接可见）

// Step 1: 在 PATH 中查找 su 可执行文件
// C1126w.m7528f() — 遍历 PATH 环境变量中的目录，查找 su
public static File m7528f() {
    for (String path : System.getenv("PATH").split(":")) {
        File su = new File(path, "su");
        if (su.exists()) return su;
    }
    return null;
}

// Step 2: C1104a.m7479d() — 尝试建立 Root Shell，优先级降序
// 尝试顺序: "su --mount-master" → "su" → "sh"

// Step 3: C1119p.m7514R() — 验证 Shell 是否具有 Root 权限
// 检查条件: uid == 0 且 mount namespace 与 init 进程相同
// /proc/self/ns/mnt == /proc/1/ns/mnt

```


C0531d — License 管理核心

```
// com.nvshen.chmp4.C0531d（License 管理，全部 native）
public class C0531d {
    // 授权服务器地址
    private String[] f4081n = {"https://xnxi.xyz", "https://xnxi.xyz"};
    private String f4074g = "";    // token
    private long   f4072e = 0;    // expiredTime
    private int    f4071d = -1;   // remain（剩余天数）

    // 关键方法（实现在 libnmmp.so 字节码中，Frida 无法直接 hook 实现）
    public static native C0531d m4544B();          // 获取单例
    public native void   m4575a0();                // 还原相机（resetCamera）
    public native void   m4582k(str, str, h);      // 初始化相机（initchmp4）
    public native void   m4577f(str, callback);    // 激活码验证
    public native long   m4593v();                 // 获取到期时间戳
    public native String m4557C();                 // 获取 token

    // License 验证响应处理（nmmp 保护外，可直接分析）
    public void m4545H(f callback, int code, String json) throws JSONException {
        if (code == 200) {
            JSONObject obj = new JSONObject(json);
            if (obj.getInt("code") == 200) {
                this.f4071d = obj.optInt("remain");
                this.f4073f = obj.optInt("now");
                this.f4074g = obj.optString("token");
                this.f4072e = obj.optLong("expiredTime", 0L);
            }
        }
    }
}
```


C0538k — Binder 服务管理

```
// com.nvshen.chmp4.C0538k — App 侧 Binder 客户端
public class C0538k {
    BinderC0536i f4112c = new BinderC0536i();  // 自定义 Binder 实现

    // 全部 native（nmmp 保护）
    public native IBinder m4612b();   // 获取/建立 Binder 连接
    public native int     m4613d();   // 获取连接状态
}

// BinderC0536i — 自定义 Binder 实现
class BinderC0536i extends Binder {
    @Override
    // onTransact 在 libnmmp.so 字节码中实现
    // 处理来自 cameraserver 的 Binder 调用
    protected native boolean onTransact(int code, Parcel data,
                                        Parcel reply, int flags);
}
```

```
javaclass C0538k {
    private IBinder f4110a;      // 目标进程的 Binder 句柄
    BinderC0536i f4112c;         // 自己的 Binder（作为服务端）
    
    // onTransact() → 全部 native 实现（在 libnmmp.so 中）
    // 支持：getCameraList、getCameraId、getCameraInfo 等操作
    m4614e(IBinder)   // 通过 Binder 传入远端句柄后获取信息
    m4617i(int)       // 整型参数的相机操作
    m4618j(int)       // 获取相机标识字符串
    m4619k(int)       // 获取相机属性
    m4620l()          // 获取相机数量
}
```





#### libnmmp.so + libnmmvm.so — Java 代码保护虚拟机

这两个 so 构成了 nmmp 保护系统的核心，属于商业代码保护方案）。

工作原理
```
Java 调用 NativeUtil.classesInit0(22)
        ↓ JNI
libnmmp.so::sub_E8D8(env, cls, classIdx=22)
        ↓
从 .rodata 段取 index=22 对应的加密字节码块
        ↓
调用 libnmmvm.so::vmInterpret(bytecode, env, ...)
        ↓ 字节码执行
RegisterNatives(C0531d, methods[])   ← 动态注册所有 native 方法
        ↓
后续每次调用 C0531d 的 native 方法 → 再次进入 vmInterpret 解释执行

```

libnmmp.so 关键结构
<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260401204618.png" alt="20260401204618" width="50%"/></p>




libnmmvm.so — 字节码解释器
```
// libnmmvm.so 导出的核心函数
void vmInterpret(uint8_t* bytecode, JNIEnv* env, jobject thiz, ...);

// 指令格式：4字节固定长度
// [opcode:1byte] [reg:1byte] [imm_lo:1byte] [imm_hi:1byte]

// 其他导出
void   cacheInitial(JNIEnv* env);     // 预缓存 java/lang 基础类型
jclass getCacheClass(char typeChar);  // 按类型符(B/C/D/F/I/J/S/Z)返回缓存 jclass
// ARM32 实现：MOV PC, R0 跳转执行
```

> **被 nmmp 保护的核心逻辑**：License 验证与存储、token/expiredTime 管理、激活码校验算法、Shell 命令构建与执行、Binder `onTransact` 处理。这些逻辑通过 VM 字节码执行，Frida 无法直接 hook 到具体实现。VM 保护的核心目标不是保护 camera hook 实现，而是保护 License 验证逻辑不被 Frida 轻易 hook 绕过。 这是 nmmp 这类壳最典型的使用场景——保护商业授权代码而不是功能代码。





NativeUtil.classesInit0(22)调用流程：
```
Java 调用 NativeUtil.classesInit0(22)
    ↓
JNI 调用 libnmmp.so 里的 sub_E8D8（已注册为 classesInit0 的实现）
    ↓
sub_E8D8(JNIEnv*, jclass, jint classIdx=22)
    ↓
从 .rodata 段的字节码表里，找到 index=22 对应的字节码块
    ↓
调用 vmInterpret(bytecodPtr, JNIEnv*, ...) 执行这段字节码
    ↓
字节码的执行效果：用 JNI 的 RegisterNatives 动态注册 C0531d 的所有 native 方法
关键一步是动态注册。字节码执行完之后，C0531d 的所有 native 方法就被注册到了对应的函数指针上——但这些函数指针指向的不是普通 C 函数，而是每次都会重新进入 vmInterpret 的入口。


从之前分析 libnmmvm.so 的结果，vmInterpret 的核心：
libnmmvm.so 导出

void vmInterpret(uint8_t* bytecode, JNIEnv* env, jobject thiz, ...) {
    // 读取 bytecode 流，逐条解释执行
    // 每条指令 4 字节：[opcode][reg][imm_lo][imm_hi]
    // 支持 JNI 调用、字段读写、方法调用等操作
}
```









#### CHMP4-1364	— ptrace 注入器与推流主程序
CHMP4-1364 是 64 位 ARM ELF 可执行文件，无壳保护，`.text` 段约 12MB（内嵌完整 FFmpeg 静态库）。

如何进行推流，视频解码？他们直接把 ffplay 的源代码 拷进来编译进去了，是 FFmpeg 的完整嵌入。

这个程序CHMP4-1364，没有混淆，我们通过比对 strcmp 的字符串，还原了完整的命令行接口：
```
CHMP4-1364 <命令> [参数...]

命令列表（通过 push_back 逐字符构建字符串，防止静态分析）：
  ac         → 检查文件是否存在（stat）
  selinux    → 查询/控制 SELinux 状态
  curl       → HTTP 请求（访问 https://xnxi.xyz/camera/refresh 上报设备信息）
  test       → 测试模式（需要 PID 参数）
  play       → 播放模式（ffplay 风格，>9个参数）→ 核心功能
  ffplay     → 同上
  inject     → 注入模式 → 调用 sub_3831F0
```

ptrace 注入实现（sub_382750）
```
// sub_382750 
sub_382750 是 ptrace 注入器，流程如下：
1. 读取 /proc/self/exe 判断自身是 32/64位
2. sub_381B14(pid) 判断目标进程位数
3. ptrace(PTRACE_ATTACH, pid) 附加目标进程
4. waitpid 等待暂停
5. ptrace(PTRACE_GETREGSET) 保存寄存器
6. sub_3819C8 在 /proc/pid/maps 中找 libc.so 的基址
7. 计算目标进程中 mmap 函数地址
8. sub_382408 远程调用 mmap → 在目标进程中分配内存
9. 把 libCHMP4-1364.so 路径写入目标内存
10. 远程调用 dlopen → 加载 libCHMP4-1364.so
11. 远程调用 dlsym → 找到入口函数
12. 远程调用入口函数 → 激活 hook
13. 恢复寄存器
14. ptrace(PTRACE_DETACH) 分离
15. 如果 SELinux 是 Enforcing，sleep(5) 后恢复
```


Binder 服务注册（sub_FE7024）
```
Video2CameraService 和 CHMP4PlayerService
Video2CameraService  (字符串 0x2093c)  → 注册到 ServiceManager，供目标 App 查找
CHMP4PlayerService   (字符串 0xc4f0c)  → 播放器服务名称
vediocameraclient    (字符串 0xc4ef0)  → 客户端标识（拼写错误：vedeo→video）
libcamera_client.so  (字符串 0x6b5e)  → hook 的目标库
Binder 的实际作用：CHMP4-1364 把自己注册为 Video2CameraService，libCHMP4-1364.so 注入进 cameraserver 后，hook 了 libcamera_client.so 里的关键函数，当目标 App 请求摄像头帧时，hook 函数通过 Binder 向 Video2CameraService 获取解码好的视频帧，再返回给目标 App。

License 时间验证（sub_FE691C）
sub_FE691C(100, 200) 返回 300 → 这是授权验证函数，检查 License 是否有效
验证通过后 sub_FE6F3C(sub_385770) 启动推流线程（FFmpeg 解码）
```
FFmpeg 推流（sub_388824）
```
play/ffplay 模式：向 Binder 服务推送视频帧
sub_FE6DDC 是 play 命令的核心，参数包括：
参数含义v93（宽度）视频宽度v94（高度）视频高度&v131（路径）mp4 文件路径v104（token）授权 tokenv105（设备ID）目标设备ID


sub_388824 就是 ffplay 模式的核心，里面的调用非常清晰：
c// 这些都是 FFmpeg 内部函数，直接调用，不走命令行
sub_D83594()   // 对应 FFmpeg 内部的 stream_open()
sub_D836F8(a1) // 对应 avformat_open_input()，a1 就是视频文件路径或流地址
sub_38AE0C     // read_thread 线程（FFmpeg 的读帧线程）
sub_D99554()   // av_gettime_relative()
sub_390A6C()   // SDL_CreateThread() - FFmpeg 的播放循环
```

完整的视频帧流转路径
```
输入源（mp4 文件 / rtmp 流 / rtsp 流）
      ↓
  FFmpeg avformat_open_input()   ← 打开视频源
      ↓
  av_read_frame()                ← 读取压缩数据包
      ↓
  avcodec_decode / send_packet   ← 解码成原始 YUV 帧
      ↓
  sws_scale()                    ← 颜色空间转换（YUV → RGB 或 NV21）
      ↓
  写入共享内存（MemoryHeapBase）  ← 存放解码好的帧
      ↓
  Binder 通知 libCHMP4-1364.so   ← "新帧来了，快来取"
      ↓
  hook 函数把帧塞进 cameraserver 的输出 buffer
```






#### libshadowhook-1364.so
这是字节跳动开源的 ShadowHook 框架，纯工具库，不包含任何业务逻辑。它提供两种 hook 方式：PLT Hook：修改 .got.plt 表里的函数指针，拦截通过动态链接调用的函数。Inline Hook：直接在目标函数的机器码开头写入跳转指令，适合 hook 任意位置.

```
// shadowhook 核心 API（libCHMP4 调用）

// 初始化
shadowhook_init(SHADOWHOOK_MODE_UNIQUE, NULL);

// 按符号名安装 hook（运行时在目标 so 中查找符号地址）
void* stub = shadowhook_hook_sym_name(
    "libcameraservice.so",            // 目标 so 名称
    "_ZN7android13Camera3Device...",  // C++ mangled 符号名（运行时解密）
    (void*)our_hook_func,             // hook 函数指针
    (void**)&original_func_ptr        // 保存原始函数地址
);

// hook 函数内调用原始实现（透明 hook，不影响 cameraserver 正常运行）
void Camera3OutputStream_returnBufferCheckedLocked_hook(...) {
    replaceFrame(binder, width, height, format, stride, buffer);
    // 调用原始函数，保持 cameraserver 内部状态机正常
    original_returnBufferCheckedLocked(a1, a2, a3, a4, a5, a6);
}
```







#### libCHMP4-1364.so

libCHMP4-1364.so 运行在 cameraserver 进程内部，覆盖了 Camera1 / Camera2 / Camera3 三代 Android 摄像头 API。

<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/!%5B%5D(image-2.png).png" alt="![](image-2.png)" width= "50%"/></p>

hook安装
```
// 0x1784c — initCameraHook()
__int64 initCameraHook(void) {
    pthread_mutex_init(&stru_8BDA0, NULL);
    l1l1l1l1ll1ll1();   // 初始化帧缓冲区和全局状态

    // 初始化 ShadowHook
    if (shadowhook_init(SHADOWHOOK_MODE_UNIQUE, NULL) != 0) {
        return 1;
    }

    // 所有函数名通过 EncryptedString 运行时解密（XOR 混淆）
    // 安装 9 个 hook：
    shadowhook_hook_sym_name("libcameraservice.so",
        "_ZN7android17CameraThreadState13getCallingUidEv",
        CameraThreadState_getCallingUid_hook, ...);

    shadowhook_hook_sym_name("libcameraservice.so",
        "_ZN7android12CameraClient12dataCallbackE...",
        CameraClient_dataCallback_hook, ...);

    shadowhook_hook_sym_name("libcameraservice.so",
        "_ZN7android24CameraHardwareInterface16setPreviewWindowE...",
        CameraHardwareInterface_setPreviewWindow_hook, ...);

    // ... 以及另外 6 个 hook（见下表）
    return 0;
}
```



替换核心：以这个函数Camera3OutputStream_returnBufferCheckedLocked_hook — Camera3 的帧缓冲区返回拦截，是最核心的
为例
```
// 先把 FrameBuffer 里的 I420 数据
// 缩放/裁剪到目标 buffer 的尺寸
convert_I420_with_cropping_and_scaling(
    src_i420_data,   // 源：从 FrameBuffer 取出的视频帧
    src_width,
    src_height,
    src_stride,
    temp_buffer,     // 中间 buffer
    dst_width,       // 目标宽度（cameraserver 请求的）
    dst_height,      // 目标高度
    dst_stride
);

// 然后转换格式写入目标 buffer（直接覆盖 cameraserver 的原始帧）
I420ToNV21(
    temp_buffer,          // 源 I420
    ...
    dst_buffer,           // ← 直接写入这里！这就是 cameraserver 准备给 App 的帧
    ...
    dst_width,
    dst_height
);
```


这是整个方案最关键的函数，Camera3OutputStream 的 hook 每次被触发时调用此函数：
```
// 0x1d4f8 — replaceFrame()（函数名被混淆为 l1l1l1l1ll1）
int replaceFrame(
    void** binder_service,   // Binder 服务对象
    int    dst_width,        // 目标 buffer 宽度（来自 cameraserver）
    int    dst_height,       // 目标 buffer 高度
    int    pixel_format,     // HAL 像素格式枚举
    int    stride,           // 行步长
    void** dst_buffer,       // 目标 GraphicBuffer 指针（直接写入此处！）
    size_t jpeg_max_size     // JPEG 模式最大大小
) {
    // 1. 暂停 flag 检查
    if (dword_8BE88) return 1;
    ++dword_8BE8C;  // 帧计数器

    // 2. License 时间校验（过期则黑屏！）
    time_t now = time(NULL);
    if (now - license_start < 0 ||
        license_end < license_remaining + now - license_start) {
        memset(dst_buffer, 0, dst_height * dst_width);  // 黑屏
        return 1;
    }

    // 3. 从全局 FrameBuffer 克隆当前视频帧
    pthread_mutex_lock(&mutex);
    FrameBuffer* src = FrameBuffer::clone(&g_frameBuffer);
    pthread_mutex_unlock(&mutex);

    // 4. 根据 HAL 像素格式转换并写入目标 buffer
    switch (pixel_format) {
        case 0x11:  // HAL_PIXEL_FORMAT_YCrCb_420_SP (NV21，最常见)
            convert_I420_with_cropping_and_scaling(src->data, ...);
            I420ToNV21(temp, ..., dst_buffer, dst_width, dst_height);
            break;

        case 0x22:  // HAL_PIXEL_FORMAT_YCbCr_420_888 (NV12)
            I420ToNV12(src->data, ..., dst_buffer, ...);
            break;

        case 0x21:  // HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED (JPEG)
            // I420 → RGB24 → libjpeg-turbo 压缩 → 写入 dst_buffer
            I420ToRAW(temp, ..., rgb_buf, ...);
            rgb24ToJpg(rgb_buf, w, h, quality, &jpeg_data, &jpeg_size);
            memcpy(dst_buffer, jpeg_data, jpeg_size);
            break;

        case 0x7FA30C03:  // UBWC（高通专有压缩格式）
            // 经过 AMediaCodec 硬件编解码转换后 I420ToNV12
            AMediaCodec_queueInputBuffer(...);
            AMediaCodec_dequeueOutputBuffer(...);
            I420ToNV12(decoded, ..., dst_buffer, ...);
            break;

        case 0x32315659:  // YV12 fourcc
            I420Scale(src->data, ..., dst_buffer, ...);
            break;
    }
    return 0;
}
```




#### libhookProxy-1364.so
注入代理。


cameraserver 最后里面会有两个关键的 so，libshadowhook.so、libCHMP4.so。必须严格先加载 libshadowhook.so，再加载 libCHMP4.so，否则 CHMP4 里面的 hook 会失败。因为 ptrace 远程 dlopen 一次只能加载一个 so，无法控制顺序，所以需要 libhookProxy-1364.so 做“代理”，先让CHMP4-1364通过 ptrace 注入libhookProxy-1364.so，然后libhookProxy-1364.so再加载libshadowhook.so和libCHMP4.so，最后调用main_hook



<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260401173847.png" alt="20260401173847" width="50%"/></p>



用 libhookProxy 的真实原因是工程权衡：首先，ptrace 远程调用期间 cameraserver 完全暂停，dlopen 的初始化代码如果内部有锁或异步等待就会死锁，而 libCHMP4 初始化比较复杂，风险更高。其次，把加载顺序、错误处理、初始化逻辑全部封装在 proxy 里，注入器本身就变得极简，只需要 dlopen 一个文件就完成所有工作。第三，解耦了注入器和业务逻辑——注入器不需要了解 libCHMP4 依赖什么，proxy 承担了这层知识。一句话：libhookProxy 是把多步初始化问题从 ptrace 层移到 so 内部，让整个注入流程更可靠。

```
// 0x1014 — autoRunFunc()
// 通过 .init_array 机制在 dlopen 时自动执行，无需显式调用
__int64 autoRunFunc(void) {
    // Step 1: 先加载 libshadowhook（libCHMP4 的依赖，顺序不能错）
    dlopen("/data/camera/libshadowhook.so", RTLD_GLOBAL);
    if (dlerror()) return -1;

    // Step 2: 加载 libCHMP4（此时 shadowhook 已就绪）
    void* handle = dlopen("/data/camera/libCHMP4.so", RTLD_GLOBAL);
    if (dlerror() || !handle) return -1;

    // Step 3: 调用 main_hook 激活所有 camera hook
    void (*entry)() = dlsym(handle, "main_hook");
    if (!dlerror()) {
        entry();   // → initCameraHook()，安装 9 个 hook
        return 0;
    }
    return -1;
}

// 关键：autoRunFunc 挂载在 .init_array
// 因此 ptrace 调用 dlopen("libhookProxy") 返回后
// 所有 hook 已安装完毕，不需要额外的 dlsym+调用步骤
```




#### chmp4.sh
乱码，只有动态运行时才能被解码

shell 脚本在运行时才解析，不需要重新编译 APK。chmp4.sh 加密存储，运行时解密执行，可以随时更新逻辑而不更新 APK——绕过应用市场审核。根据 libnmmp.so .rodata 字符串池（byte_19BC）推断的脚本功能.


1. checkSu           → 检查 root 权限
2. chmod +x/chmod 777 %s/sh  → 给 sh 赋执行权限
3. sh %s/chmp4.sh initchmp4 %d %d %s %s %s
   参数：宽、高、视频路径、设备路径等
4. sh %s/chmp4.sh resetCamera  → 完成后重置
5. sh %s/chmp4.sh getDeviceId  → 查询设备信息






### 完整调用链

```
阶段 1 — 启动与权限获取
─────────────────────────────────────────────────────
App 启动
  → MyApplication.onCreate()（nmmp 字节码）
  → SplashActivity.onCreate()（nmmp 字节码）
  → libsu: C1126w.m7528f() → 遍历 PATH 查找 su 可执行文件
  → libsu: C1104a.m7479d() → 尝试 "su --mount-master" → "su" → "sh"
  → libsu: C1119p.m7514R() → 验证 uid==0 且 namespace 匹配
  → SplashActivity.m4539J() → 执行 "setenforce 0"（关闭 SELinux）
  → 进入 MainActivity

阶段 2 — 在线 License 验证
─────────────────────────────────────────────────────
  → C0531d（nmmp 字节码）向 https://xnxi.xyz 发送验证请求
  → 响应解析：token、expiredTime、remain
  → CHMP4-1364 curl https://xnxi.xyz/camera/refresh
       上报：serialno（ro.serialno）、deviceId

阶段 3 — 替换摄像头（用户点击"替换相机"）
─────────────────────────────────────────────────────
  → C0531d.m4582k()（nmmp 字节码）
  → 解密 chmp4.sh → 写入 App 私有目录
  → 执行 Shell 命令：
       {su} {app_dir}/sh {app_dir}/chmp4.sh initchmp4 {W} {H} {path} {id} {fmt}
  → chmp4.sh 复制组件到 /data/camera/
  → CHMP4-1364 play 启动（注册 Video2CameraService）
  → CHMP4-1364 inject <cameraserver_pid> libhookProxy-1364.so ""
       → ptrace(PTRACE_ATTACH, cameraserver_pid)
       → 远程调用 mmap() 申请内存
       → 远程调用 dlopen("libhookProxy-1364.so")
           ↳ .init_array 自动触发 autoRunFunc()
               → dlopen("libshadowhook.so")
               → dlopen("libCHMP4.so")
               → dlsym(handle, "main_hook")
               → main_hook() → initCameraHook()
                   → shadowhook_hook_sym_name × 9（安装所有 hook）
       → ptrace(PTRACE_DETACH, cameraserver_pid)
       → sleep(5) → setenforce 1（恢复 SELinux）

阶段 4 — 持续推流
─────────────────────────────────────────────────────
  CHMP4-1364 主进程：
    FFmpeg 持续解码视频帧 → 写入全局 FrameBuffer

  cameraserver 进程（libCHMP4 注入后）：
    Camera3OutputStream::returnBufferCheckedLocked 被触发
    → hook 拦截
    → GraphicBuffer::lock() 获取帧 buffer 写指针
    → replaceFrame():
        License 时间校验（过期 → memset 0 黑屏）
        FrameBuffer::clone() 取当前视频帧
        I420ToNV21/NV12/JPEG 格式转换
        直接写入 dst_buffer
    → GraphicBuffer::unlock()
    → 调用原始函数（保持正常流程）
    → 目标 App 收到假帧，完全不知情

阶段 5 — 还原摄像头（用户点击"还原相机"）
─────────────────────────────────────────────────────
  → C0531d.m4575a0()（nmmp 字节码）
  → 执行：sh chmp4.sh resetCamera
  → CHMP4-1364 卸载所有 hook，恢复 ANativeWindow 函数指针
  → pkill CHMP4-1364
  → cameraserver 恢复正常
```




### 视频帧数据流

```
输入视频源（MP4 / RTMP / RTSP / HTTP）
        ↓
  CHMP4-1364 进程
  avformat_open_input()   → 打开视频源
  av_read_frame()         → 读取压缩数据包
  avcodec_decode          → 解码为 YUV I420 格式
        ↓ pthread_mutex_lock
  写入全局 FrameBuffer（g_frameBuffer @ 0x8BE38）
        ↓
  cameraserver 进程（libCHMP4 注入后）
  Camera3OutputStream::returnBufferCheckedLocked 被触发
        ↓ hook 拦截
  GraphicBuffer::lock()           → 获取目标帧写指针
  FrameBuffer::clone()            → 取当前视频帧副本
  License 时间检查                 → 过期则 memset 0（黑屏）
  convert_I420_with_cropping_and_scaling() → 缩放匹配目标分辨率
  格式转换（按 HAL pixel_format）：
    0x11 NV21   → I420ToNV21()
    0x22 NV12   → I420ToNV12()
    0x21 JPEG   → rgb24ToJpg() via libjpeg-turbo
    YV12        → I420Scale()
    UBWC        → AMediaCodec encode+decode → I420ToNV12()
        ↓
  直接写入 GraphicBuffer 内存（dst_buffer）
  GraphicBuffer::unlock()
  调用原始 returnBufferCheckedLocked
        ↓
  目标 App（微信/视频会议）
  Camera2 API 返回此帧 → 认为是真实摄像头画面
```



#### 保护机制（对抗分析）

| 机制 | 实现方式 | 目的 |
|------|---------|------|
| nmmp VM 保护 | Java 方法体抽取为字节码，通过 VM 解释执行 | Frida 无法直接 hook License 验证实现 |
| chmp4.sh 加密 | AES 加密存储，运行时解密执行 | 静态分析无法读取脚本内容 |
| EncryptedString | 被 hook 的函数名逐字节 XOR 混淆 | 防止 `strings` 命令扫描出目标函数 |
| 函数名混淆 | `l1l1l1l1ll1`、`l1llll1lllll1l1` 等 | IDA 分析时难以追踪调用关系 |
| 包名伪装 | `com.telegram.a1064` | 欺骗用户和部分安全检测工具 |
| push_back 构建 | 命令名称逐字符拼接 | 防止静态字符串扫描发现命令接口 |




---

### 用一张图说明整体结构
```
Java 层                    native 层                  字节码层
─────────────────────────────────────────────────────────────────

App 启动
    ↓
NativeUtil.classesInit0(22)
    ↓ JNI
                    libnmmp.so
                    sub_E8D8(env, cls, 22)
                         ↓
                    从 .rodata 取 index=22 的字节码
                         ↓
                    vmInterpret(bytecode, env)
                         ↓ 字节码执行
                    RegisterNatives(C0531d, methods[])
                         ↓ 注册完成
↑ m4575a0 现在有了实现

调用 m4575a0()
    ↓ JNI（通过刚注册的函数指针）
                    libnmmp.so trampoline
                         ↓
                    vmInterpret(bytecode_for_a0, env)
                         ↓ 解释执行
                    // 字节码内容（被加密存在 .rodata）：
                    // 1. 构建字符串 "sh /data/.../chmp4.sh resetCamera"
                    // 2. 调用 Runtime.exec() 或 system()
                    // 3. 等待返回码
                         ↓
    ← 返回结果

```







检测与防御建议

运行时检测
检测 ServiceManager 中是否注册了 "Video2CameraService" 服务
检测 /data/camera/ 目录是否存在异常 .so 文件
检测 cameraserver 的 /proc/<pid>/maps 中是否有非系统路径的 .so
检测 SELinux 状态是否为 Permissive（getenforce 返回 Permissive）
检测 Camera3OutputStream 关键函数地址是否在 libcameraservice.so 范围内

系统防御建议

启用 SafetyNet/Play Integrity API，阻止 Root 设备访问敏感业务
在 cameraserver 中添加进程完整性检测，检查自身 maps 中的异常 so
视频通话应用可在应用层对摄像头帧做统计分析，检测异常的帧重复率




<p align="center"><img src="https://raw.githubusercontent.com/BojackMa/image-hosting/main/img/20260401210855.png" alt="20260401210855" width="50%"/></p>



## 7、离线版


## 8、在线版 apex
这个版本同上





## 元萝卜
元萝卜（也称为 Meta 元萝卜 或原名 伏羲X / 天鉴X / SPatch 等）是一款 安卓免 Root 虚拟框架 APK，主要用于实现应用多开（分身）、加载 Xposed 模块，以及提供虚拟环境下的增强功能。它类似于太极（TaiChi）或 VirtualXposed 的替代方案，通过沙盒/虚拟空间技术，在不获取手机 Root 权限的情况下，让用户同时运行多个相同应用的实例，或给指定 App 注入 Xposed 插件。



## 9、VCAMMAX_1.1.3
包名com.nvshen.chmp4

看上去这个还好



## 10、红色虚拟相机

看上去这个也还好


