# 飞腾 D2000 平台 QEMU/KVM 内存一致性问题总结

## 背景

在飞腾 D2000（ARMv8.2，麒麟 V10，KVM）上运行 Windows ARM64 虚拟机时出现一系列
看似无关的故障，在鲲鹏 920（同为 ARMv8.2）上同一份二进制、同一份镜像全部正常：

- qxl-vga / bochs-display 开机画面及 Windows 启动、安装阶段局部花屏（雪花、错位）
- Windows 设备管理器中完全没有声卡（ich9-intel-hda）
- 保存系统快照失败（日志：`State blocked by non-migratable device 'usb-audio'`）

## 根因

**同一块物理内存被 host（QEMU，WB 缓存属性）和 guest（NC/Device 属性）以不同
内存属性访问时，D2000 不保证一致性。**

ARM 规范中"混合内存属性别名"本来就是 UNPREDICTABLE 行为：

- guest 以 NC 写 → 数据直达 DRAM，绕过 cache
- host 以 WB 读写 → 数据停在 cache 里
- 两边各自看到不同的"视图"，读到旧数据/垃圾

x86 上这类混用由硬件统一处理，所以 Windows 驱动里大量 `MmNonCached` 的习惯写法
从来不出事。ARMv8.4 引入的 FEAT_S2FWB（Stage-2 Force Write-Back）可以让 KVM 把
guest 的 NC 映射强制按 WB 处理，硬件层面掩盖问题。D2000 和鲲鹏 920 都是 ARMv8.2、
没有 S2FWB；鲲鹏的互联实现恰好兜住了 NC 访问，D2000 没有——所以"鲲鹏好、D2000 坏"。

上游 QEMU（截至 master）没有任何针对此问题的处理；上游立场是：声明了 _CCA=1
的平台上 guest 本就该使用一致性 DMA 属性，这属于平台/KVM 层的问题。

## 三个战场与修法

| 场景 | 故障表现 | 谁的代码 | 修法 |
|---|---|---|---|
| EDK2 开机 logo | 花屏 | 我方固件 | GOP 把 framebuffer 从 EFI_MEMORY_WC 改为 EFI_MEMORY_WB（ARM64 上 WC 会退化为 NC） |
| Windows 桌面（qxldod.sys） | 花屏/崩溃 | 我方驱动 | BAR 映射从 MmNonCached/MmWriteCombined 改为 MmCached |
| Windows 启动/安装阶段（微软 Basic Display 驱动） | 花屏 | 微软 | QEMU 侧兜底：vga.c 每帧读显存前 dc civac |
| HDA 声卡（hdaudbus.sys） | 无声 | 微软 | QEMU 侧兜底：intel-hda.c DMA 全通道 cache 维护 |

原则：**能改 guest 就改 guest（一行属性、零开销、架构上正确）；
改不了的微软组件才由 QEMU 侧做 cache 维护兜底。**

## QEMU 侧改动清单（本仓库）

- `include/qemu/host-cache-maint.h`（新增）
  公共助手：`qemu_host_dcache_clean_poc()`（dc cvac，QEMU 写完后调用）、
  `qemu_host_dcache_invalidate_poc()`（dc civac，QEMU 读取 guest 所写内存前调用）。
  仅 aarch64 生效，其他平台为空操作。dc civac 先 clean 再 invalidate，
  即使对方是 WB 写也不会丢数据。

- `hw/audio/intel-hda.c`
  HDA 的 DMA 控制/数据通道全部加了维护（均通过 `intel_hda_guest_cache_maint`）：
  - `intel_hda_corb_run()`：读 CORB 动词前 civac
  - `intel_hda_parse_bdl()`：读 BDL 描述符前 civac
  - `intel_hda_xfer()`：播放方向读 PCM 前 civac；录音方向写 PCM 后 cvac；
    位置回写（dp）后 cvac
  - `intel_hda_response()`：写 RIRB 应答后 cvac

- `hw/display/vga.c`
  `vga_draw_graphic()` 每帧读显存前，对可见区域（region_start..region_end）
  做 civac。覆盖 qxl-vga 的 VGA 兼容模式（Windows 启动/安装画面走这条路，
  qxl_enter_vga_mode() 会把 console hwops 切回 VGA）。

- `hw/display/qxl.c`
  `interface_get_command()` / `interface_get_cursor_command()` 的 ring 消费路径
  加了 `smp_rmb()`/`smp_mb()` 屏障（这是独立的弱内存序问题：guest 写的 ring
  item 与 prod/cons 指针之间的顺序，x86 由 TSO 掩盖，ARM 不会）。

- `hw/arm/virt.c`
  强制创建 qxl-vga 处 ram_size 16MB→64MB：修复 `init_qxl_rom()` 中
  num_pages 的 uint32 下溢（16MB - 4K - 16MB 回绕成 65535 页，ROM 声称
  ~4GB QXL 内存）。

## 诊断方法备查

- intel-hda 自带 debug 属性：`-device ich9-intel-hda,debug=2`，
  日志含全部 MMIO 读写与 verb/response 交换。
- 关键证据：第一批 3 个 verb 正确（冷缓存），第二批读出 `verb 0x00000000`
  （host 命中了旧缓存行）；guest 侧表现为 codec 枚举出
  `HDAUDIO\FUNC_00&VEN_1AF4&DEV_0022&SUBSYS_00000000`（功能组类型和
  SUBSYS 读成了 0，正常应为 FUNC_01 / SUBSYS 非 0）。
- 读写方向不对称的机制：
  - guest NC 写 → host 冷读：第一次正确（cache 里没有副本），后续读到旧行
  - host WB 写 → guest NC 读：稳定读到旧数据（脏行不主动回写就一直脏在 cache）

## 遗留事项

- 建议把最小复现（bochs-display 三行命令花屏 + HDA debug 日志中 verb 读出全 0）
  报给麒麟/飞腾，这是平台/KVM 层的问题，ARMv8.4（S2FWB）之后的硬件不再存在。
- 上游不会收这类 QEMU 侧兜底补丁；若长期维护，建议改成带开关的形式
  （如 device/machine 属性）而非无条件生效。
- usb-audio 不支持迁移（无 vmstate），会阻塞 savevm/快照，不要使用。
- virtio-snd 对 Windows guest 不可行：virtio-win 没有 Windows 版声卡驱动
  （kvm-guest-drivers-windows 仓库无对应驱动，issue #929 仍是 open 的功能请求），
  目前仅 Linux guest（CONFIG_SND_VIRTIO）可用。
- 若 PCM 播放仍有轻微沙哑：先关掉 `-device ...,debug=2` 再测（日志开销本身
  会造成爆音），再与鲲鹏对照以区分平台问题与 PA 后端问题。
