#!/bin/sh
# ==========================================================================
#  extend-disk.sh  ——  OpenWrt / Armbian / 任意 Linux：把硬盘没用完的空间用起来
#  version 1.0.0   |   https://github.com/loticc/openwrt-extend-disk
#
#  一句话执行（不用先下载）：
#     wget -qO- https://cdn.jsdelivr.net/gh/loticc/openwrt-extend-disk@main/extend-disk.sh | sh -s
#
#  它做什么
#     · 扫描所有硬盘，列出容量、分区表类型、每个分区的起止/大小/文件系统/挂载点
#     · 算出每块盘“尾部还有多少空间没被任何分区占用”
#     · 让你选：① 扩展现有分区（ext4/xfs/btrfs/f2fs，支持在线扩）
#              ② 把剩余空间建成新分区（OpenWrt 刷完镜像后最常见的情况）
#              ③ 建成新分区并直接接管为 /overlay（自动迁移现有插件层）
#
#  为什么 OpenWrt 需要 ② / ③
#     官方 combined 镜像是 1GB 左右的固定尺寸，写进大盘后尾部全是空闲；
#     而 p2 是 squashfs 只读，**扩不了**。所以正确做法是新建一个分区当 overlay，
#     插件放进去，升级固件时只重写 p1/p2，这个分区不受影响。
#
#  非交互用法（脚本化 / 批量）
#     sh extend-disk.sh --list
#     sh extend-disk.sh --disk /dev/sda --info
#     sh extend-disk.sh --disk /dev/sda --resize 3 --yes
#     sh extend-disk.sh --disk /dev/sda --new --label DATA --mount /mnt/data --yes
#     sh extend-disk.sh --disk /dev/sda --new --label IMMO_OVERLAY --as-overlay --yes
#
#  安全约定
#     · 不做任何“删除分区”动作；扩容只改分区的“结尾”，不动起点
#     · 新建分区前会打印完整计划并要求输入 YES
#     · ext4/xfs 在线扩，不需要重启；③ 接管 /overlay 需要 reboot
# ==========================================================================

set -u

AS_OVERLAY=0
DO_YES=0
OPT_DISK=""
OPT_ACTION=""
OPT_PART=""
OPT_LABEL=""
OPT_MOUNT=""

tty_in() {
    if [ -r /dev/tty ]; then
        read -r "$@" </dev/tty
    else
        read -r "$@"
    fi
}

say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
ok()   { printf '  [OK] %s\n' "$*"; }

[ "$(id -u)" = "0" ] || die "需要 root 运行"

# ---------------------------------------------------------------- 基础读取

sectors_of() { cat "/sys/class/block/${1##*/}/size" 2>/dev/null; }

human2() {
    _b="$1"
    if   [ "$_b" -ge 1073741824 ]; then awk -v v="$_b" 'BEGIN{printf "%.1f GiB", v/1073741824}'
    elif [ "$_b" -ge 1048576 ];    then awk -v v="$_b" 'BEGIN{printf "%.0f MiB", v/1048576}'
    else awk -v v="$_b" 'BEGIN{printf "%.0f KiB", v/1024}'
    fi
}

pttype() {   # 只读探测，用于显示；判断不出来返回 ?
    _d="$1"
    if command -v parted >/dev/null 2>&1; then
        if parted -s "$_d" print 2>/dev/null | grep -qi "Partition Table: gpt"; then
            echo GPT; return 0
        fi
    fi
    if command -v fdisk >/dev/null 2>&1; then
        if fdisk -l "$_d" 2>/dev/null | grep -qi "disklabel type: gpt"; then
            echo GPT; return 0
        fi
        if fdisk -l "$_d" 2>/dev/null | grep -qi "disklabel type: dos"; then
            echo "DOS/MBR"; return 0
        fi
    fi
    echo "?"
}

