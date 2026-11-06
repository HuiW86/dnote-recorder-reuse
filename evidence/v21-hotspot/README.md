# 证据：#21 热点自动加入 14 轮批量测试

- 日期：2026-11-07 02:06–02:23（设备本地时间）
- 机型：iPhone 12，iOS **27.2**（build 24B119）
- 卡：序列号 `h7spab9m1novnz0415`，固件 `1.50`，电量 30–32%
- App：`com.huiw86.dnoteprobe`，分支 `fix/21-hotspot-ssid-check`（提交 3ebe13f）
- 原始日志：`probe-batch.log`，sha256 `2043d930…93a7a16`

## 方法

Mac 上无人值守启动，不经 Xcode：

```sh
xcodebuild -project DNoteProbe.xcodeproj -scheme DNoteProbe \
  -destination 'platform=iOS,id=00008101-001828D02686001E' \
  -derivedDataPath build/dd -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008101-001828D02686001E \
  build/dd/Build/Products/Debug-iphoneos/DNoteProbe.app
xcrun devicectl device process launch --device 00008101-001828D02686001E \
  com.huiw86.dnoteprobe --autorun 14
```

`--autorun 14` 让 App 自己连卡并连跑 14 轮，每轮：`0x88 ap=0` → `ap=1` → 等 6 s →
`NEHotspotConfiguration.apply`（`joinOnce=false`，随机 12 位密码，最多 3 次）→
校验 en0 是否拿到 `192.168.88.x` → TCP `192.168.88.1:6718` → `0x88 ap=0` 清理。
轮间隔 10 s。

日志取回：

```sh
xcrun devicectl device copy from --device 00008101-001828D02686001E \
  --domain-type appDataContainer --domain-identifier com.huiw86.dnoteprobe \
  --source Documents/probe.log --destination /tmp/probe.log
```

## 结果

**13 PASS / 1 inconclusive（14 轮）**，对比 V7 的 2/14。

| 轮次 | 结果 | join 尝试 |
|---|---|---|
| 1 | PASS | 第 1 次成，**耗时 362.6 s** |
| 2–6 | PASS | 第 1 次成，12.2–45.7 s |
| 7 | PASS | 第 1 次失败，第 2 次成 |
| 8–11 | PASS | 第 1 次成，12.1–13.4 s |
| 12 | PASS | 第 1、2 次失败，第 3 次成 |
| 13 | inconclusive | 3 次全失败 |
| 14 | PASS | 第 1 次成，15.3 s |

- 第一次尝试即成功：11/14（79%）
- 加上最多 3 次重试：13/14（93%）
- 成功轮次的 TCP 全部在**第 1 次尝试**连通，没有一轮用到 6 次重试额度

## 判据与结论

**根因是首次加入的系统确认框。** 第 1 轮的 362.6 s 就是弹框等待人工点击的时间；
人工批准一次之后，后续 13 轮不再弹框，且 11 轮第一次尝试就成功。

V7 的 2/14 与本轮的 13/14 用的是同一台设备、同一张卡、同样的 `joinOnce=false` 路径，
唯一差别是本轮有人批准了弹框。**所以 V7 的失败不是 API 用法或时序问题。**

批准具有持久性：本轮每轮用**新的随机密码**，且每轮结束都
`removeConfiguration(forSSID:)` 清掉配置，仍然不再弹框。

**重试逻辑有实际价值**：第 7、12 轮靠重试救回，去掉重试成功率从 93% 降到 79%。

## 局限

- **A/B 分类未能生效。** 定位权限被拒（`CLAuthorizationStatus = 2 = denied`），
  `NEHotspotNetwork.fetchCurrent()` 全程返回 nil，日志里都是 `ssid=unavailable`。
  因此第 13 轮的失败只能判为 inconclusive，无法区分「iOS 没切网」与「切了网但路由不通」。
  要定位残留的 1/14，需重跑并授予定位权限
- 本轮全程 App 在前台、设备未锁屏，**未覆盖后台与锁屏场景**
- 卡在批量开始时处于录音状态（`rec:1`，按键误触发的 `20261106100604.opus`），
  未单独测过「空闲状态下的成功率」是否更高
- 只测了一台设备、一个 iOS 版本、一张卡、一个 Wi-Fi 环境（家庭网 `192.168.31.x`）
- 本轮未验证快传 TCP 协议本身，只验证了端口可连（banner 3 s 内无数据），协议属 #6

## 对 #13 的影响

自动加入在用户批准过一次后可用（93%，带重试）。**首次使用必须有一次人工批准**，
这是 iOS 的硬约束，产品上要把它设计成明确的引导步骤，而不是静默重试。
