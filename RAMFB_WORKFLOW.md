# QEMU qxl.c 中 RAMFB 工作流程详解

## 1. 什么是 RAMFB

**RAMFB (RAM Framebuffer)** 是一种绕过 PCI BAR 的显示方案：

- **传统 QXL**：Guest 驱动通过 PCI BAR0 (Device Memory) 读写像素，Host (QEMU) 通过 BAR0 的 HVA 读取
- **RAMFB**：Guest 驱动在**系统内存**中分配一块 framebuffer，通过 PCI Config Space 把 GPA (Guest Physical Address) 告诉 QEMU，QEMU 直接用 `qxl_phys2virt()` 映射为 HVA 读取

**为什么需要 RAMFB**：ARM64 上 PCI BAR 通常是 Device Memory (非缓存)，Guest CPU 写后 Host 可能看不到最新数据（缓存一致性问题）。RAMFB 使用 Normal Memory (系统内存)，天然支持缓存一致性。

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Guest (Windows)                       │
│  ┌─────────────────┐         ┌────────────────────────────┐ │
│  │  Display Driver │         │    RAMFB Framebuffer        │ │
│  │  (qxldod.sys)   │         │  (MmAllocateContiguous...)  │ │
│  └────────┬────────┘         └─────────────┬──────────────┘ │
│           │                                │                │
│           │ 1. Allocate memory             │                │
│           │───────────────────────────────>│                │
│           │                                │                │
│           │ 2. Write pixels (memcpy)       │                │
│           │───────────────────────────────>│                │
│           │                                │                │
│           │ 3. Write PCI Config (0x80)     │                │
│           │    PA + Size + Width + Height  │                │
│           └────────────────────────────────┘                │
└──────────────────────────┬──────────────────────────────────┘
                           │ PCI Config Write
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                        Host (QEMU)                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  qxl_pci_write_config()               │  │
│  │  捕获 offset=0x80 的写入，解析 RAMFB_CONFIG           │  │
│  └────────────────────────┬─────────────────────────────┘  │
│                           │                                  │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              qxl_phys2virt(PA) → HVA                  │  │
│  │  将 Guest GPA 转换为 Host 虚拟地址                     │  │
│  └────────────────────────┬─────────────────────────────┘  │
│                           │                                  │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           SPICE Server / Display Output               │  │
│  │  直接从 HVA 读取像素，发送到客户端                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 详细工作流程

### 3.1 初始化阶段 (Guest → Host)

**Guest 侧 (Windows 驱动)**：
```cpp
// 1. 分配物理连续的 Write-Combined 内存
PVOID va = MmAllocateContiguousMemorySpecifyCache(
    size, lowest, highest, lowest, MmWriteCombined);

// 2. 获取 GPA
PHYSICAL_ADDRESS pa = MmGetPhysicalAddress(va);

// 3. 填充 RAMFB_CONFIG 结构
RAMFB_CONFIG config = {
    .magic = 0x464D4152,        // 'RAMF'
    .version = 1,
    .width = 1920,
    .height = 1080,
    .format = DRM_FORMAT_XRGB8888,
    .flags = RAMFB_FLAG_ACTIVE,
    .framebuffer_pa = pa.QuadPart,   // Guest Physical Address
    .framebuffer_size = size
};

// 4. 通过 PCI Config Space 通知 QEMU
DxgkCbWriteDeviceSpace(
    DXGK_WHICHSPACE_CONFIG,
    &config,
    RAMFB_PCI_OFFSET,    // offset 0x80
    sizeof(config),
    &bytesWritten);
```

**Host 侧 (QEMU qxl.c)**：
```c
static void qxl_pci_write_config(PCIDevice *pci_dev, uint32_t address,
                                  uint64_t val, int len)
{
    QXLState *qxl = DO_UPCAST(QXLState, pci, pci_dev);
    
    // 检测 RAMFB 配置写入 (offset 0x80)
    if (address >= RAMFB_PCI_OFFSET && 
        address < RAMFB_PCI_OFFSET + sizeof(RAMFB_CONFIG)) {
        
        // 解析 Guest 写入的配置
        memcpy(&qxl->ramfb_config, ...);
        
        // 验证 magic
        if (qxl->ramfb_config.magic == RAMFB_MAGIC) {
            // 激活 RAMFB
            qxl_ramfb_activate(qxl);
        }
    }
}
```

---

### 3.2 像素更新阶段 (Guest → Host)

