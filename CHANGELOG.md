# Release Notes

## 1.14.2

- **Fix:** Remove name-based MAC resolution — device name matching is unsafe due to name collisions. Persisted MAC→UUID mapping and LE database lookup are now the only MAC sources on startup.
- **Fix:** `scheduleDeviceMenuReorder` guard prevented separator visibility updates during menu tracking, causing separator and "Scanning…" to disappear when unmonitored devices arrived after the menu opened.
- Fix late MAC correlation in mergeDevice leaving stale "not detected" entries by removing any existing menu item for the new UUID before adding.
- Add MAC correlation check in newDevice: before creating a separate unmonitored entry, verify the device's MAC doesn't match a monitored one and merge if so.
- Fix monitored device reorder flicker: sort by stable MAC key instead of evolving resolved name; simplify menu rebuild to full replace instead of error-prone diff algorithm.
- Fix mergeDevice during menu tracking: repurpose the existing menu item without touching menu structure, eliminating position shifts from insertItem repositioning.
- Normalize all MAC comparisons and storage to canonical lowercase-dash format, resolving mismatches between resolveMACForDeviceName and getMACFromUUID return formats.
- Monitored device RSSI denoising: switch to median-of-3 sliding window filter — single outliers are eliminated, real trends track within 1 sample (2s).
- Cache Bluetooth preferences plist reads (30s TTL) and throttle per-device IOBluetooth lookups (5s cooldown) to eliminate redundant disk I/O from allowDuplicates scanning callbacks.
- **Fix:** Move scanning lifecycle from device submenu to main menu, so detection counts (e.g. 1/2 vs 2/2) are accurate on menu open without requiring device list expansion.
- **Fix:** Clamp RSSI ≥ 0 to -100 — RSSI 0 dBm is physically impossible for BLE and indicates a stale or invalid reading.
- **Fix:** Do not cache new UUIDs in the deferred merge path — duplicate MAC entries in the devices dictionary caused findKnownDeviceByMAC to return the wrong (unmonitored) entry, silently breaking remap.
- **Fix:** Check for remap opportunities on every RSSI update in the else branch, not just on first MAC resolution — a previously resolved MAC would never trigger cross-correlation when the old UUID later went invisible.
- **Fix:** Call remapMonitoredUUID before devices.removeValue in late-correlation paths — removeValue clears devices[oldUUID] before remapMonitoredUUID's guard can validate it, causing silent remap failure (no log).

<details>
<summary>中文发布说明</summary>

- **修复:** 移除基于设备名称的 MAC 解析 — 设备名可能重复，有安全隐患。启动时仅使用持久化 MAC→UUID 映射和 LE 数据库查找作为 MAC 来源。
- **修复:** `scheduleDeviceMenuReorder` 的 guard 在菜单追踪期间阻止后续分隔线可见性更新，导致菜单打开后新发现的未勾选设备无法触发分隔线和「扫描中…」显示。
- 修复延迟 MAC 关联时 mergeDevice 残留「未检测到信息」条目的问题：添加新条目前先移除 newUUID 已有的菜单项。
- newDevice 加入 MAC 关联检查：未监控设备创建前，校验其 MAC 是否与已监控设备相同，相同则直接合并。
- 修复已勾选设备排序抖动：改用 MAC 稳定键排序替代变化的解析名；简化菜单重建为全量替换，避免 diff 算法的边界错误。
- 修复菜单追踪期间 mergeDevice 造成的位序跳变：原地复用已有菜单项，不触碰菜单元数据。
- 统一所有 MAC 地址比较和存储为小写短横线格式，消除 resolveMACForDeviceName 与 getMACFromUUID 返回格式不一致导致的匹配失败。
- 已监控设备 RSSI 降噪：改用中值滤波（3 样本滑动窗口取中位数） — 单个异常值完全消除，真实趋势延迟 1 个采样周期（2 秒）内跟踪。
- 蓝牙偏好 plist 读取缓存（30 秒）和设备级 IOBluetooth 查询冷却（5 秒），消除 allowDuplicates 扫描回调引发的冗余磁盘 I/O。
- **修复:** 扫描生命周期从设备子菜单提升到主菜单，打开菜单时检测计数（如 1/2 vs 2/2）即时准确，无需展开设备列表。
- **修复:** RSSI ≥ 0 统一视为 -100 — BLE 不可能出现 0 dBm，此值表明读数异常或已断连。
- **修复:** 推迟合并路径不再缓存新 UUID 到设备字典 — 重复 MAC 条目导致 findKnownDeviceByMAC 返回错误的（未监控）条目，remap 静默失败。
- **修复:** else 分支每次 RSSI 更新都检查 remap 机会，不再仅限于首次 MAC 解析 — 先解析 MAC 后旧 UUID 才变不可见的情况也会触发合并。
- **修复:** late-correlation 路径中先调用 remapMonitoredUUID 再 devices.removeValue — 先 remove 会使 remap 的 guard 拿到 nil 而静默返回 false（无日志）。

</details>