fs_of() {
    _p="$1"
    _mm=$(cat "/sys/class/block/${_p##*/}/dev" 2>/dev/null)
    # 1) 已挂载的分区：直接从 mountinfo 拿 fstype（最准，且不用碰原始扇区）
    if [ -n "${_mm:-}" ]; then
        _t=$(awk -v mm="$_mm" '$3==mm{for(i=1;i<=NF;i++) if($i=="-"){print $(i+1); exit}}' \
             /proc/self/mountinfo 2>/dev/null)
        [ -n "$_t" ] && { echo "$_t"; return; }
    fi
    # 2) blkid
    if command -v blkid >/dev/null 2>&1; then
        _t=$(blkid -o value -s TYPE "$_p" 2>/dev/null)
        [ -n "$_t" ] && { echo "$_t"; return; }
    fi
    _t=$(busybox blkid "$_p" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
    [ -n "$_t" ] && { echo "$_t"; return; }
    echo "?"
}

label_of() {
    _p="$1"
    if command -v blkid >/dev/null 2>&1; then
        _l=$(blkid -o value -s LABEL "$_p" 2>/dev/null)
        [ -n "$_l" ] && { echo "$_l"; return; }
    fi
    busybox blkid "$_p" 2>/dev/null | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p'
}

mount_of() {
    _p="$1"
    _mm=$(cat "/sys/class/block/${_p##*/}/dev" 2>/dev/null)
    [ -n "${_mm:-}" ] || return 0
    # 用 major:minor 匹配，能认出 /rom 这种 source 显示为 /dev/root 的挂载
    awk -v mm="$_mm" '$3==mm{print $5}' /proc/self/mountinfo 2>/dev/null | head -n1
}

parent_disk_of() {  # /dev/vda3 -> /dev/vda
    _p="${1##*/}"
    [ -e "/sys/class/block/$_p" ] || return 1
    _par=$(dirname "$(readlink -f "/sys/class/block/$_p")")
    printf '/dev/%s' "$(basename "$_par")"
}

is_whole_disk() {
    _n="$1"
    [ -e "/sys/class/block/$_n" ] || return 1
    [ -f "/sys/class/block/$_n/partition" ] && return 1   # 有 partition 文件=分区
    case "$_n" in
        loop*|ram*|zram*|dm-*|md*|sr*) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 磁盘/分区列表

list_disks() {   # 输出：设备名 每行一个，带序号信息由调用方处理
    for _d in /sys/class/block/*; do
        _n=$(basename "$_d")
        is_whole_disk "$_n" || continue
        _sz=$(sectors_of "$_n")
        [ -n "$_sz" ] || continue
        [ "$_sz" -gt 0 ] || continue
        printf '/dev/%s\n' "$_n"
    done
}

parts_of() {   # /dev/vda -> 按分区号升序输出 /dev/vdaN
    _disk="${1##*/}"
    for _d in /sys/class/block/*; do
        [ -f "$_d/partition" ] || continue
        _n=$(basename "$_d")
        _pd=$(basename "$(dirname "$(readlink -f "$_d")")")
        [ "$_pd" = "$_disk" ] || continue
        _num=$(cat "$_d/partition" 2>/dev/null)
        [ -n "$_num" ] || continue
        printf '%03d\t/dev/%s\n' "$_num" "$_n"
    done | sort | cut -f2
    return 0
}

tail_end() {   # 磁盘最后可用扇区：统一给 GPT 备份表预留 34 扇区（MBR 上牺牲 17KB 无影响）
    _sz=$(sectors_of "$1")
    echo $(( _sz - 34 ))
}

show_disk_table() {   # $1=/dev/vda
    _disk="$1"
    _dsz=$(sectors_of "$_disk")
    _model=$(cat "/sys/class/block/${_disk##*/}/device/model" 2>/dev/null | sed 's/[[:space:]]*$//')
    [ -n "$_model" ] || _model="-"
    say ""
    say "磁盘 $_disk   $(human2 $(( _dsz * 512 )))   $_model   $(pttype "$_disk")"

    printf '  %-3s %-13s %-9s %-9s %-9s %-6s %-9s %-14s %s\n' \
        "NO" "分区" "起始" "结束" "大小" "#" "文件系统" "标签" "挂载点"
    _n=0
    _maxend=0
    for _p in $(parts_of "$_disk"); do
        _name="${_p##*/}"
        _st=$(cat "/sys/class/block/${_name}/start" 2>/dev/null)
        _sz=$(sectors_of "$_name")
        _ed=$(( _st + _sz - 1 ))
        _fs=$(fs_of "$_p")
        _lbl=$(label_of "$_p")
        _mnt=$(mount_of "$_p")
        _pn=$(cat "/sys/class/block/${_name}/partition" 2>/dev/null)
        printf '  %-3s %-13s %-9s %-9s %-9s %-6s %-9s %-14s %s\n' \
            "$_n" "$_p" "$_st" "$_ed" "$(human2 $(( _sz * 512 )))" "$_pn" \
            "$_fs" "${_lbl:--}" "${_mnt:-未挂载}"
        _n=$(( _n + 1 ))
        [ "$_ed" -gt "$_maxend" ] && _maxend=$_ed
    done
    _te=$(tail_end "$_disk")
    _free=$(( _te - _maxend ))
    if [ "$_free" -le 0 ]; then
        say "  尾部空闲: 0 MiB（已铺满）"
    else
        say "  尾部空闲: $(( _free * 512 / 1048576 )) MiB（扇区 $(( _maxend + 1 )) - $_te）"
    fi
    [ "$_free" -gt 0 ] || warn "这块盘已经铺满，没有可扩容空间"
    return 0
}

