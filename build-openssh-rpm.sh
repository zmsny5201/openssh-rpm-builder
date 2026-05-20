#!/bin/sh
#===============================================================================
# OpenSSH RPM 一键打包脚本 (POSIX sh 兼容版)
# 适用于 Kylin V10 / RHEL / CentOS
#
# 功能：
#   1. 自动检测最新版 OpenSSH 并下载源码包
#   2. 或使用手动下载/放置的源码包
#   3. 自动安装编译依赖
#   4. 生成 RPM 包（可拷贝到银河麒麟 V10 用 rpm -ivh 安装）
#
# 用法：
#   sh build-openssh-rpm.sh                          # 自动模式
#   sh build-openssh-rpm.sh -v 10.3p1                # 指定版本
#   sh build-openssh-rpm.sh -f ./openssh-10.3p1.tar.gz   # 本地源码包
#   sh build-openssh-rpm.sh -v 10.3p1 -o /tmp/rpms       # 指定输出目录
#   sh build-openssh-rpm.sh -v 10.3p1 --skip-deps        # 跳过依赖安装
#===============================================================================

# --- 严格模式（POSIX 兼容子集） ---
set -eu

# ============================================================================
# 颜色输出
# ============================================================================
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

info()   { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()   { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error()  { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()   { printf "${BLUE}[STEP]${NC} %s\n" "$*"; }
header() { printf "\n${CYAN}━━━ %s ━━━${NC}\n" "$*"; }

# ============================================================================
# 全局变量
# ============================================================================
WORK_DIR=$(pwd)
OUTPUT_DIR=""
VERSION=""
SOURCE_FILE=""
DIST_TAG="ky10"
SKIP_DEPS=0
FORCE_REBUILD=0

# 源码下载地址
OPENBSD_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable"
GITHUB_MIRROR="https://github.com/openssh/openssh-portable/archive/refs/tags"
CLOUDFLARE_MIRROR="https://cloudflare.cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable"

# ============================================================================
# 帮助信息
# ============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -v VERSION            指定版本（如 10.3p1），默认自动检测最新版
  -f PATH               使用本地已下载的源码包
  -o DIR                指定 RPM 输出目录（默认: 当前目录/RPMS/）
  -d TAG                指定发行版标签（默认: ky10，可选: el7/el8/el9）
  --skip-deps           跳过安装编译依赖
  --force               强制重新构建
  -h                    显示帮助

示例:
  $0                                         # 自动下载最新版
  $0 -v 10.3p1                               # 指定版本
  $0 -f ./openssh-10.2p1.tar.gz              # 使用本地源码包
  $0 -v 10.3p1 -o /tmp/rpms                  # 指定输出目录
EOF
    exit 0
}

# ============================================================================
# 解析命令行参数
# ============================================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--version)
                VERSION="$2"
                shift; shift
                ;;
            -f|--file)
                SOURCE_FILE="$2"
                shift; shift
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift; shift
                ;;
            -d|--dist)
                DIST_TAG="$2"
                shift; shift
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            --force)
                FORCE_REBUILD=1
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "未知选项: $1"
                usage
                ;;
        esac
    done

    if [ -n "$SOURCE_FILE" ]; then
        if [ ! -f "$SOURCE_FILE" ]; then
            error "指定的源码包文件不存在: $SOURCE_FILE"
            exit 1
        fi
        # 如果未通过 -v 指定版本，从文件名自动解析
        if [ -z "$VERSION" ]; then
            _basename=$(basename "$SOURCE_FILE")
            VERSION=$(printf '%s' "$_basename" | sed -n \
                -e 's/^openssh-\([0-9]\+\.[0-9]\+p[0-9]\+\)\.tar\.gz$/\1/p' \
                -e 's/^openssh-\([0-9]\+\.[0-9]\+\)\.tar\.gz$/\1p0/p' \
                -e 's/^V_\([0-9]\+\)_\([0-9]\+\)_P\([0-9]\+\)\.tar\.gz$/\1.\2p\3/p')
            if [ -z "$VERSION" ]; then
                error "无法从文件名解析版本号，请使用 -v 参数指定"
                exit 1
            fi
            info "从文件名解析出版本号: $VERSION"
        fi
    fi

    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$WORK_DIR/RPMS"
    fi
}

