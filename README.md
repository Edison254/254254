# 归因清理 AttribClean

iOS 越狱插件。重新生成广告标识、清掉各家归因 SDK 在本机留下的数据、重置跟踪授权状态。
**每个 App 一个开关，默认全关**，你要清哪个才开哪个。

支持 iOS 15 – 18，rootless（Dopamine / palera1n rootless）和 rootful 两种环境都能编。

---

## 一、它是怎么工作的

一个注入型插件（tweak）挂进每个 App 进程，做两件事：

1. **换标识** — 拦截 App 查询 IDFA / IDFV / ATT 授权状态的那几个系统方法，返回新造的值。
2. **清数据** — 访问该 App 自己的数据目录，把归因 SDK 写进去的缓存、配置、钥匙串条目删掉。

因为插件在每个 App 自己的进程里跑，所以：

- 覆盖的是**这台设备上所有 App**，不用一个个单独装
- 只能动**自己有权限动的那个 App 的数据**，不会串到别人家
- 系统进程（SpringBoard、守护进程）直接跳过，不碰

开关写成 plist 放在每个 App 自己的容器里，桌面上的「归因清理」App 负责改这些 plist。

---

## 二、编译

> 需要一台电脑（Mac 或 Linux），手机上编不了。三种方式挑一种。

### 方式一：Mac（推荐）

```bash
# 1. 装 Theos
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS

# 2. 放 iOS SDK
mkdir -p $THEOS/sdks
git clone --depth 1 https://github.com/theos/sdks.git /tmp/sdks
cp -r /tmp/sdks/iPhoneOS16.5.sdk $THEOS/sdks/

# 3. 装签名工具
brew install ldid xz

# 4. 编译
cd AttribClean
chmod +x build.sh
./build.sh
```

`packages/` 里会出两个 deb：

- `com.zaka.attribclean_1.0.0_iphoneos-arm64.deb` — **rootless 用这个**（现在的主流，装到 /var/jb）
- `com.zaka.attribclean_1.0.0_iphoneos-arm.deb` — rootful 用（palera1n 老模式）

### 方式二：Linux

跟 Mac 基本一样，只是 ldid 用 Theos 自带的：

```bash
sudo apt install -y make git curl xz-utils libplist-utils
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS
git clone --depth 1 https://github.com/theos/sdks.git /tmp/sdks
cp -r /tmp/sdks/iPhoneOS16.5.sdk $THEOS/sdks/
chmod +x $THEOS/bin/ldid
cd AttribClean && ./build.sh
```

### 方式三：GitHub 云编译（本机什么都没有也能用）

1. 在 GitHub 建一个空仓库
2. 把 `AttribClean` 整个目录传上去（`.github/workflows/build.yml` 要一起传）
3. 等 Actions 跑完，在 Artifacts 里下 `AttribClean-debs`
4. 手机上下载 artifact 里的 deb

免费，不用装任何东西。

---

## 三、安装

把 deb 传到手机，用 Filza / Sileo / Zebra 打开安装，或者命令行：

```bash
# rootless
dpkg -i com.zaka.attribclean_1.0.0_iphoneos-arm64.deb

# rootful
dpkg -i com.zaka.attribclean_1.0.0_iphoneos-arm.deb
```

装完桌面会出现「归因清理」图标。没出现就手动刷一下：

```bash
uicache -a
```

---

## 四、使用

1. 打开「归因清理」
2. 上面几排开关决定**清什么**（默认全开，可以关掉不想动的）
3. 下面列表里挑**要清哪个 App**，把开关打开
4. **重启那个 App**（上滑杀掉，再打开）

第一次打开目标 App 时会自动清一遍，之后每次冷启动都清。

点列表里任意一行能看到这个 App 上次清理的明细（删了什么、失败几个）。

### 几个开关的意思

| 开关 | 作用 |
|---|---|
| 广告标识 IDFA | 让 App 每次都拿到新造的广告标识，跟以前那个对不上 |
| 应用厂商标识 IDFV | 同上，这个是按厂商分组的 |
| 跟踪授权 ATT | App 查「允许跟踪」状态时直接返回已授权 |
| 缓存与文件 | 删 SDK 写在 Caches / Documents / tmp 里的数据 |
| 偏好设置 | 删 SDK 的配置文件，以及 App 主配置里 SDK 写的键 |
| 钥匙串 | 删 SDK 存在钥匙串里的安装标识 |
| 深度清理 | 扩大关键词范围（会认 install_id、device_id 这类），可能误伤 App 自己的缓存，默认关 |
| 预演模式 | 只写日志不动手，先看清楚会删什么再决定，默认关 |

