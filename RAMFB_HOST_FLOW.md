# QEMU Host端 RAMFB 处理流程

## 核心
Guest把GPA通过PCI Config给QEMU后，QEMU只需：
1. 保存HVA（GPA→HVA映射）
2. 显示更新时从HVA读像素

## 阶段1: 激活RAMFB

Guest PCI Config Write(0x80)
    → qxl_pci_write_config()
        → qxl_ramfb_activate()
            → qxl_gpa_to_hva(GPA) → HVA
            → qxl->ramfb_host_ptr = HVA
            → qxl->guest_primary.data = HVA

## 阶段2: Guest更新像素

Guest直接写RAMFB内存，QEMU无感知

## 阶段3: 显示刷新

### 路径A: 本地显示
qxl_render_update()
    → qxl_blit()
        → src = qxl->guest_primary.data (= HVA)
            → memcpy(HVA → 本地DisplaySurface)

### 路径B: SPICE远程
interface_get_command()
    → SPICE server内部解析drawable
        → qxl_phys2virt(src_bitmap)
            → qxl_ramfb_get_ptr(addr)
                → 返回 HVA + offset
                    → SPICE读取像素 → 客户端

## HVA使用位置

| 位置 | 变量/函数 |
|------|----------|
| Primary Surface数据 | qxl->guest_primary.data |
| 本地显示 | qxl_blit()读取 |
| SPICE路径 | qxl_ramfb_get_ptr()返回 |

## Guest侧要点

src_bitmap = ramfb_pa + rect_offset
src_area = {0, 0, height, width}
