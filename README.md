# openwrt-extend-disk

> 刷完固件，把硬盘没用完的空间用起来 —— 一条命令，交互式选盘、选分区、扩分区 / 建新分区 / 接管 `/overlay`。

适用于 **OpenWrt / ImmortalWrt / iStoreOS / LEDE / Armbian 以及任意 Linux**。不写死磁盘名和分区号，认不出的环境也不会瞎动手。

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s
```

粘贴执行即可，全程中文菜单。所有改动动手前都会打印完整计划并要求输入 `YES`。

---

## 它解决的是什么问题

OpenWrt 的官方 combined 镜像（`*-squashfs-combined.img.gz` 之类）是**固定尺寸**的，一般只有 1 GB 左右。你把它写进 4 GB / 8 GB / 16 GB 的虚拟机磁盘、U 盘、SSD，尾部一大片空间根本没人用：

```
Disk /dev/vda: 16 GiB
Device     Start      End  Sectors Size
/dev/vda1    512    66047    65536  32M
/dev/vda2  66048  2163199  2097152   1G     <- 到这里就没了
                                          ↑ 剩下 15G 全是空闲，但系统不认识
```

更麻烦的是：**p2 是 squashfs，只读、扩不了**。所以「扩容」这件事在 OpenWrt 上不是 `resize2fs` 一句话能解决的，正确解法只有两条：

1. **新建一个分区，接管 `/overlay`** —— 你的插件、配置、软件包都活在 `/overlay/upper` 里，搬到新分区后容量等于整盘剩余空间，而且升级固件时只重写 p1/p2，这块数据安然无恙。
2. **新建一个分区当数据盘** —— 挂到 `/mnt/xxx`，存镜像、备份、容器数据。

本脚本把这两条路 + 「普通 Linux 上扩 ext4 分区」都做成菜单，选一下就行。

---

## 菜单流程

```
[1/4] 扫描硬盘
  NO  磁盘              容量        分区表
  1   /dev/vda          16.0 GiB    GPT
  2   /dev/sda           8.0 GiB    DOS/MBR
  选择磁盘 [1-2, q 退出]: 1

[2/4] /dev/vda 分区表
  NO  设备          起始        结束       大小      文件系统   标签          挂载点
  1   /dev/vda1     512         66047      32 MiB    vfat       -             /boot
  2   /dev/vda2     66048       2163199    1024 MiB  squashfs   -             /rom
  3   /dev/vda3     2164736     10483711   4048 MiB  ext4       IMMO_OVERLAY  /overlay
  尾部空闲: 0 MiB（已铺满）

[3/4] 选择动作
  1) 扩容已有分区（ext4 / xfs / btrfs / f2fs，支持在线扩，不用重启）
  2) 用剩余空间新建分区（可填 label，可挂到 /mnt/xxx 并写 fstab）
  3) 新建分区并接管为 /overlay（自动搬现有插件层，重启后生效）