### 重新生成标识

底部「重新生成广告标识」会造一个新的 IDFA 发给所有已开启的 App。点一次换一次，旧的再也对不回来。

---

## 五、它清哪些 SDK

按品牌名匹配，覆盖这些：

- 归因：AppsFlyer、Adjust、Branch、Kochava、Singular、Tenjin、AppMetrica
- Meta：Facebook SDK、FBAnalytics、FBAppLink
- 字节：Bytedance、Toutiao、BDInstall、AppLog、Pangle
- 腾讯：Tencent、Bugly、GDT、MSDK
- 友盟、阿里百川
- 快手：Kuaishou、Kwai
- 广告聚合：UnityAds、Vungle、ironSource、AppLovin、AdMob、Chartboost、Mintegral、Tapjoy、InMobi、AdColony、Pangle
- 统计：Firebase、Google Analytics、Amplitude、Mixpanel、mParticle、Countly、Crashlytics、Sentry、Bugsnag
- 推送：OneSignal、JPush、个推、信鸽

开了「深度清理」再加：segment、attribution、install_id、installid、idfa、idfv、gaid、oaid、device_id 这类通用命名。

---

## 六、为了不闪退做了哪些事

写的时候是照着「宁可少清一点，也不能让 App 崩」来的：

1. **只在用户 App 里干活** — 系统进程、守护进程一进入口就 return，不装载任何 hook
2. **每个 hook 都包 try/catch** — 出异常就返回原实现，App 感觉不到
3. **类和方法先判空再 hook** — AdSupport / AppTrackingTransparency 没加载就跳过，不强来
4. **文件操作全在后台队列** — 不占主线程，不会让 App 卡启动
5. **只删命中关键词的文件** — App 主配置 plist 不整个删，只摘掉 SDK 写的键
6. **不跟符号链接、限制遍历深度和数量** — 最多 5 层、3000 项，跑飞不了
7. **熔断保护** — 连续 3 次清理没正常收尾（比如 App 被强杀在清理中途），自动停掉这个 App 的清理，不会再反复试
8. **不 hook 任何 UI 方法** — 界面层一行没碰

---

## 七、说清楚做不到的部分

- **没在真机上跑过。** 我这边只有源码环境，没有 iOS 编译器也没有越狱设备，所有代码是逐行写的、逻辑对着系统接口抠的，但「装上去确实不崩」这句话我没法替你保证。装之前建议先拿一个不重要的 App 试。
- **清得干净不等于清得彻底。** 有些 App 用了自研的归因方案、或者把 install id 藏进加密数据库里，插件认不出来，就清不到。开了深度清理能多认一些，但不是 100%。
- **反越狱检测的 App 可能直接不让你进。** 那是 App 自己的保护，跟这个插件无关。
- **有些 App 把标识存在服务端。** 清本地只解决本地那一半，服务端那边它早就记住了。
- **iOS 17 之后 ATT 的坑变多了。** 插件层面返回已授权是有效的，但如果 App 走的是系统里别的路径去查，可能查得到真状态。
- **首次开启要重启目标 App** — 插件是在进程启动时装的，不重启不生效。

---

## 八、卸载

Sileo / Zebra 里卸载 `AttribClean 归因清理`，或者：

```bash
dpkg -r com.zaka.attribclean
```

卸载只删插件本身，不会留什么。各 App 容器里那份几 KB 的配置文件留着也无害；想彻底干净，把每个 App 容器下
`Library/Preferences/com.zaka.attribclean.plist` 和 `Library/Caches/com.zaka.attribclean/` 删掉即可。

---

## 九、目录结构

```
AttribClean/
├── Makefile                 主工程
├── control                  deb 元信息
├── build.sh                 一键编译
├── Sources/
│   ├── ACCommon.h           常量与路径
│   ├── ACPrefs.h/.m         配置读写（容器内 + 全局兜底）
│   ├── ACIdentity.h/.m      IDFA / IDFV 生成
│   ├── ACCleaner.h/.m       文件 / 偏好 / 钥匙串清理
│   ├── ACLog.h/.m           日志
│   └── Tweak.xm             注入入口与 hook
├── prefsapp/                桌面上的「归因清理」
│   ├── main.m
│   ├── ACAppDelegate.h/.m
│   ├── ACAppEnumerator.h/.m 枚举已装 App 与容器
│   ├── ACListViewController.h/.m  主界面
│   ├── entitlements.plist
│   └── Resources/Info.plist
├── layout/DEBIAN/           postinst / prerm
└── .github/workflows/       云编译
```
