# T-M15-60 先不连卡及手机录音子项

2026-11-26 23:11–23:38（设备时间，UTC+08:00）。iPhone 16，iOS 27.0，USB 充电，实测电量约 92–97%。源码 `2a638e8`，DEBUG 0.1.0 (109)，构建号提交 `8417093`。v1.50 卡仍由原闻笺管理，这轮没有与验收版配对。原 App 与原录音库保留。

从已安装过的 DEBUG 构建复制 App 签名包，单独用现有通配开发描述文件签名。把测试包的 Bundle ID 设为 `com.huiw86.revive.acceptance`，显示名称为「闻笺验收」。用 `otool -s __TEXT __text` 对照机器码一致，核对版本、蓝牙/麦克风/语音权限说明一致，再用 `codesign --verify --deep --strict` 核验签名。用 `xcrun devicectl device install app` 通过 USB 安装独立测试包，与原 App 并存。首次启动使用空白容器和独立的系统授权。截图裁掉顶部状态栏，无连续屏幕录像。

## T-M15-60 的步骤与判据

按 `product-spec.md` §9，先不连卡时进入总览，蓝牙权限只在 P01 点「继续」后才问。手机录音、从「文件」导入音频和文字、打开本机转写后可用，重启状态正确；配对、解绑能闭环，拒绝蓝牙后仍可用手机功能。

1. 从 [初次启动的 P01](01-read-before-using.jpg) 点「先不连卡，直接用」，进入 [总览](02-cardless-overview.jpg)，未弹 Bluetooth 权限。
2. 点底栏红键，出现 [用这部手机录](03-phone-choice.jpg)，勾选录音同意项后出现 [麦克风授权](04-microphone-permission.jpg)。允许后已在手机录音界面，随后出现国行系统的 [无线数据授权](05-wireless-permission.jpg)，选择不允许。录音完整存入列表，数据库时长为 71.921 秒。见 [保存界面](06-phone-recording-saved.jpg) 和 [文件校验](phone-library-check.txt)。
3. 从「录音卡」标签点「添加录音卡」，回到 [P01](07-return-before-continue.jpg)。回到此页时未弹权限，点击「继续」后才出现系统 [蓝牙授权](08-bluetooth-permission.jpg)。拒绝后见 [权限拒绝页](09-bluetooth-denied.jpg)，可点「先不连卡，直接用」。此时 [录音卡标签](10-card-tab-after-denial.jpg) 显示「还没有录音卡」，规格所述的蓝牙不可用提示实际出现在 [录音标签](11-recordings-bluetooth-banner.jpg)。先前的手机录音仍在。
4. 按 [T-M5-61](../v72-link-import-device/README.md#t-m5-61-关闭无线数据) 恢复该 App 的 Wi-Fi 权限。在蓝牙仍被拒绝时，从链接导入小宇宙公开音频，详情显示 58 分 56 秒，文件完整解码。随后从系统「文件」也成功导入同一音频。[文件回环](../v70-m4a-export/README.md)
5. 设置打开「本机转写（试验）」，在 71.921 秒的手机录音点「转成文字」。首次出现 [语音识别授权](12-speech-permission.jpg)，允许后界面 23:25:20 显示「转写失败，请重试」，仍可再点「转成文字」。未生成文字稿。未抓系统网络和底层错误，本样本音频不入库。[界面文字记录](asr-ui.txt)
6. 使用 `xcrun devicectl device process launch --terminate-existing com.huiw86.revive.acceptance` 终止并重启验收版。重启进入总览，未再次回 P01。仍未配对卡。

**部分通过，限独立 DEBUG 身份。** 验证了蓝牙权限时序、拒绝后继续、无卡手机录音、链接和「文件」音频导入、重启回总览。本机转写未产出文字稿，蓝牙拒绝提示位置与规格有差异。正式 TestFlight 干净安装、连续录屏、`.txt` 导入、配对和解绑仍未取证。

## 手机录音的操作子项

- **T-M4-19 通过，限独立 DEBUG 身份的真机部分。** 判据要求在约 10 秒和 40 秒标两处，第二次连点只算一处，保存后详情和「有重点」筛选可用。单独录一条 62.238 秒的手机录音，App 显示两处，库中位置为 9.259 和 39.311 秒。「有重点」筛选保留该条，点第二处后播放器从 39.311 秒开始播放。异常退出样本也保留了一处重点。[重点回放](13-mark-playback.jpg)
- **T-M4-18 部分通过。** 判据要求录约 1 分钟后不点停止而强制退出，重启能找回可播的 CAF 转存和原始开始时间，并另证 ≥30 分钟正常停止和保存。用上述 `--terminate-existing` 代替上滑关闭，重启后列表增加一条名为「11月26日 23:27」的手机录音，保留一处重点。数据库测得 101.245 秒，M4A 解码成功，本次未截到「找回」Toast，≥30 分钟手机样本未录。[重启后](14-restored-after-relaunch.jpg) · [库与文件校验](phone-library-check.txt)

本机校验用 `xcrun devicectl device copy from --source 'Library/Application Support/library' --domain-type appDataContainer --domain-identifier com.huiw86.revive.acceptance`，以只读 SQLite 查询 `recording` 和 `phone_mark`、以 FFmpeg 完整解码，报告仅记录音频校验值。