**Guest 侧**：
```cpp
// 应用程序更新屏幕 → Dxgkrnl → qxldod
// 驱动直接把像素 memcpy 到 m_RamfbVA
for (y = 0; y < height; y++) {
    RtlCopyMemory(dstRow, srcRow, width * 4);
}

// 内存屏障确保 Host 能看到最新数据 (ARM64 关键!)
__dsb(ish);
__dmb(ish);

// 发送 QXL drawable 通知 Host 哪个区域脏了
// (drawable 中不附带像素数据，只带 rect 坐标)
```

**Host 侧**：
```c
// QEMU 收到 QXL_COMMAND 中断
// 解析 drawable，得到 dirty rect
// 注意：drawable->u.copy.src_bitmap == 0 表示使用 RAMFB

void qxl_draw_ramfb_update(QXLState *qxl, QXLDrawable *drawable)
{
    // 1. 获取 RAMFB 的 HVA
    void *ramfb_hva = qxl->ramfb.hva;  // 之前通过 qxl_phys2virt 映射
    
    // 2. 计算 dirty rect 在 framebuffer 中的偏移
    int offset_y = drawable->surfaces_rects[0].top;
    int offset_x = drawable->surfaces_rects[0].left;
    int width = drawable->surfaces_rects[0].right - offset_x;
    int height = drawable->surfaces_rects[0].bottom - offset_y;
    
    void *src = ramfb_hva + (offset_y * qxl->ramfb.stride) + (offset_x * 4);
    
    // 3. 发送到 SPICE (零拷贝方式)
    // 方式A: 直接标记 surface 脏区域
    spice_server_update_area(qxl->ssd.server, 0, &rect);
    
    // 方式B: 复制到 QXL 内部 surface
    // pixman_image_composite32(..., src, ...);
}
```

---

### 3.3 关闭/释放阶段 (Guest → Host)

**Guest 侧**：
```cpp
// 模式切换或驱动卸载时
RAMFB_CONFIG config = {0};  // 全零表示停用
config.magic = RAMFB_MAGIC;
DxgkCbWriteDeviceSpace(..., &config, RAMFB_PCI_OFFSET, ...);

// 释放内存
MmFreeContiguousMemory(m_RamfbVA);
```

**Host 侧**：
```c
static void qxl_pci_write_config(...)
{
    // 检测到 PA=0 或 flags=0，停用 RAMFB
    if (qxl->ramfb_config.framebuffer_pa == 0) {
        qxl_ramfb_deactivate(qxl);
        // 释放 pixman surface，回到标准 QXL 模式
    }
}
```

---

## 4. 关键函数说明

### 4.1 Guest → Host 通知路径

| 步骤 | Guest (Windows) | 通信方式 | Host (QEMU) |
|------|----------------|---------|------------|
| 1 | `MmAllocateContiguousMemorySpecifyCache` | 无 | 无 |
| 2 | `DxgkCbWriteDeviceSpace(offset=0x80)` | PCI Config Write | `qxl_pci_write_config` |
| 3 | `memcpy` 到 framebuffer | 直接写内存 | 无 (被动读取) |
| 4 | `__dsb()` + `__dmb()` | 内存屏障 | 无 |
| 5 | `QXL_IO_NOTIFY_CMD` | IO Port Write | `qxl_handle_drawable` |
| 6 | `DxgkCbWriteDeviceSpace(zeros)` | PCI Config Write | `qxl_ramfb_deactivate` |

### 4.2 QEMU 内部关键函数

```c
// 1. PCI Config Space 捕获
qxl_pci_write_config(PCIDevice *pci_dev, uint32_t addr, uint64_t val, int len)
    └── 检测 addr >= 0x80
        └── qxl_ramfb_activate(qxl)
            └── qxl->ramfb.hva = qxl_phys2virt(qxl, pa, 0)
                └── 通过 memory_region_get_ram_ptr() 获取 HVA
            └── qxl->ramfb.surface = pixman_image_create_bits(..., hva, ...)

// 2. 处理 Guest 的 QXL drawable
qxl_handle_drawable(QXLState *qxl, QXLDrawable *drawable)
    └── if (drawable->u.copy.src_bitmap == 0)  // RAMFB 模式标记
        └── qxl_draw_ramfb_update(qxl, drawable)
            └── spice_server_update_area(...)  // 通知 SPICE 刷新

// 3. SPICE 读取像素 (在 SPICE worker 线程中)
red_update_area(...)
    └── 从 qxl->ramfb.surface (pixman) 读取像素
        └── 编码为 Spice 协议数据包发送给客户端
```

---

## 5. 内存地址映射详解

```
Guest Virtual Address (VA)
    │  Windows 内核页表映射
    ▼
Guest Physical Address (GPA)
    │  KVM/HVF/TCG: GPA → HPA (Host Physical)
    │  或: memory_region_get_ram_ptr()
    ▼
Host Virtual Address (HVA)
    │  QEMU 进程地址空间
    ▼
SPICE Server (pixman_surface)
    │  spice-protocol 编码
    ▼
Remote Client (spice-gtk/virt-viewer)
```

