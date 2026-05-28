# 04. 셋업 — Windows

WSL2는 Microsoft 전용 커널을 쓰기 때문에 외부 모듈 `insmod`가 불가능하고 `null_blk`도 기본 빌트인이 아니다. 빌드는 가능하지만 적재·실행은 안 된다. WSL2용 커스텀 커널을 빌드하는 방법은 본 과제 범위 밖.

권장 경로는 **Vagrant + VirtualBox**다. 본 repo의 `Vagrantfile`과 `provision.sh`가 Ubuntu 게스트 생성과 의존성 설치를 자동화한다.

## 호스트 설치

| 도구 | 다운로드 | 검증된 버전 |
|---|---|---|
| VirtualBox | https://www.virtualbox.org/ | 7.2.x amd64 |
| Vagrant | https://www.vagrantup.com/downloads | 2.4.x |

ARM Windows가 아닌 한 amd64 빌드 (Intel/AMD 공통). VirtualBox 설치 중 "Network Disconnection" 경고는 가상 네트워크 드라이버 설치로 잠깐 끊기는 정상 동작. `VBoxManage`가 PATH에 안 잡혀도 Vagrant가 기본 경로에서 찾는다.

## Hyper-V 충돌 차단

VirtualBox는 Hyper-V hypervisor가 활성화돼 있으면 충돌한다.

```cmd
bcdedit /enum | findstr -i hypervisorlaunchtype
```

아무것도 뜨지 않거나 Off면 넘어가도 된다.

`Auto`로 떠 있으면 관리자 셸에서 `bcdedit /set hypervisorlaunchtype off` 후 재부팅(이러면 WSL2도 같이 동작 중지). 

## `vagrant up`

```cmd
git clone https://github.com/wnsah814/dm-zns-base.git
cd dm-zns-base
vagrant up
```

처음 한 번은 Ubuntu box 다운로드 + apt 설치로 5~10분. 끝에 `[provision] 완료.` 메시지.

## 게스트 진입 + 검증

```cmd
vagrant ssh
```

게스트(Ubuntu) 안:
```bash
cd /vagrant                       # repo가 그대로 보임 (synced folder)
sudo bash scripts/nullblk-up.sh
cd src && make && cd ..
sudo bash scripts/test-basic.sh   # ALL CHECKS PASSED
```

## VM 라이프사이클

```cmd
vagrant halt        # 종료
vagrant up          # 재시작 (provision 재실행 안 함)
vagrant destroy     # 디스크까지 완전 제거
vagrant ssh         # 다시 진입
```

## 트러블슈팅

- **`vagrant up`에서 "VBoxManage not found"**: VirtualBox 재설치, 또는 `C:\Program Files\Oracle\VirtualBox`를 PATH에 추가.
- **"VT-x is not available"**: BIOS/UEFI에서 Intel VT-x 또는 AMD-V 활성화. hypervisorlaunchtype off도 같이 확인.
- **게스트에서 `modprobe null_blk` 실패**: `sudo apt install linux-modules-extra-$(uname -r)`.
- **`vagrant ssh`가 멈춤**: Windows Defender Firewall에서 vagrant/VirtualBox 예외 허용.

## 수동 VM (선택)

자동화 없이 VirtualBox/Hyper-V로 직접 Ubuntu VM을 띄우려면 [02-setup-mac.md](02-setup-mac.md)의 절차가 거의 그대로 적용된다.