# ---------------------------------------------------------------- 交互选择

choose_disk() {
    _i=0
    say ""
    say "=============================================================="
    say " 检测到的硬盘"
    say "=============================================================="
    for _d in $(list_disks); do
        _i=$(( _i + 1 ))
        _sz=$(sectors_of "$_d")
        _model=$(cat "/sys/class/block/${_d##*/}/device/model" 2>/dev/null | sed 's/[[:space:]]*$//')
        printf '  %2d) %-12s %-10s %-6s %s\n' "$_i" "$_d" "$(human2 $(( _sz * 512 )))" "$(pttype "$_d")" "${_model:--}"
        eval "_DISK_$_i=\"$_d\""
    done
    [ "$_i" -gt 0 ] || die "没有检测到可用硬盘"
    say ""
    printf '选择硬盘 [1-%d]: ' "$_i"
    tty_in _c
    case "$_c" in
        ''|*[!0-9]*) die "输入无效" ;;
    esac
    [ "$_c" -ge 1 ] && [ "$_c" -le "$_i" ] || die "超出范围"
    eval "printf '%s' \"\$_DISK_$_c\""
}

choose_part_index() {   # $1=disk  返回序号（0 起）
    _n=0
    for _p in $(parts_of "$1"); do
        _n=$(( _n + 1 ))
    done
    [ "$_n" -gt 0 ] || die "这块盘没有分区"
    say ""
    printf '选择要操作的分区序号 [0-%d]（就是上面表格里的 NO）: ' "$(( _n - 1 ))"
    tty_in _c
    case "$_c" in
        ''|*[!0-9]*) die "输入无效" ;;
    esac
    [ "$_c" -ge 0 ] && [ "$_c" -le "$(( _n - 1 ))" ] || die "超出范围"
    echo "$_c"
}

part_by_index() {   # $1=disk $2=index
    _i=0
    for _p in $(parts_of "$1"); do
        if [ "$_i" = "$2" ]; then
            echo "$_p"
            return 0
        fi
        _i=$(( _i + 1 ))
    done
    return 1
}

confirm_yes() {   # $1=提示
    if [ "$DO_YES" = "1" ]; then
        ok "已用 --yes 跳过确认"
        return 0
    fi
    say ""
    say "$1"
    printf '确认继续请输入 YES : '
    tty_in _ans
    [ "$_ans" = "YES" ] || { say "已取消"; return 1; }
    return 0
}

