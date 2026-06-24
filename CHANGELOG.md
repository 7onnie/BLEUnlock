# Release Notes

## 1.14.0

- Resolve MAC addresses from system paired Bluetooth devices via IOBluetooth and display them in the device list.
- Automatically remap device tracking when BLE UUID changes after disconnect or reboot, using MAC-based cross-correlation. No reconfiguration needed.
- Monitored devices are now sorted to the top of the device list, with unmonitored devices following in discovery order.
- Add Bluetooth entitlement for broader macOS compatibility.

<details>
<summary>中文发布说明</summary>

- 通过 IOBluetooth 从系统已配对蓝牙设备中获取 MAC 地址，并显示在设备列表中。
- 当设备 BLE UUID 因断连或系统重启发生变化时，自动通过 MAC 地址交叉关联重映射追踪，无需手动重新配置。
- 已勾选的监控设备自动排序到设备列表顶部，未勾选设备按发现顺序排列在下方。
- 添加 Bluetooth entitlement 以兼容更多 macOS 版本。

</details>
