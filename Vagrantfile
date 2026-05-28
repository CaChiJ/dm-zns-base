# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Automated VM for Windows hosts: one `vagrant up` brings up Ubuntu 22.04
# and installs all apt dependencies. See docs/04-setup-windows.md.

Vagrant.configure("2") do |config|
  config.vm.box      = "ubuntu/jammy64"
  config.vm.hostname = "zns-dev"

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "dm-zns-base"
    vb.memory = 4096
    vb.cpus   = 2
  end

  # Default synced folder: host repo root -> guest /vagrant.
  # provision.sh only does apt; null_blk lives in scripts/nullblk-up.sh
  # because it's memory-backed and has to be re-run after every reboot.
  config.vm.provision "shell", path: "provision.sh"
end
