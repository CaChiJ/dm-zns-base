#!/usr/bin/env bash
# Vagrant provisioner: install apt dependencies only.
# null_blk creation lives in scripts/nullblk-up.sh so it can be re-run
# after every reboot (the device is memory-backed and doesn't persist).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
	build-essential \
	git \
	linux-headers-$(uname -r) \
	linux-modules-extra-$(uname -r) \
	dmsetup \
	util-linux \
	nvme-cli \
	fio

cat <<'EOF'

[provision] Done. Next, inside the guest:
  cd /vagrant
  sudo bash scripts/nullblk-up.sh
  cd src && make && cd ..
  sudo bash scripts/test-basic.sh
EOF
