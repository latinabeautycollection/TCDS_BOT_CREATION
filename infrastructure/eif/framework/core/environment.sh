#!/usr/bin/env bash
eif_discover_environment() {
  EIF_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
  EIF_SHORT_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
  EIF_ARCH="$(uname -m)"; EIF_KERNEL="$(uname -r)"
  EIF_OS_ID=unknown; EIF_OS_VERSION=unknown; EIF_OS_CODENAME=unknown
  EIF_CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"
  EIF_MEMORY_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  EIF_SWAP_KB="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  EIF_TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)"
  EIF_OPERATOR="${SUDO_USER:-${USER:-unknown}}"
  [[ -r /etc/os-release ]] && { source /etc/os-release; EIF_OS_ID="${ID:-unknown}"; EIF_OS_VERSION="${VERSION_ID:-unknown}"; EIF_OS_CODENAME="${VERSION_CODENAME:-unknown}"; }
  EIF_INIT_SYSTEM=unknown; command -v systemctl >/dev/null 2>&1 && EIF_INIT_SYSTEM=systemd
  EIF_PACKAGE_MANAGER=unknown; command -v apt-get >/dev/null 2>&1 && EIF_PACKAGE_MANAGER=apt
  export EIF_HOSTNAME EIF_SHORT_HOSTNAME EIF_ARCH EIF_KERNEL EIF_OS_ID EIF_OS_VERSION EIF_OS_CODENAME
  export EIF_CPU_COUNT EIF_MEMORY_KB EIF_SWAP_KB EIF_TIMEZONE EIF_OPERATOR EIF_INIT_SYSTEM EIF_PACKAGE_MANAGER
}