**核心**：`qxl_phys2virt()` 的作用就是实现 `GPA → HVA` 的转换。

---

## 6. 代码实现参考

### 6.1 QEMU qxl.c 需要添加的代码

```c
// 在 QXLState 结构中添加 RAMFB 字段
typedef struct QXLState {
    PCIDevice pci;
    // ... 现有字段 ...
    
    struct {
        bool active;
        uint64_t pa;           // Guest Physical Address
        uint32_t size;
        uint32_t width;
        uint32_t height;
        uint32_t stride;
        void *hva;             // Host Virtual Address
        pixman_image_t *surface;
    } ramfb;
} QXLState;

// PCI Config Write 钩子
#define RAMFB_PCI_OFFSET 0x80
#define RAMFB_MAGIC 0x464D4152

static void qxl_ramfb_activate(QXLState *qxl)
{
    RAMFB_CONFIG *cfg = &qxl->ramfb_config;
    
    // GPA → HVA
    qxl->ramfb.hva = qxl_phys2virt(qxl, cfg->framebuffer_pa, 0);
    if (!qxl->ramfb.hva) {
        error_report("RAMFB: failed to map GPA %"PRIx64, cfg->framebuffer_pa);
        return;
    }
    
    qxl->ramfb.pa = cfg->framebuffer_pa;
    qxl->ramfb.size = cfg->framebuffer_size;
    qxl->ramfb.width = cfg->width;
    qxl->ramfb.height = cfg->height;
    qxl->ramfb.stride = cfg->width * 4;
    qxl->ramfb.active = true;
    
    // 创建 pixman surface (零拷贝，直接包装 HVA)
    qxl->ramfb.surface = pixman_image_create_bits(
        PIXMAN_x8r8g8b8,
        cfg->width,
        cfg->height,
        (uint32_t *)qxl->ramfb.hva,
        qxl->ramfb.stride
    );
    
    // 注册为 SPICE surface 0
    red_worker_set_surface(qxl->ssd.worker, 0, qxl->ramfb.surface);
    
    error_report("RAMFB: activated %dx%d at GPA=%"PRIx64" HVA=%p",
                 cfg->width, cfg->height, cfg->framebuffer_pa, qxl->ramfb.hva);
}

static void qxl_ramfb_deactivate(QXLState *qxl)
{
    if (!qxl->ramfb.active) return;
    
    qxl->ramfb.active = false;
    
    if (qxl->ramfb.surface) {
        pixman_image_unref(qxl->ramfb.surface);
        qxl->ramfb.surface = NULL;
    }
    
    // 回到标准 QXL 模式
    red_worker_set_surface(qxl->ssd.worker, 0, qxl->guest_primary.surface);
    
    error_report("RAMFB: deactivated");
}
```

### 6.2 Windows 驱动需要添加的代码

见 `qxl-wddm-dod` 项目中的 `QxlDod.cpp` 实现：
- `AllocateRamfbMemoryInternal()` - 分配连续物理内存
- `EscapeRamfbSetup()` - 通过 PCI Config 通知 QEMU
- `PrepareBltBits()` - RAMFB 模式下直接 memcpy 像素

---

## 7. 常见问题

### Q1: 为什么 Guest 写内存后 Host 看不到？
**A**: ARM64 上需要内存屏障。Guest 写完 framebuffer 后必须执行 `__dsb(ish)` 确保数据真正写回内存（而不是在 CPU cache 中），Host 才能看到。

### Q2: `qxl_phys2virt` 返回 NULL？
**A**: 检查：
1. GPA 是否有效（是否在 Guest RAM 范围内）
2. 内存是否确实是连续的（`MmAllocateContiguousMemorySpecifyCache`）
3. QEMU 的 memory region 是否正确设置了 RAM 属性

### Q3: 画面撕裂/花屏？
**A**: 
- Guest 缺少内存屏障
- Guest 和 Host 访问不同步（建议 Guest 发送 drawable 通知，不要假设 Host 实时读取）
- 多 rect 更新时顺序问题

---

## 8. 总结

RAMFB 的核心就是**让 Host 直接访问 Guest 系统内存中的 framebuffer**，绕过 PCI BAR 的缓存一致性问题。关键三步：

1. **Guest 分配内存** → `MmAllocateContiguousMemorySpecifyCache` (Write-Combined)
2. **Guest 通知 Host** → 通过 PCI Config Space (offset 0x80) 写入 GPA
3. **Host 映射读取** → `qxl_phys2virt(GPA) → HVA`，然后包装为 pixman surface 给 SPICE 使用