```

---

## 三种动作的区别

| 动作 | 效果 | 需要重启 | 典型场景 |
|---|---|---|---|
| `1` 扩容已有分区 | 只改分区的**结尾**，起点不动；随后 `resize2fs` / `xfs_growfs` / `btrfs resize` / `f2fs` 在线扩 | 否（ext4/xfs/btrfs）；f2fs 需重挂 | 普通 Linux / Armbian 根分区没吃满 |
| `2` 新建分区 | 用尾部空闲建一个新分区，可选 label、可选写 fstab 挂到 `/mnt/xxx` | 否（挂载立刻生效） | 想要一块独立数据盘；OpenWrt 刷完镜像后最常见 |
| `3` 新建分区接管 `/overlay` | 建分区 → 格式化 ext4 → 把当前 `overlay/upper` 整体复制过去 → 写 label fstab | 是 | 插件装爆了 1G overlay，要彻底解决 |

动作 3 的关键细节：fstab 里用的是 **label**（`IMMO_OVERLAY`）而不是 `/dev/vda3`，因为设备名会随磁盘顺序、内核枚举变化，label 不会。

---

## 非交互用法（脚本化 / 批量）

```sh
sh extend-disk.sh --list                                      # 列出所有磁盘
sh extend-disk.sh --disk /dev/sda --info                      # 看某块盘的分区表
sh extend-disk.sh --disk /dev/sda --resize 3 --yes            # 扩第 3 个分区（序号见 --info）
sh extend-disk.sh --disk /dev/sda --new --label DATA --mount /mnt/data --yes
sh extend-disk.sh --disk /dev/sda --new --label IMMO_OVERLAY --as-overlay --yes
```

| 参数 | 说明 |
|---|---|
| `--list` | 只列磁盘，不做任何事 |
| `--disk <dev>` | 指定磁盘，省略则进交互选择 |
| `--info` | 打印该盘分区表后退出 |
| `--resize <n>` | 扩分区序号 `n` 到盘尾（或到下一个分区起点前） |
| `--new` | 用尾部空闲建新分区 |
| `--label <s>` | 新分区的 label |
| `--mount <path>` | 把新分区挂到该路径并写 fstab |
| `--as-overlay` | 新分区接管 `/overlay`（会复制 upper，需 reboot） |
| `--yes` | 跳过 `YES` 确认（危险，用于自动化） |

---

## 支持的文件系统

| 分区上的文件系统 | 能否扩 | 怎么扩 |
|---|---|---|
| ext2 / ext3 / ext4 | 能 | `resize2fs`，在线 |
| xfs | 能 | `xfs_growfs`，在线 |
| btrfs | 能 | `btrfs filesystem resize`，在线 |
| f2fs | 能 | `resize.f2fs`（需先卸载/重挂） |
| vfat / ntfs / exfat | 不能 | 脚本直接提示：换用菜单 2 新建 |
| **squashfs** | **不能** | 只读文件系统，物理上没得扩 → 走菜单 2 / 3 |
| iso9660 | 不能 | 同上 |

脚本在选到不可扩的分区时会**直接拦下来并给出替代路径**，不会强行 `resize2fs` 把系统搞坏。

---

## 安全设计

这几条是踩过坑才加上的，也是它能用在「不止一个固件」上的原因：

1. **只往后延伸，从不往前挪**。扩容只改分区结束扇区，起点一个字节不动，所以不会碰分区里的数据。
2. **绝不覆盖后面的分区**。目标分区后面如果有别的分区，最多扩到「下一个分区起点 − 1 扇区」。
3. **尾部统一预留 34 扇区**（GPT 备份表用）。不去探测「这是 GPT 还是 MBR 再决定留多少」，因为误判成 MBR 后写到盘尾最后一扇区，正好把 GPT 备份表写坏 —— 表现就是**重启后磁盘突然不存在**。MBR 上白留 17 KB，代价忽略不计。
4. **不预测新分区设备名**。建分区前后对比 `/sys/class/block/` 的节点差集，找出真正新增的那个，避免 `/dev/sda4` 猜错。
5. **交互读 `/dev/tty`**。这样 `wget | sh -s` 管道执行时依然能正常问答（普通 `read` 在管道里会读到空值）。
6. **再确认一次**。执行前打印完整计划（磁盘、分区、起止扇区、大小、动作），要手输 `YES` 才动。全脚本**没有任何删除分区的代码路径**。

---

## 依赖

脚本本身零依赖，但执行动作需要工具，缺了会提示：

```sh
# OpenWrt / ImmortalWrt（25.x 用 apk）
apk add parted e2fsprogs e2fsprogs-extra

# OpenWrt（24.x 及更早，用 opkg）
opkg install parted e2fsprogs resize2fs

# Debian / Ubuntu / Armbian
apt install -y parted e2fsprogs xfsprogs f2fs-tools
```

只跑 `--list` / `--info` 不需要装任何东西。

---

## FAQ

**扩完了，`df` 还是老大小？**
分区表扩了但文件系统没扩。重跑一次动作 1（脚本会检测到分区已经是目标大小，然后只补 `resize2fs`），或手动 `resize2fs /dev/vda3`。

**动作 3 做完重启，`/overlay` 还是原来的？**
`/etc/config/fstab` 里大概率还有一条**旧的、按 UUID 写的** `/overlay` 条目（sysupgrade 恢复配置时会带回来），两条并存时旧的先命中。删掉旧那条，只留 label 那条。

**squashfs 为什么不能扩？**
它不是普通块设备文件系统，是「压缩只读 + overlay 叠加」。扩分区没有意义，只能新建分区当 overlay。

**扩容后升级固件，数据还在吗？**
关键看升级时分区表跟固件内置镜像是否一致。不一致时 `sysupgrade` 会**全盘重写**（`Partition layout has changed. Full image will be written.`），独立分区就没了。所以升级前建议先体检：

```sh
sysupgrade -T /path/to/新固件.img.gz
```

输出里出现 `Partition layout has changed` 就是警告信号。配套的 `img-installer` 仓库里有 `extroot.sh verify` 做这件事。

**盘上有多个分区，怎么知道扩哪个？**
先 `--info` 看表格里的「NO」列，那个序号就是 `--resize` 的参数。

**支持 MBR 吗？**
支持。GPT/MBR 都会识别（表格「分区表」列会显示），只是尾部一律按 GPT 的规矩留 34 扇区。

---

## 和 img-installer 的关系

| 场景 | 用哪个 |
|---|---|
| 全新刷机，希望装完就自动分好 overlay | [img-installer](https://github.com/loticc/img-installer) 的 Custom2 安装器 |
| 已经刷好、一条命令无脑搞定 | img-installer 里的 `extroot.sh` |
| 已经刷好、想自己看着选盘选分区 | **本仓库 `extend-disk.sh`** |

本仓库是从 img-installer 里拆出来的独立工具，专注「盘没吃满」这一件事，可以脱离安装器单独用，也能用在非 OpenWrt 的 Linux 上。

---

## 目录结构

```
openwrt-extend-disk/
├── extend-disk.sh              # 主脚本，单文件，无依赖
├── README.md
├── LICENSE
├── .gitattributes              # 强制 LF，防 Windows 上传后 sh 报 ^M 错误
└── .github/workflows/lint.yml  # dash -n 语法检查
```

## License

MIT
