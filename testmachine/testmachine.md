__The current test machine is as follow:__

The device in use for tests is the `/dev/nvme0n1p1`
With current FIO result 
![ops_sec](https://github.com/user-attachments/assets/f09a7ce0-39a9-4211-a9f7-a1f68038fb8d)


![tot_latency](https://github.com/user-attachments/assets/81753c77-65cf-448d-bfbb-e622f8ca58ba)


```
# Percona Toolkit System Summary Report ######################
        Date | 2025-01-27 15:55:11 UTC (local TZ: EST -0500)
    Hostname | node3
      Uptime | 59 days, 22:49, 11 users,  load average: 0.07, 1.57, 3.07
      System | Supermicro; SYS-2028TP-HC0TR; v0123456789 (Other)
 Service Tag | S16548325C22065
    Platform | Linux
     Release | Ubuntu 24.04.1 LTS (noble)
      Kernel | 6.8.0-49-generic
Architecture | CPU = 64-bit, OS = 64-bit
   Threading | NPTL 2.39
     SELinux | No SELinux detected
 Virtualized | No virtualization detected
# Processor ##################################################
  Processors | physical = 2, cores = 28, virtual = 56, hyperthreading = yes
      Speeds | 1x2499.848, 1x2499.857, 1x2499.896, 52x2500.000, 1x2501.293
      Models | 56xIntel(R) Xeon(R) CPU E5-2683 v3 @ 2.00GHz
      Caches | 56x35840 KB
  Designation               Configuration                  Size     Associativity
  ========================= ============================== ======== ======================
  CPU Internal L1           Enabled, Not Socketed, Level 1 896 kB   8-way Set-associative 
  CPU Internal L2           Enabled, Not Socketed, Level 2 3584 kB  8-way Set-associative 
  CPU Internal L3           Enabled, Not Socketed, Level 3 35 MB    20-way Set-associative
  CPU Internal L1           Enabled, Not Socketed, Level 1 896 kB   8-way Set-associative 
  CPU Internal L2           Enabled, Not Socketed, Level 2 3584 kB  8-way Set-associative 
  CPU Internal L3           Enabled, Not Socketed, Level 3 35 MB    20-way Set-associative
# Memory #####################################################
         Total | 251.8G
          Free | 248.3G
          Used | physical = 3.0G, swap allocated = 0.0, swap used = 0.0, virtual = 3.0G
        Shared | 6.1M
       Buffers | 1.9G
        Caches | 248.7G
         Dirty | 256 kB
       UsedRSS | 1.4G
    Swappiness | 1
   DirtyPolicy | 20, 10
   DirtyStatus | 0, 0
    Numa Nodes | 2
   Numa Policy | default
Preferred Node | current
   Node    Size        Free        CPUs
   ====    ====        ====        ====
   node1   128967 MB   127191 MB   14 15 16 17 18 19 20 21 22 23 24 25 26 27 42 43 44 45 46 47 48 49 50 51 52 53 54 55 
   node0   128842 MB   127095 MB   0 1 2 3 4 5 6 7 8 9 10 11 12 13 28 29 30 31 32 33 34 35 36 37 38 39 40 41 

  Locator   Size     Speed             Form Factor   Type          Type Detail
  ========= ======== ================= ============= ============= ===========
  P1-DIMMA1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P1-DIMMB1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P1-DIMMC1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P1-DIMMD1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P2-DIMME1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P2-DIMMF1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P2-DIMMG1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P2-DIMMH1 32 GB    2133 MT/s         DIMM          DDR4          Synchronous
  P1-DIMMA2 {EMPTY}                    DIMM          DDR4          Synchronous
  P1-DIMMB2 {EMPTY}                    DIMM          DDR4          Synchronous
  P1-DIMMC2 {EMPTY}                    DIMM          DDR4          Synchronous
  P1-DIMMD2 {EMPTY}                    DIMM          DDR4          Synchronous
  P2-DIMME2 {EMPTY}                    DIMM          DDR4          Synchronous
  P2-DIMMF2 {EMPTY}                    DIMM          DDR4          Synchronous
  P2-DIMMG2 {EMPTY}                    DIMM          DDR4          Synchronous
  P2-DIMMH2 {EMPTY}                    DIMM          DDR4          Synchronous
# Mounted Filesystems ########################################
  Filesystem                      Size Used Type  Opts                                                                                Mountpoint
  /dev/mapper/smblade03--vg-root  1.6T  21% ext4  rw,relatime,errors=remount-ro                                                       /
  /dev/nvme0n1p1                  343G  94% ext4  rw,noatime,nodiratime                                                               /mnt/nvme_drive
  /dev/sda1                       234M  71% ext2  rw,relatime,stripe=4                                                                /boot
  /dev/sdb                        1.8T  57% xfs   rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,noquota                             /mnt/data
  /dev/sdc                        1.9T  50% ext4  rw,noatime,nodiratime                                                               /mnt/datamy
  tmpfs                           126G   0% tmpfs rw,nosuid,nodev,inode64                                                             /dev/shm
  tmpfs                           126G   0% tmpfs rw,nosuid,nodev,noexec,relatime,size=5120k,inode64                                  /dev/shm
  tmpfs                           126G   0% tmpfs rw,nosuid,nodev,noexec,relatime,size=26399760k,mode=755,inode64                     /dev/shm
  tmpfs                           126G   0% tmpfs rw,nosuid,nodev,relatime,size=26399756k,nr_inodes=6599939,mode=700,uid=1007,inode64 /dev/shm
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,inode64                                                             /run/user/1007
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,noexec,relatime,size=5120k,inode64                                  /run/user/1007
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,noexec,relatime,size=26399760k,mode=755,inode64                     /run/user/1007
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,relatime,size=26399756k,nr_inodes=6599939,mode=700,uid=1007,inode64 /run/user/1007
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,inode64                                                             /run
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,noexec,relatime,size=5120k,inode64                                  /run
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,noexec,relatime,size=26399760k,mode=755,inode64                     /run
  tmpfs                            26G   1% tmpfs rw,nosuid,nodev,relatime,size=26399756k,nr_inodes=6599939,mode=700,uid=1007,inode64 /run
  tmpfs                           5.0M   0% tmpfs rw,nosuid,nodev,inode64                                                             /run/lock
  tmpfs                           5.0M   0% tmpfs rw,nosuid,nodev,noexec,relatime,size=5120k,inode64                                  /run/lock
  tmpfs                           5.0M   0% tmpfs rw,nosuid,nodev,noexec,relatime,size=26399760k,mode=755,inode64                     /run/lock
  tmpfs                           5.0M   0% tmpfs rw,nosuid,nodev,relatime,size=26399756k,nr_inodes=6599939,mode=700,uid=1007,inode64 /run/lock
# Disk Schedulers And Queue Size #############################
        dm-0 | UNREADABLE
        dm-1 | UNREADABLE
     nvme0n1 | [none] 1023
         sda | [mq-deadline] 256
         sdb | [mq-deadline] 256
         sdc | [mq-deadline] 256
# Disk Partitioning ##########################################
Device       Type      Start        End               Size
============ ==== ========== ========== ==================
/dev/nvme0n1 Disk                             375083606016
/dev/nvme0n1p1 Part       2048  732585167                  0
/dev/sda     Disk                            1798999900160
/dev/sda1    Part       2048     499711                  0
/dev/sda2    Part     501758 3513669631                  0
/dev/sda5    Part     501760 3513669631                  0
/dev/sdb     Disk                            1920383410176
/dev/sdc     Disk                            2048408248320
# Kernel Inode State #########################################
dentry-state | 24986	12904	45	0	540	0
     file-nr | 4400	0	1000000
    inode-nr | 24558	0
  VG           VSize  VFree
  smblade03-vg <1.64t    0 
# RAID Controller ############################################
  Controller | Fusion-MPT SAS
# Network Config #############################################
  Controller | Intel Corporation Ethernet Controller 10-Gigabit X540-AT2 (rev 01)
  Controller | Intel Corporation Ethernet Controller 10-Gigabit X540-AT2 (rev 01)
  Controller | Intel Corporation X540 Ethernet Controller Virtual Function (rev 01)
  Controller | Intel Corporation X540 Ethernet Controller Virtual Function (rev 01)
  Controller | Intel Corporation X540 Ethernet Controller Virtual Function (rev 01)
  Controller | Intel Corporation X540 Ethernet Controller Virtual Function (rev 01)
 FIN Timeout | 30
  Port Range | 65000

# The End ####################################################

```