ensure_tool() {   # $1=命令 $2=apk包 $3=opkg包
    command -v "$1" >/dev/null 2>&1 && return 0
    say "  安装 $2 ..."
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$2" >/dev/null 2>&1 || apk add "$2" >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install "$3" >/dev/null 2>&1
    fi
    command -v "$1" >/dev/null 2>&1
}

reread() {   # $1=disk $2=part
    partprobe "$1" >/dev/null 2>&1 || true
    partx -u "$2" >/dev/null 2>&1 || true
    sync
    sleep 1
}

# ---------------------------------------------------------------- 动作 1：扩容已有分区

act_resize() {
    _disk="$1"
    _part="$2"
    _name="${_part##*/}"
    _st=$(cat "/sys/class/block/${_name}/start" 2>/dev/null)
    _sz=$(sectors_of "$_name")
    _ed=$(( _st + _sz - 1 ))
    _fs=$(fs_of "$_part")
    _mnt=$(mount_of "$_part")

    case "$_fs" in
        squashfs|iso9660|vfat|ufs|"?"|"")
            warn "$_part 的文件系统类型是 ${_fs}，不支持在线扩容"
            say ""
            say "  OpenWrt 的 p2 是 squashfs 只读分区，本来就扩不了；"
            say "  正确做法是用【剩余空间新建分区当 /overlay】→ 菜单选 2 或 3。"
            return 1
            ;;
    esac

    _te=$(tail_end "$_disk")
    # 后面还有别的分区？只能扩到最近的那个分区的起点之前
    for _p in $(parts_of "$_disk"); do
        _pn="${_p##*/}"
        _ps=$(cat "/sys/class/block/${_pn}/start" 2>/dev/null)
        if [ "$_ps" -gt "$_ed" ]; then
            _te=$(( _ps - 1 ))
            break
        fi
    done
    _free=$(( _te - _ed ))
    if [ "$_free" -le 2048 ]; then
        warn "$_part 后面没有可扩展空间（空闲 $(( _free * 512 / 1048576 )) MiB）"
        return 1
    fi

    say ""
    say "计划扩容："
    say "  分区        : $_part ($_fs, 挂载点 ${_mnt:-未挂载})"
    say "  当前大小    : $(human2 $(( _sz * 512 )))  (扇区 $_st - $_ed)"
    say "  扩容后大小  : $(human2 $(( (_free + _sz) * 512 )))  (扇区 $_st - $_te)"
    say "  文件系统    : $_fs（在线扩容，不需要重启）"

    confirm_yes "确认要把 $_part 扩到扇区 $_te 吗？" || return 1

    # GPT 备份表如果不在盘尾，先挪过去（磁盘变大后常见）
    if [ "$(pttype "$_disk")" = "GPT" ] && command -v sgdisk >/dev/null 2>&1; then
        sgdisk -e "$_disk" >/dev/null 2>&1 || true
    fi

    _pnum=$(cat "/sys/class/block/${_name}/partition" 2>/dev/null)
    [ -n "$_pnum" ] || die "读不到 $_part 的分区号"
    ensure_tool parted parted parted || die "需要 parted（apk add parted / opkg install parted）"

    say "[1/3] 调整分区结尾 ..."
    if ! parted -s "$_disk" unit s resizepart "$_pnum" "${_te}s" 2>/dev/null; then
        die "parted 修改分区失败（分区可能被占用或被容器锁定）"
    fi
    reread "$_disk" "$_part"

    say "[2/3] 扩展文件系统 ..."
    case "$_fs" in
        ext2|ext3|ext4)
            ensure_tool resize2fs e2fsprogs-extra e2fsprogs || die "需要 resize2fs（apk add e2fsprogs-extra）"
            resize2fs "$_part" || die "resize2fs 失败"
            ;;
        xfs)
            ensure_tool xfs_growfs xfsprogs xfsprogs || die "需要 xfs_growfs"
            [ -n "$_mnt" ] || die "xfs 必须在挂载状态下扩容，请先挂载 $_part"
            xfs_growfs "$_mnt" || die "xfs_growfs 失败"
            ;;
        btrfs)
            ensure_tool btrfs-progs btrfs-progs btrfs-progs || die "需要 btrfs"
            [ -n "$_mnt" ] || die "btrfs 需要挂载点"
            btrfs filesystem resize max "$_mnt" || die "btrfs resize 失败"
            ;;
        f2fs)
            ensure_tool resize.f2fs f2fs-tools f2fs-tools || die "需要 f2fs-tools"
            [ -n "$_mnt" ] && umount "$_mnt" 2>/dev/null
            resize.f2fs "$_part" || die "resize.f2fs 失败（f2fs 需卸载后扩容）"
            ;;
        *)
            die "不支持的文件系统: $_fs"
            ;;
    esac

    say "[3/3] 结果"
    _newsz=$(sectors_of "$_name")
    ok "分区现为 $(human2 $(( _newsz * 512 )))"
    [ -n "$_mnt" ] && df -h "$_mnt" 2>/dev/null | tail -n1
    return 0
}