# ============================================================================
# 检查操作系统
# ============================================================================
check_os() {
    header "检查操作系统环境"

    if [ -f /etc/os-release ]; then
        _saved_version="$VERSION"
        . /etc/os-release
        VERSION="$_saved_version"
        info "操作系统: $PRETTY_NAME"
    else
        warn "无法检测操作系统类型，继续执行..."
    fi

    _missing=""
    for _cmd in rpm rpmbuild tar gcc make; do
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            _missing="$_missing $_cmd"
        fi
    done

    if [ -n "$_missing" ]; then
        warn "缺少以下工具:$_missing"
        if [ "$SKIP_DEPS" -eq 1 ]; then
            warn "已跳过依赖安装，请确保手动安装缺失工具"
        else
            info "将在下一步安装缺失工具"
        fi
    else
        info "基础构建工具已安装 ✓"
    fi
}

# ============================================================================
# 检测最新版 OpenSSH
# ============================================================================
detect_latest_version() {
    header "检测最新版 OpenSSH"

    _version_list=""
    info "正在从 $OPENBSD_URL 获取版本列表..."

    _version_list=$(curl -sL "$OPENBSD_URL" 2>/dev/null | \
        sed -n 's/.*openssh-\([0-9]\+\.[0-9]\+p[0-9]\+\).tar.gz.*/\1/p' | \
        sort -t. -k1,1n -k2,2n -k3,3V 2>/dev/null | tail -1)

    if [ -z "$_version_list" ]; then
        warn "官方源获取失败，尝试 GitHub..."
        _version_list=$(curl -sL "https://api.github.com/repos/openssh/openssh-portable/releases/latest" 2>/dev/null | \
            sed -n 's/.*"tag_name": *"V_\([0-9]\+\)_\([0-9]\+\)_P\([0-9]\+\).*/\1.\2p\3/p')
    fi

    if [ -z "$_version_list" ]; then
        _v=$(curl -sL "$OPENBSD_URL" 2>/dev/null | \
            sed -n 's/.*openssh-\([0-9]\+\.[0-9]\+p[0-9]\+\).tar.gz.*/\1/p' | \
            sort -t. -k1,1n -k2,2n -k3,3V 2>/dev/null | tail -1)
        if [ -n "$_v" ]; then
            _version_list="$_v"
        fi
    fi

    if [ -z "$_version_list" ]; then
        error "无法检测最新版本，请使用 -v 参数手动指定"
        exit 1
    fi

    VERSION="$_version_list"
    info "检测到最新版本: $VERSION"
}

# ============================================================================
# 安装编译依赖
# ============================================================================
install_deps() {
    header "安装编译依赖"

    if [ "$SKIP_DEPS" -eq 1 ]; then
        info "已跳过依赖安装 (--skip-deps)"
        return
    fi

    _use_sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            _use_sudo="sudo"
            info "将以 sudo 权限安装依赖包"
        else
            warn "非 root 用户且无 sudo，跳过依赖安装..."
            return
        fi
    fi

    if command -v yum >/dev/null 2>&1; then
        _pkg_install="${_use_sudo} yum install -y"
    elif command -v dnf >/dev/null 2>&1; then
        _pkg_install="${_use_sudo} dnf install -y"
    elif command -v apt-get >/dev/null 2>&1; then
        warn "检测到 Debian/Ubuntu 系统，RPM 构建推荐使用 Kylin/CentOS"
        _pkg_install="${_use_sudo} apt-get install -y"
    else
        warn "未检测到支持的包管理器，跳过依赖安装"
        warn "请确保已安装: gcc make rpm-build openssl-devel pam-devel zlib-devel"
        return
    fi

    if [ -n "$_pkg_install" ]; then
        info "安装编译依赖包..."
        $_pkg_install \
            gcc gcc-c++ make autoconf automake \
            rpm-build rpmdevtools \
            openssl-devel pam-devel zlib-devel \
            libselinux-devel krb5-devel libedit-devel \
            perl perl-IPC-Cmd wget curl \
            xauth libXt-devel gtk2-devel tk-devel 2>&1 | tail -5 || true
        info "编译依赖安装完成 ✓"
    fi
}

