#!/usr/bin/env bash
set -euo pipefail

cd "${KERNEL_DIR}"

defconfig_targets=()
defconfig_paths=()
if [ -n "${DEFCONFIG:-}" ]; then
  for def in ${DEFCONFIG}; do
    if echo "${def}" | grep -q '^/'; then
      def_path="${def#/}"
    else
      def_path="arch/arm64/configs/${def}"
    fi

    if [ ! -f "${def_path}" ]; then
      echo "Defconfig path not found: ${def_path}" >&2
      exit 1
    fi

    def_target="$(basename "${def_path}")"
    if [ "${def_path}" != "arch/arm64/configs/${def_target}" ]; then
      cp "${def_path}" "arch/arm64/configs/${def_target}"
    fi

    defconfig_targets+=("${def_target}")
    defconfig_paths+=("arch/arm64/configs/${def_target}")
  done
fi

if [ "${#defconfig_targets[@]}" -lt 1 ]; then
  echo "No defconfig provided" >&2
  exit 1
fi

frags=()
if [ -n "${DEFCONFIG_FRAGS:-}" ]; then
  for frag in ${DEFCONFIG_FRAGS}; do
    if [ -f "${frag}" ]; then
      frags+=("${frag}")
    elif [ -f "arch/arm64/configs/${frag}" ]; then
      frags+=("arch/arm64/configs/${frag}")
    else
      echo "Skipping missing defconfig fragment: ${frag}"
    fi
  done
fi

make ${MAKE_ARGS} "${defconfig_targets[0]}"

merge_frags=()
if [ "${#defconfig_paths[@]}" -gt 1 ]; then
  merge_frags+=("${defconfig_paths[@]:1}")
fi
if [ "${#frags[@]}" -gt 0 ]; then
  merge_frags+=("${frags[@]}")
fi

if [ "${#merge_frags[@]}" -gt 0 ]; then
  if [ -x "scripts/kconfig/merge_config.sh" ]; then
    scripts/kconfig/merge_config.sh -m -O out out/.config "${merge_frags[@]}"
  else
    echo "merge_config.sh not found; cannot apply defconfig fragments" >&2
    exit 1
  fi
fi

# --- Docker fragment (added in fork): merge our container options ---
DOCKER_FRAG="${GITHUB_WORKSPACE:-..}/configs/docker.config"
if [ -f "$DOCKER_FRAG" ]; then
  echo "Merging Docker config fragment: $DOCKER_FRAG"
  scripts/kconfig/merge_config.sh -m -O out out/.config "$DOCKER_FRAG"
else
  echo "WARNING: docker.config not found at $DOCKER_FRAG" >&2
fi

EXTRA_CFG="out/ci-extra.config"
: > "${EXTRA_CFG}"
echo "CONFIG_KSU=y" >> "${EXTRA_CFG}"

if [ "${SUSFS_SUPPORT}" = "true" ]; then
  echo "CONFIG_KSU_SUSFS=y" >> "${EXTRA_CFG}"
fi

if [ "${BBG_SUPPORT}" = "true" ]; then
  echo "CONFIG_BBG=y" >> "${EXTRA_CFG}"
fi

cat "${EXTRA_CFG}" >> out/.config
make ${MAKE_ARGS} olddefconfig
# fork: verify the critical Docker options survived olddefconfig
for _o in NETFILTER_XT_MATCH_ADDRTYPE BRIDGE_NETFILTER OVERLAY_FS VETH BRIDGE NF_NAT; do
  if ! grep -q "^CONFIG_${_o}=y" out/.config; then
    echo "FATAL: CONFIG_${_o} did not survive olddefconfig" >&2; exit 1
  fi
done
echo "Docker config retention: all critical options present"
[ -f scripts/setlocalversion ] && sed -i 's/-dirty//g' scripts/setlocalversion || true

JOBS=$(( $(nproc) / 2 ))
[ "${JOBS}" -lt 1 ] && JOBS=1
make -j"${JOBS}" ${MAKE_ARGS} Image KCFLAGS="-Wno-error"