# ---------------------------------------------------------------- 动作 2/3：新建分区

act_new() {
    _disk="$1"
    _label="${OPT_LABEL:-DATA}"
    _asovl="$AS_OVERLAY"

    _te=$(tail_end "$_disk")
    _maxend=0
    _maxpnum=0
    for _p in $(parts_of "$_disk"); do
        _pn="${_p##*/}"
        _ps=$(cat "/sys/class/block/${_pn}/start" 2>/dev/null)
        _pz=$(sectors_of "$_pn")
        _pe=$(( _ps + _pz - 1 ))
        [ "$_pe" -gt "$_maxend" ] && _maxend=$_pe
        _num=$(cat "/sys/class/block/${_pn}/partition" 2>/dev/null)
        if [ -n "$_num" ] && [ "$_num" -gt "$_maxpnum" ]; then
            _maxpnum=$_num
        fi
    done

    # 起点对齐 2048 扇区（1MiB）
    _start=$(( ((_maxend + 1 + 2047) / 2048) * 2048 ))
    # 给固件镜像尾部的备份 GPT 留余量：至少 34 扇区，已含在 tail_end
    _avail=$(( _te - _start + 1 ))
    if [ "$_avail" -lt $(( 300 * 2048 )) ]; then
        die "剩余空间不足 300MiB（$(( _avail * 512 / 1048576 )) MiB），无法新建分区"
    fi
    _newnum=$(( _maxpnum + 1 ))
    [ "$_newnum" -gt 128 ] && _newnum=128
    _newpart_pred="${_disk}${_newnum}"
    case "$_disk" in
        *[0-9]) _newpart_pred="${_disk}p${_newnum}" ;;
    esac
    _newpart="$_newpart_pred"

    say ""
    say "计划新建分区："
    say "  磁盘        : $_disk ($(pttype "$_disk"))"
    say "  新分区      : 约 $_newpart_pred（分区号 $_newnum，最终由 parted 分配）"
    say "  起止        : 扇区 $_start - $_te"
    say "  容量        : $(human2 $(( _avail * 512 )))"
    say "  文件系统    : ext4，label=$_label"
    if [ "$_asovl" = "1" ]; then
        say "  用途        : 挂成 /overlay（会把当前 overlay 的插件层复制过来，需重启生效）"
    elif [ -n "${OPT_MOUNT:-}" ]; then
        say "  用途        : 挂到 $OPT_MOUNT（写 /etc/config/fstab）"
    else
        say "  用途        : 仅建好分区，不挂载"
    fi
    if [ "$_asovl" = "1" ] && [ ! -d /overlay/upper ]; then
        warn "当前没有 /overlay/upper，接管 /overlay 后会是一个空 overlay（插件需重装）"
    fi

    confirm_yes "确认创建 $_newpart 吗？这一步会写分区表并格式化【这个新分区】，不碰已有分区。" || return 1

    if [ "$(pttype "$_disk")" = "GPT" ] && command -v sgdisk >/dev/null 2>&1; then
        sgdisk -e "$_disk" >/dev/null 2>&1 || true
    fi

    say "[1/6] 创建分区 ..."
    _before=" $(parts_of "$_disk" | tr '\n' ' ') "
    if command -v parted >/dev/null 2>&1 || ensure_tool parted parted parted; then
        parted -s "$_disk" unit s mkpart primary "${_start}s" "${_te}s" 2>/dev/null || die "parted 建分区失败"
    else
        die "需要 parted 或 fdisk"
    fi

    # parted 自己决定分区号，这里用“建表前后差集”找出新设备，最稳
    _newpart=""
    _i=0
    while [ "$_i" -lt 12 ]; do
        for _p in $(parts_of "$_disk"); do
            case "$_before" in
                *" $_p "*) continue ;;
            esac
            _newpart="$_p"
            break 2
        done
        sleep 1
        _i=$(( _i + 1 ))
    done
    [ -n "$_newpart" ] || die "分区已写入但内核没出现新设备节点，请 reboot 后重新运行 --new"
    reread "$_disk" "$_newpart"
    ok "分区已创建：$_newpart"

    say "[2/6] 格式化 ext4（label=$_label） ..."
    if command -v mke2fs >/dev/null 2>&1; then
        mke2fs -t ext4 -L "$_label" -m 0 -q "$_newpart" || die "格式化失败"
    else
        ensure_tool mkfs.ext4 e2fsprogs e2fsprogs || die "需要 mkfs.ext4"
        mkfs.ext4 -F -L "$_label" -m 0 "$_newpart" || die "格式化失败"
    fi
    ok "已格式化"

    if [ "$_asovl" != "1" ] && [ -z "${OPT_MOUNT:-}" ]; then
        say "[3/6]-[6/6] 跳过挂载配置"
        ok "完成：$(_newpart) 可用 $(human2 $(( _avail * 512 )))"
        return 0
    fi

    say "[3/6] 挂载并准备数据 ..."
    _mnt=/mnt/extend-new
    mkdir -p "$_mnt"
    mount "$_newpart" "$_mnt" || die "挂载 $_newpart 失败"

    if [ "$_asovl" = "1" ]; then
        mkdir -p "$_mnt/upper" "$_mnt/work"
        if [ -d /overlay/upper ]; then
            _src=$(find /overlay/upper 2>/dev/null | wc -l)
            say "  复制现有 overlay 数据（约 $_src 个条目，勿断电）..."
            if ! cp -a /overlay/upper/. "$_mnt/upper/" 2>/dev/null; then
                tar cf - -C /overlay/upper . 2>/dev/null | tar xf - -C "$_mnt/upper" || {
                    umount "$_mnt"; die "复制失败"; }
            fi
            sync
            _dst=$(find "$_mnt/upper" 2>/dev/null | wc -l)
            say "  源 $_src → 目标 $_dst"
            [ "$_dst" -lt $(( _src / 2 )) ] && { umount "$_mnt"; die "复制数量异常，已中止"; }
        fi
    fi

    say "[4/6] 写 fstab ..."
    if [ "$_asovl" = "1" ]; then
        _target="/overlay"
    else
        _target="$OPT_MOUNT"
    fi
    if command -v uci >/dev/null 2>&1; then
        _secs=$(uci show fstab 2>/dev/null | sed -n "s/^fstab\.\([^.]*\)\.target='$_target'$/\1/p" | sort -u)
        for _s in $_secs; do uci -q delete "fstab.$_s"; done
        _sname=$(printf '%s' "$_target" | tr -d '/' | tr 'a-z' 'A-Z')
        [ -n "$_sname" ] || _sname=extroot
        uci set "fstab.$_sname=mount"
        uci set "fstab.$_sname.target=$_target"
        uci set "fstab.$_sname.label=$_label"
        uci set "fstab.$_sname.fstype=ext4"
        uci set "fstab.$_sname.enabled=1"
        uci commit fstab
        ok "fstab 已写入（label=$_label → $_target）"
    else
        sed -i "s|^.*[[:space:]]${_target}[[:space:]].*$|# &#" /etc/fstab 2>/dev/null || true
        printf 'LABEL=%s %s ext4 defaults 0 0\n' "$_label" "$_target" >> /etc/fstab
        ok "/etc/fstab 已追加"
    fi

    say "[5/6] 自检 ..."
    [ -f "$_mnt/upper/etc/config/network" ] && ok "network 配置在" || true
    du -sh "$_mnt/upper" 2>/dev/null | sed 's/^/    upper: /'

    say "[6/6] 卸载 ..."
    sync
    umount "$_mnt" 2>/dev/null || true
    rmdir "$_mnt" 2>/dev/null || true

    say ""
    if [ "$_asovl" = "1" ]; then
        say "=============================================================="
        say " 完成。执行 reboot，重启后 /overlay 落在 $_newpart"
        say "=============================================================="
    else
        say "=============================================================="
        say " 完成。$_newpart 将在开机时挂到 $_target"
        say "=============================================================="
    fi
}