# ============================================================================
# 下载源码包
# ============================================================================
download_source() {
    header "下载 OpenSSH $VERSION 源码包"

    _sources_dir="${BUILD_DIR}/SOURCES"
    mkdir -p "$_sources_dir"

    if [ -n "$SOURCE_FILE" ] && [ -f "$SOURCE_FILE" ]; then
        info "使用本地源码包: $SOURCE_FILE"
        _target="${_sources_dir}/openssh-${VERSION}.tar.gz"
        cp "$SOURCE_FILE" "$_target"
        info "已重命名为: openssh-${VERSION}.tar.gz"
        return
    fi

    _filename="openssh-${VERSION}.tar.gz"
    _target="${_sources_dir}/${_filename}"

    if [ -f "$_target" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
        if gzip -t "$_target" 2>/dev/null; then
            info "源码包已存在且通过完整性检查 ✓"
            return
        else
            warn "文件损坏，重新下载..."
        fi
    fi

    _downloaded=0

    info "尝试 Cloudflare CDN 源..."
    curl -fSL --connect-timeout 15 --max-time 300 \
        -o "$_target" "$CLOUDFLARE_MIRROR/$_filename" 2>/dev/null && \
    gzip -t "$_target" 2>/dev/null && _downloaded=1

    if [ "$_downloaded" -eq 0 ]; then
        _github_tag="V_$(printf '%s' "$VERSION" | sed 's/\./_/g; s/p/_P/')"
        info "尝试 GitHub 镜像源..."
        curl -fSL --connect-timeout 15 --max-time 300 \
            -o "$_target" "$GITHUB_MIRROR/$_github_tag.tar.gz" 2>/dev/null && \
        gzip -t "$_target" 2>/dev/null && _downloaded=1
    fi

    if [ "$_downloaded" -eq 0 ]; then
        info "尝试 OpenBSD 官方源..."
        curl -fSL --connect-timeout 15 --max-time 300 \
            -o "$_target" "$OPENBSD_URL/$_filename" 2>/dev/null && \
        gzip -t "$_target" 2>/dev/null && _downloaded=1
    fi

    if [ "$_downloaded" -eq 0 ]; then
        error "所有下载源均失败！"
        error "请手动下载后使用 -f 参数指定本地文件"
        error "下载地址: https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${VERSION}.tar.gz"
        exit 1
    fi

    info "源码包下载成功 ✓"
}

# ============================================================================
# 生成 RPM Spec 文件（用临时文件 + sed 替换变量，避免 heredoc 转义问题）
# ============================================================================
generate_spec() {
    header "生成 RPM Spec 文件"

    _spec_file="$BUILD_DIR/SPECS/openssh.spec"
    mkdir -p "$(dirname "$_spec_file")"

    # 用 sed 替换标记 @VERSION@ 和 @OPENBSD_URL@，scriptlet 部分则不需要任何转义
    cat > "$_spec_file" << 'SPECEOF'
#==============================================================================
# OpenSSH RPM Spec - 自动生成
#==============================================================================

Summary: OpenSSH @VERSION@ - 安全 Shell 服务端与客户端
Name: openssh
Version: @VERSION@
Release: 1%{?dist}
%global debug_package %{nil}
License: BSD
Group: Applications/System
URL: https://www.openssh.com/
Source0: @OPENBSD_URL@/openssh-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
Obsoletes: openssh-help < %{version}

BuildRequires: gcc, make, zlib-devel, openssl-devel, pam-devel
BuildRequires: perl, perl-IPC-Cmd
%if 0%{?rhel} || 0%{?suse_version} || 0%{?kyulin}
BuildRequires: libselinux-devel
%endif

%description
OpenSSH（OpenBSD Secure Shell）使用 SSH 协议进行远程登录，
提供加密通信通道，确保远程管理安全。

本包由自动构建脚本生成，适用于 Kylin V10 等操作系统
通过 rpm -ivh 快速升级 OpenSSH 版本。

%package server
Summary: OpenSSH 服务端（sshd）
Group: System Environment/Daemons
Requires: openssh = %{version}-%{release}
Provides: sshd

%description server
OpenSSH 服务端守护进程（sshd），提供远程登录和文件传输服务。

%package clients
Summary: OpenSSH 客户端工具
Group: Applications/System
Requires: openssh = %{version}-%{release}
Provides: ssh

%description clients
OpenSSH 客户端工具，包括 ssh, scp, sftp 等。

%prep
%setup -q -n openssh-%{version}

%build
%configure \
    --prefix=/usr \
    --sysconfdir=/etc/ssh \
    --libexecdir=%{_libexecdir}/openssh \
    --datadir=%{_datadir}/openssh \
    --mandir=%{_mandir} \
    --with-pam \
    --with-selinux \
    --with-privsep-path=/var/empty/sshd \
    --with-privsep-user=sshd \
    --with-md5-passwords \
    --with-kerberos5 \
    --with-libedit \
    --with-ssl-engine \
    --with-xauth=%{_bindir}/xauth

make %{?_smp_mflags}

%install
[ "$RPM_BUILD_ROOT" != "/" ] && rm -rf $RPM_BUILD_ROOT
%make_install

install -d $RPM_BUILD_ROOT/var/empty/sshd
install -d $RPM_BUILD_ROOT/var/run/sshd

install -d $RPM_BUILD_ROOT/etc/pam.d
cat > $RPM_BUILD_ROOT/etc/pam.d/sshd << PAMEOF
#%PAM-1.0
auth       required     pam_sepermit.so
auth       substack     password-auth
auth       include      postlogin
account    required     pam_sepermit.so
account    required     pam_nologin.so
account    include      password-auth
password   include      password-auth
session    required     pam_selinux.so close
session    required     pam_loginuid.so
session    optional     pam_selinux.so open env_params
session    optional     pam_keyinit.so force revoke
session    include      password-auth
session    include      postlogin
PAMEOF

install -d $RPM_BUILD_ROOT/%{_unitdir}
cat > $RPM_BUILD_ROOT/%{_unitdir}/sshd.service << SERVEOF
[Unit]
Description=OpenSSH server daemon
Documentation=man:sshd(8) man:sshd_config(5)
After=network.target sshd-keygen.target
Wants=sshd-keygen.target

[Service]
Type=notify
EnvironmentFile=-/etc/sysconfig/sshd
ExecStart=%{_sbindir}/sshd -D $OPTIONS
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=42s

[Install]
WantedBy=multi-user.target
SERVEOF

cat > $RPM_BUILD_ROOT/%{_unitdir}/sshd-keygen.target << KEYEOF
[Unit]
Description=sshd key generation target
Documentation=man:sshd(8) man:sshd_config(5)
KEYEOF

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%doc ChangeLog CREDITS INSTALL LICENCE OVERVIEW README* TODO
%{_bindir}/ssh-keygen
%{_libexecdir}/openssh/
%{_mandir}/man1/ssh-keygen.1*
%{_mandir}/man8/ssh-keysign.8*
%{_mandir}/man8/sftp-server.8*
%{_mandir}/man8/ssh-pkcs11*
%{_mandir}/man8/ssh-sk-helper*
%{_mandir}/man5/moduli.5*
%{_mandir}/man5/ssh*config.5*
%dir /etc/ssh/
%config(noreplace) /etc/ssh/moduli
%attr(0711,root,root) %dir /var/empty/sshd

%files server
%defattr(-,root,root)
%{_sbindir}/sshd
%attr(4755,root,root) %{_bindir}/ssh-agent
%config(noreplace) /etc/ssh/sshd_config
%config(noreplace) /etc/pam.d/sshd
%{_unitdir}/sshd.service
%{_unitdir}/sshd-keygen.target
%dir /var/run/sshd
%{_mandir}/man8/sshd.8*
%{_mandir}/man1/ssh-agent.1*

%files clients
%defattr(-,root,root)
%{_bindir}/ssh
%{_bindir}/scp
%{_bindir}/sftp
%{_bindir}/ssh-add
%{_bindir}/ssh-keyscan
%config(noreplace) /etc/ssh/ssh_config
%{_mandir}/man1/ssh.1*
%{_mandir}/man1/scp.1*
%{_mandir}/man1/sftp.1*
%{_mandir}/man1/ssh-add.1*
%{_mandir}/man1/ssh-keyscan.1*

%pre server
if [ -f /etc/ssh/sshd_config ] && [ ! -f /etc/ssh/sshd_config.rpmsave ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.rpmsave
fi
getent group sshd >/dev/null 2>&1 || groupadd -r sshd
getent passwd sshd >/dev/null 2>&1 || useradd -r -g sshd -d /var/empty/sshd -s /sbin/nologin -c "sshd privilege separation" sshd

%post server
# 重新加载 systemd 配置
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
# 生成主机密钥（如果不存在）
for _kt in rsa ecdsa ed25519; do
    _kf="/etc/ssh/ssh_host_${_kt}_key"
    if [ ! -f "$_kf" ]; then
        ssh-keygen -t $_kt -f "$_kf" -N '' < /dev/null 2>/dev/null || true
    fi
done
# 检测并修复不兼容的 sshd_config 选项
if [ -f /etc/ssh/sshd_config ]; then
    _changed=0
    for _opt in RSAAuthentication RhostsRSAAuthentication GSSAPIKexAlgorithms XAuthLocation; do
        if grep -Eqs "^[[:space:]]*${_opt}[[:space:]]" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i "s/^[[:space:]]*\(${_opt}[[:space:]].*\)$/# \1  # deprecated by OpenSSH 10.x/" /etc/ssh/sshd_config
            _changed=1
        fi
    done
    if [ "$_changed" -eq 1 ]; then
        echo "sshd_config: 已注释不兼容选项" >&2
    fi
    # 最终验证
    if ! /usr/sbin/sshd -t >/dev/null 2>&1; then
        echo "WARNING: sshd_config 仍有问题，请手动检查" >&2
        /usr/sbin/sshd -t 2>&1 || true
    fi
fi

%preun server
if [ $1 -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop sshd >/dev/null 2>&1 || true
    fi
fi

%postun server
if [ $1 -ge 1 ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl try-restart sshd >/dev/null 2>&1 || true
    fi
fi

%changelog
* @DATE@  Hermes Build System <build@localhost>
- 自动构建 OpenSSH @VERSION@ RPM 包
- 适用于 Kylin V10 / RHEL / CentOS 系统
SPECEOF

    # 替换标记变量
    _date=$(LC_ALL=C date '+%a %b %d %Y')
    sed -i \
        -e "s|@VERSION@|${VERSION}|g" \
        -e "s|@OPENBSD_URL@|${OPENBSD_URL}|g" \
        -e "s|@DATE@|${_date}|g" \
        "$_spec_file"

    # 检测 tarball 实际解压目录名，与 spec 中 %setup -n 保持一致
    _source_tar="${BUILD_DIR}/SOURCES/openssh-${VERSION}.tar.gz"
    if [ -f "$_source_tar" ]; then
        # 查出 tarball 的顶层目录名（只取包含子路径的条目的第一级目录）
        _actual_dir=$(tar tzf "$_source_tar" 2>/dev/null | \
            sed 's@^\./@@' | \
            awk -F/ 'NF>1{print $1}' | \
            sort -u | head -1)
        _expected_dir="openssh-${VERSION}"
        if [ -n "$_actual_dir" ] && [ "$_actual_dir" != "$_expected_dir" ]; then
            sed -i "s/%setup -q -n openssh-%{version}/%setup -q -n ${_actual_dir}/" "$_spec_file"
            info "tarball 解压目录为: $_actual_dir，已自动适配 spec"
        fi
    fi

    info "Spec 文件已生成: $_spec_file"
    echo "--- spec 关键部分预览 ---"
    grep -n '^%pre\b\|^%post\b\|^%preun\|^%postun\|^%files\|ExecStart\|Obsoletes\|%changelog' "$_spec_file" | head -30
}

# ============================================================================
# 构建 RPM
# ============================================================================
build_rpm() {
    header "构建 RPM 包"

    _existing_count=0
    for _f in $(find "$OUTPUT_DIR" -name "openssh-${VERSION}*.rpm" -type f 2>/dev/null); do
        if [ -f "$_f" ]; then
            _existing_count=$((_existing_count + 1))
        fi
    done

    if [ "$_existing_count" -gt 0 ] && [ "$FORCE_REBUILD" -eq 0 ]; then
        warn "RPM 包已存在（使用 --force 强制重新构建）:"
        for _f in $(find "$OUTPUT_DIR" -name "openssh-${VERSION}*.rpm" -type f 2>/dev/null); do
            [ -f "$_f" ] && warn "  - $_f"
        done
        info "跳过构建"
        return
    fi

    info "开始编译构建（请耐心等待 5-15 分钟）..."

    rpmbuild -ba \
        --define "_topdir $BUILD_DIR" \
        --define "_smp_mflags -j$(nproc 2>/dev/null || echo 1)" \
        --define "_rpmdir $OUTPUT_DIR" \
        --define "_srcrpmdir $BUILD_DIR/SRPMS" \
        --define "dist .${DIST_TAG}" \
        "$BUILD_DIR/SPECS/openssh.spec" 2>&1

    _status=$?

    if [ "$_status" -ne 0 ]; then
        error "RPM 构建失败！退出码: $_status"
        error "检查日志: $BUILD_DIR/BUILD/"
        return 1
    fi

    info "RPM 构建成功 ✓"
    return 0
}

# ============================================================================
# 显示结果
# ============================================================================
show_results() {
    header "构建结果"

    mkdir -p "$OUTPUT_DIR"

    echo ""
    printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${GREEN}  OpenSSH %s RPM 包已生成！${NC}\n" "$VERSION"
    printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    echo ""

    _total_size=0
    _rpm_files=""
    for _f in $(find "$OUTPUT_DIR" -name "openssh-${VERSION}*.rpm" -type f 2>/dev/null | sort); do
        if [ -f "$_f" ]; then
            _size=$(du -h "$_f" 2>/dev/null | cut -f1)
            _rpm_files="$_rpm_files $_f"
            _total_size=$((_total_size + 1))
            printf "  📦  %s  (%s)\n" "$(basename "$_f")" "$_size"
        fi
    done

    if [ "$_total_size" -eq 0 ]; then
        warn "未找到生成的 RPM 文件"
        warn "检查目录: $OUTPUT_DIR"
        return
    fi

    echo ""
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${CYAN}  安装说明${NC}\n"
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    echo ""
    echo "  cd $OUTPUT_DIR"
    echo "  cd \$(find . -type d -name 'x86_64' -o -name 'aarch64' | head -1)"
    echo "  yum localinstall *.rpm --allowerasing -y"
    echo "  systemctl daemon-reload"
    echo "  systemctl restart sshd"
    echo "  sshd -V"
    echo ""

    _manifest="$OUTPUT_DIR/openssh-${VERSION}-sha256.txt"
    {
        echo "OpenSSH ${VERSION} RPM 包 SHA256 校验清单"
        echo "生成: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "系统: $(uname -a 2>/dev/null || echo unknown)"
        echo "========================================"
        echo ""
        for _f in $(find "$OUTPUT_DIR" -name "openssh-${VERSION}*.rpm" -type f 2>/dev/null | sort); do
            [ -f "$_f" ] && sha256sum "$_f"
        done
    } > "$_manifest"
    info "SHA256 校验清单已保存: $_manifest"

    printf "${YELLOW}⚠ 重要提醒：${NC}\n"
    printf "${YELLOW}  1. 升级前确保有备用远程连接（带外管理/物理控制台）${NC}\n"
    printf "${YELLOW}  2. 新版 SSH 可能默认禁用旧算法，需调整 sshd_config${NC}\n"
    printf "${YELLOW}  3. 建议先在测试环境验证后再生产升级${NC}\n"
    echo ""
}

# ============================================================================
# 清理
# ============================================================================
cleanup_build() {
    header "清理构建临时文件"

    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR/BUILD" "$BUILD_DIR/BUILDROOT" \
               "$BUILD_DIR/SOURCES" "$BUILD_DIR/SPECS" "$BUILD_DIR/SRPMS" 2>/dev/null || true
        info "已清理构建临时文件"
    fi
}

# ============================================================================
# 主流程
# ============================================================================
main() {
    echo ""
    printf "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║     OpenSSH RPM 一键打包脚本 (POSIX sh)                ║${NC}\n"
    printf "${CYAN}║     适用于 Kylin V10 / RHEL / CentOS                   ║${NC}\n"
    printf "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"
    echo ""

    parse_args "$@"
    check_os

    if [ -z "$VERSION" ]; then
        detect_latest_version
    fi

    echo ""
    info "========================================"
    info " OpenSSH 版本:     ${VERSION}"
    info " RPM 输出目录:     ${OUTPUT_DIR}"
    info " 发行版标签:       .${DIST_TAG}"
    info "========================================"
    echo ""

    install_deps

    header "准备 RPM 构建环境"
    BUILD_DIR="$WORK_DIR/rpmbuild-ssh-${VERSION}"
    mkdir -p "$BUILD_DIR/BUILD" "$BUILD_DIR/BUILDROOT" \
             "$BUILD_DIR/RPMS/x86_64" "$BUILD_DIR/RPMS/aarch64" \
             "$BUILD_DIR/RPMS/noarch" \
             "$BUILD_DIR/SOURCES" "$BUILD_DIR/SPECS" "$BUILD_DIR/SRPMS"
    info "构建目录已创建: $BUILD_DIR"

    download_source
    generate_spec
    build_rpm
    _build_ok=$?

    if [ "$_build_ok" -eq 0 ]; then
        show_results
    else
        error "构建失败，请检查错误信息"
        exit 1
    fi

    cleanup_build

    echo ""
    info "所有操作完成！RPM 包位置: $OUTPUT_DIR/"
    echo ""
}

main "$@"
