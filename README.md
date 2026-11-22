# openwrt-extend-disk

**项目地址：** https://github.com/loticc/openwrt-extend-disk
**脚本直链：** https://raw.githubusercontent.com/loticc/openwrt-extend-disk/main/extend-disk.sh
**CDN 加速：** https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh

> 刷完固件，把硬盘没用完的空间用起来 —— 一条命令，交互式选盘、选分区、扩分区 / 建新分区 / 接管 `/overlay`。

适用于 **OpenWrt / ImmortalWrt / iStoreOS / LEDE / Armbian 以及任意 Linux**。不写死磁盘名和分区号，认不出的环境也不会瞎动手。

---

## 目录

- [一键命令大全（直接复制）](#一键命令大全直接复制)
- [三种动作选哪个（先看这里）](#三种动作选哪个先看这里)
- [它解决的是什么问题](#它解决的是什么问题)
- [菜单流程](#菜单流程)
- [参数表](#参数表)
- [支持的文件系统](#支持的文件系统)
- [安全设计](#安全设计)
- [FAQ](#faq)

---

## 一键命令大全（直接复制）

下面每一段都是**独立完整**的，整行复制粘贴执行即可。所有命令里的 `/dev/vda` 换成你机器上真实的磁盘名（`--list` 里显示的那一列）。

### ① 一键执行（推荐，CDN 加速）

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s
```

### ② 一键执行（GitHub 原始直链）

```sh
wget -qO- https://raw.githubusercontent.com/loticc/openwrt-extend-disk/main/extend-disk.sh | sh -s
```

### ③ 先存本地再执行（可反复重跑，长期用推荐这个）

```sh
wget -qO /root/extend-disk.sh https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh && chmod +x /root/extend-disk.sh && sh /root/extend-disk.sh
```

存好之后，后面所有功能都不用再联网：

```sh
sh /root/extend-disk.sh                                        # 交互菜单
sh /root/extend-disk.sh --list                                 # 只体检
sh /root/extend-disk.sh --disk /dev/vda --info                 # 看某块盘的分区表
```

### ④ 只体检、绝不动手（每块新盘第一步）

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --list
```

### ⑤ 看指定磁盘的分区表和尾部空闲

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --info
```

### ⑥ 动作 1：扩容已有分区到盘尾

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --resize 3 --yes
```

> `3` 是这个分区的**序号**（`--info` 表格里 NO 列那个数字），不是分区设备号。

### ⑦ 动作 2：用剩余空间新建数据分区

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --new --label DATA --mount /mnt/data --yes
```

### ⑧ 动作 3：新建分区并接管 `/overlay`（执行完必须重启）

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --new --label IMMO_OVERLAY --as-overlay --yes
```

### ⑨ 装依赖 —— OpenWrt 25.x（apk）

```sh
apk update && apk add parted e2fsprogs e2fsprogs-extra
```

### ⑩ 装依赖 —— OpenWrt 24.x 及更早（opkg）

```sh
opkg update && opkg install parted e2fsprogs resize2fs
```

### ⑪ 装依赖 —— Debian / Ubuntu / Armbian

```sh
apt update && apt install -y parted e2fsprogs xfsprogs f2fs-tools
```

第 ⑨⑩⑪ 三条**只跑跟你系统对应的那一条**，不要全跑。

---

## 三种动作选哪个（先看这里）

菜单里的 `1 / 2 / 3` 对应三种结果，搞错方向的代价是白干一次甚至系统起不来。先按这张表定位：

| 你的情况 | 选哪个 | 一句话原因 |
|---|---|---|
| **OpenWrt 系固件（ImmortalWrt / iStoreOS / LEDE / 官方 OpenWrt），刷完镜像后盘没吃满** | **动作 3** | 这是唯一能同时解决「盘没用完」和「插件空间只有 1G」的方案 |
| OpenWrt 系，只想多一块存东西的盘（镜像、备份、容器数据） | 动作 2 | 不动 `/overlay`，风险最低 |
| Armbian / Debian / 普通 Linux，根分区没吃满 | 动作 1 | 根分区是 ext4，直接往后扩就行 |
| Custom2 安装器已经自动分好 overlay 分区了 | 哪个都不用 | 安装时已经处理过，只需在磁盘调大后做一次扩容 |

### 为什么 OpenWrt 上「动作 1」基本用不上

OpenWrt 的分区通常是：`p1` 引导、`p2` 系统（**squashfs，只读**）、`p3` 数据分区。squashfs 是「压缩只读 + overlay 叠加」的文件系统，**物理上没法扩容**——它不是普通块设备文件系统，`resize2fs` 对它无效。

你在菜单里选 1 并选中 p2 时，脚本会直接拦住并提示你走 2 或 3。这不是限制，是防止你把系统扩成砖。

**只有 p2 是 ext4 的固件（少数自编译、或改过 rootfs 格式的）才能在 OpenWrt 上用动作 1。**

### 推荐路径：动作 3（绝大多数人该走这条）

这是解决「刷完固件盘没吃满 + 插件装不下」的标准答案。原理：你的插件、配置、软件包全都活在 `/overlay/upper` 里，把这个目录整体搬到新分区，`/overlay` 就变成整盘剩余空间那么大，而且升级固件时只重写 p1/p2，这块数据不受影响。

**具体怎么用**

第一步，先看清现状（只读，不动任何东西）：

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --list
```

输出里确认三件事：磁盘名（比如 `/dev/vda`）、容量、尾部空闲是不是你说的那几 G。

第二步，装依赖（第一次用才需要）：

```sh
apk update && apk add parted e2fsprogs e2fsprogs-extra
```

第三步入菜单，按提示选：

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s
```

顺序是：选磁盘 → 看分区表 → 动作选 `3` → 填 label（不填就用默认 `IMMO_OVERLAY`）→ 核对计划，输入 `YES`。

中间它会做四件事：建分区 → 格式化成 ext4 → 把当前 `upper` 整个复制过去 → 往 `/etc/config/fstab` 写一条**按 label 挂载**的条目（不是按 `/dev/vda3`，因为设备名会变，label 不会）。

第四步，**手动重启**：

```sh
reboot
```

第五步，验证成功了没有（这条最硬，别看别的）：

```sh
grep overlay /proc/mounts
```

- 看到 `/dev/vda3 ... /overlay`（或你新分区的设备名）→ **成功**
- 还看到 `/dev/loop0 ... /overlay` → **没生效**，去查 `/etc/config/fstab` 里是不是留着一条旧的 UUID 条目，删掉它

再确认一下容量：

```sh
df -h /overlay
```

容量应该是整盘剩余空间，而不是原来的 1007M。

**这一步踩坑预警**：`sysupgrade` 恢复配置时会把你以前的 fstab 带回来，里面可能有一条**旧 UUID 写的 `/overlay`**。两条并存时旧的先命中，表现就是「明明搬了，重启后还是老容量」。删掉旧那条（只留 label 那条）再重启即可。

### 动作 2 怎么用（只要数据盘、不想动 overlay）

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --new --label DATA --mount /mnt/data --yes
```

或者进菜单选 `2`，按提示填 label 和挂载点（挂载点可以留空，那就只建分区不挂）。

做完的验证：

```sh
blkid | grep DATA
df -h /mnt/data
```

分区立刻可用，**不需要重启**。如果填了挂载点，脚本会同时写进 fstab，重启后自动挂上。

### 动作 1 怎么用（普通 Linux 根分区没吃满）

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --info
```

先看 `--info` 表格，找到你要扩的分区的 NO 序号（比如根分区是 `2`），然后：

```sh
wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s -- --disk /dev/vda --resize 2 --yes
```

脚本会改分区结尾 → 自动跑 `resize2fs`（ext4）/ `xfs_growfs`（xfs）/ `btrfs resize`。ext4/xfs/btrfs **在线扩，不用重启、不用卸载**。

验证：

```sh
df -h /
```

如果 `df` 没变，说明分区表扩了但文件系统没跟上的情况极少见（通常是 `resize2fs` 失败），手动补一次：

```sh
resize2fs /dev/vda2
```

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

更麻烦的是 p2 是 squashfs 只读、扩不了，所以「扩容」在 OpenWrt 上不是一句 `resize2fs` 能解决的。

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

交互读的是 `/dev/tty`，所以 `wget | sh -s` 这种管道执行也能正常问答。

---

## 参数表

| 参数 | 说明 |
|---|---|
| `--list` | 只列磁盘，不做任何事 |
| `--disk <dev>` | 指定磁盘，省略则进交互选择 |
| `--info` | 打印该盘分区表后退出 |
| `--resize <n>` | 扩分区序号 `n` 到盘尾（或到下一个分区起点前） |
| `--new` | 用尾部空闲建新分区 |
| `--label <s>` | 新分区的 label |
| `--mount <path>` | 把新分区挂到该路径并写 fstab |
| `--as-overlay` | 新分区接管 `/overlay`（复制 upper，需 reboot） |
| `--yes` | 跳过 `YES` 确认（用于自动化，**确认路径正确再用**） |

---

## 支持的文件系统

| 分区上的文件系统 | 能否扩 | 怎么扩 |
|---|---|---|
| ext2 / ext3 / ext4 | 能 | `resize2fs`，在线 |
| xfs | 能 | `xfs_growfs`，在线 |
| btrfs | 能 | `btrfs filesystem resize`，在线 |
| f2fs | 能 | `resize.f2fs`（需先卸载/重挂） |
| vfat / ntfs / exfat | 不能 | 脚本直接提示：换用动作 2 新建 |
| **squashfs** | **不能** | 只读文件系统，物理上没得扩 → 走动作 2 / 3 |
| iso9660 | 不能 | 同上 |

---

## 安全设计

1. **只往后延伸，从不往前挪**。扩容只改分区结束扇区，起点一个字节不动。
2. **绝不覆盖后面的分区**。目标分区后面还有别的分区时，最多扩到「下一个分区起点 − 1 扇区」。
3. **尾部统一预留 34 扇区**给 GPT 备份表。不去猜「这是 GPT 还是 MBR 再决定留多少」，因为误判成 MBR 后写到盘尾最后一扇区，正好把 GPT 备份表写坏 —— 表现就是**重启后磁盘突然不存在**。MBR 上白留 17 KB，代价忽略不计。
4. **不预测新分区设备名**。建分区前后对比 `/sys/class/block/` 的节点差集，找出真正新增的那个。
5. **交互读 `/dev/tty`**，管道执行也能问答。
6. **再确认一次**。执行前打印完整计划（磁盘、分区、起止扇区、大小、动作），要手输 `YES`。全脚本**没有任何删除分区的代码路径**。

---

## FAQ

**扩完了，`df` 还是老大小？**
分区表扩了但文件系统没扩。手动补 `resize2fs /dev/vda2`，或重跑动作 1（脚本检测到分区已是目标大小就只补文件系统）。

**动作 3 做完重启，`/overlay` 还是原来的？**
`/etc/config/fstab` 里大概率还有一条**旧的、按 UUID 写的** `/overlay` 条目（sysupgrade 恢复配置时带回来），两条并存时旧的先命中。`cat /etc/config/fstab` 看一眼，删掉旧那条只留 label 那条，重启。

**怎么一眼判断动作 3 到底成没成？**
`grep overlay /proc/mounts`。显示 `/dev/vda3`（或其它真实设备）= 成了；显示 `/dev/loop0` = 还在镜像内部的 f2fs 回环，没成。

**squashfs 为什么不能扩？**
它不是普通块设备文件系统，是「压缩只读 + overlay 叠加」。扩分区没有意义，只能新建分区当 overlay。

**扩容后升级固件，数据还在吗？**
关键看升级时分区表跟固件内置镜像是否一致。不一致时 `sysupgrade` 会**全盘重写**（`Partition layout has changed. Full image will be written.`），独立分区就没了。升级前先体检：

```sh
sysupgrade -T /path/to/新固件.img.gz
```

输出里出现 `Partition layout has changed` 就是警告信号。配套的 [img-installer](https://github.com/loticc/img-installer) 仓库里有 `extroot.sh verify` 专门做这件事。

**盘上有多个分区，怎么知道扩哪个？**
`--info` 表格里的 NO 列，那个序号就是 `--resize` 的参数。

**支持 MBR 吗？**
支持。GPT/MBR 都会识别（「分区表」列显示），只是尾部一律按 GPT 的规矩留 34 扇区。

**多个硬盘怎么办？**
菜单第一步就是选盘；非交互模式用 `--disk` 指定。脚本一次只操作你选的那一块，不会碰其它盘。

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

## 相关链接

- 项目主页：https://github.com/loticc/openwrt-extend-disk
- 脚本直链：https://raw.githubusercontent.com/loticc/openwrt-extend-disk/main/extend-disk.sh
- CDN 加速：https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh
- 配套安装器：[loticc/img-installer](https://github.com/loticc/img-installer)（Custom2 一键刷机 + 自动分 overlay）
- 上游来源：[wukongdaily/img-installer](https://github.com/wukongdaily/img-installer)
- 问题反馈：https://github.com/loticc/openwrt-extend-disk/issues

## License

MIT