# ---------------------------------------------------------------- 主菜单

run_menu() {
    _disk=$(choose_disk)
    show_disk_table "$_disk"

    say ""
    say "=============================================================="
    say " 要对 $_disk 做什么？"
    say "=============================================================="
    say "  1) 扩容某个已有分区（ext4/xfs/btrfs/f2fs 在线扩）"
    say "  2) 用剩余空间新建分区（可选挂到 /mnt/xxx）"
    say "  3) 用剩余空间新建分区并接管为 /overlay（OpenWrt 插件持久化）"
    say "  0) 退出"
    printf '选择 [0-3]: '
    tty_in _act
    case "$_act" in
        1)
            _idx=$(choose_part_index "$_disk")
            _part=$(part_by_index "$_disk" "$_idx") || die "找不到该分区"
            act_resize "$_disk" "$_part"
            ;;
        2)
            printf '分区标签 label（默认 DATA）: '
            tty_in _l; [ -n "$_l" ] && OPT_LABEL="$_l"
            printf '挂载点（留空则不挂载，例如 /mnt/data）: '
            tty_in _m; [ -n "$_m" ] && OPT_MOUNT="$_m"
            act_new "$_disk"
            ;;
        3)
            AS_OVERLAY=1
            OPT_LABEL="${OPT_LABEL:-IMMO_OVERLAY}"
            act_new "$_disk"
            ;;
        0|'') say "退出"; exit 0 ;;
        *) die "无效选项" ;;
    esac
}

