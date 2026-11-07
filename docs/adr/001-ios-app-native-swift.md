# ADR-001：App 用 Swift / SwiftUI 原生开发

**日期**　2026-11-06
**状态**　Accepted
**来源**　#26（父 issue #10）

## 背景

- 平台已定为先做 iOS（`backend-design.md` §2.4）。
- App 的难点在设备侧：BLE 长连接与后台、连卡热点（`NEHotspotConfiguration`）、TCP 快传、Opus 解码。这些都已在 Swift 原型 `ios-prototype/` 上真机跑通（#7、#21、#6）。
- 官方 App 是 Capacitor（Vue + Ionic），`official-app-analysis.md` §5 曾把沿用 Capacitor 列为选项。

## 候选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| **Swift / SwiftUI 原生** | 直接复用原型的协议层、热点、快传、解码代码和单元测试；后台蓝牙、热点等系统能力无中间层 | 以后做安卓要另写一套 |
| Capacitor（沿用官方技术栈） | 交互逻辑可参照官方；以后顺带出安卓 | 设备侧要靠插件，后台蓝牙和热点的行为要重新验证；原型代码不能复用 |
| Flutter / React Native | 一套代码出双端 | 同 Capacitor：设备侧要靠插件桥接，原型验证结论不能直接沿用 |

## 决定

App 用 Swift / SwiftUI 原生开发，最低支持 iOS 17（与原型一致），协议层从 `ios-prototype/Sources/DNoteProtocol.swift` 起步。

## 后果

- 正面：阶段 0 的 iOS 结论（H6）直接成立，不用重测；M1 风险最低。
- 负面：安卓需要单独立项；协议层可以参照 Swift 和 Python 两份实现，但界面没法共享。
- 反悔成本：改跨端框架等于重写 App 界面层；协议层逻辑可以移植。
