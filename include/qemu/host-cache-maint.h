/*
 * host-cache-maint.h -- 宿主侧 cache 维护助手（仅 aarch64 有效）
 *
 * 某些 ARM64 宿主平台（如 Phytium D2000）不保证
 * "host 与 guest 以不同内存属性（WB vs NC/Device）访问同一页内存"
 * 之间的一致性（ARM 规范中这属于 UNPREDICTABLE，鲲鹏 920 的互联
 * 实现恰好兜住了）。当 guest 侧软件无法修改时（如 Windows 自带的
 * hdaudbus、Basic Display 驱动），由 QEMU 在读写对应内存的前后做
 * 显式 cache 维护来兜底：
 *
 *   QEMU 写 -> guest 读：写完后 qemu_host_dcache_clean_poc()（dc cvac）
 *   guest 写 -> QEMU 读：读之前 qemu_host_dcache_invalidate_poc()（dc civac）
 *
 * dc civac 先 clean 再 invalidate，即使对方是 WB 写也不会丢数据。
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 */
#ifndef QEMU_HOST_CACHE_MAINT_H
#define QEMU_HOST_CACHE_MAINT_H

#if defined(__aarch64__)

static inline uintptr_t qemu_host_dcache_line_size(void)
{
    static uintptr_t line_size;

    if (unlikely(!line_size)) {
        uint64_t ctr;

        asm volatile("mrs %0, ctr_el0" : "=r"(ctr));
        /* CTR_EL0.DminLine：log2(字数)，每字 4 字节 */
        line_size = 4ULL << ((ctr >> 16) & 0xf);
    }
    return line_size;
}

static inline void qemu_host_dcache_maint_poc(const void *ptr, size_t len,
                                              bool invalidate)
{
    uintptr_t line = qemu_host_dcache_line_size();
    uintptr_t start = (uintptr_t)ptr & ~(line - 1);
    uintptr_t end = ((uintptr_t)ptr + len + line - 1) & ~(line - 1);
    uintptr_t p;

    for (p = start; p < end; p += line) {
        if (invalidate) {
            asm volatile("dc civac, %0" :: "r"(p) : "memory");
        } else {
            asm volatile("dc cvac, %0" :: "r"(p) : "memory");
        }
    }
    asm volatile("dsb sy" ::: "memory");
}

#else

static inline void qemu_host_dcache_maint_poc(const void *ptr, size_t len,
                                              bool invalidate)
{
}

#endif

/* QEMU 写入 guest RAM 之后调用：clean 到 PoC，保证 guest 非缓存读可见 */
static inline void qemu_host_dcache_clean_poc(const void *ptr, size_t len)
{
    qemu_host_dcache_maint_poc(ptr, len, false);
}

/* QEMU 读取 guest 刚写入的 RAM 之前调用：丢弃旧缓存行，强制从 DRAM 取 */
static inline void qemu_host_dcache_invalidate_poc(const void *ptr, size_t len)
{
    qemu_host_dcache_maint_poc(ptr, len, true);
}

#endif