# ---------------------------------------------------------------- 参数解析

while [ $# -gt 0 ]; do
    case "$1" in
        --list)     for _d in $(list_disks); do show_disk_table "$_d"; done; exit 0 ;;
        --disk)     OPT_DISK="$2"; shift 2 ;;
        --info)     [ -b "$OPT_DISK" ] || die "不是块设备: $OPT_DISK"; show_disk_table "$OPT_DISK"; exit 0 ;;
        --resize)   OPT_ACTION="resize"; OPT_PART="$2"; shift 2 ;;
        --new)      OPT_ACTION="new"; shift ;;
        --label)    OPT_LABEL="$2"; shift 2 ;;
        --mount)    OPT_MOUNT="$2"; shift 2 ;;
        --as-overlay) AS_OVERLAY=1; OPT_ACTION="new"; shift ;;
        --yes|-y)   DO_YES=1; shift ;;
        -h|--help)
            sed -n '2,40p' "$0" 2>/dev/null || say "见脚本头部说明"
            exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

if [ -n "$OPT_ACTION" ]; then
    [ -n "$OPT_DISK" ] || die "需要 --disk"
    [ -b "$OPT_DISK" ] || die "不是块设备: $OPT_DISK"
    show_disk_table "$OPT_DISK"
    case "$OPT_ACTION" in
        resize)
            _part=$(part_by_index "$OPT_DISK" "$OPT_PART") || \
                die "分区序号 $OPT_PART 不存在（用 --info 查看）"
            act_resize "$OPT_DISK" "$_part"
            ;;
        new) act_new "$OPT_DISK" ;;
    esac
    exit $?
fi

run_menu
