## Disks and Volumes

A Linux system sees physical disks as device files like `/dev/sda` or `/dev/nvme0n1`. These raw disks need a layer of organization before the operating system can use them efficiently.

**Logical Volume Management (LVM)** bridges the gap between physical hard drives and the operating system. Instead of working with fixed disk partitions, LVM lets you pool storage from multiple disks and carve out flexible virtual partitions on demand.

The abstraction has three layers:

- **Physical Volumes:** The actual physical disks or partitions.
- **Volume Groups:** A pool of storage that collects one or more physical volumes.
- **Logical Volumes:** Virtual partitions carved from a volume group, which hold a filesystem.

The diagram below shows how these layers fit together, from the physical hardware up to the directories the operating system sees:

```mermaid
graph TD
    subgraph Operating System Layer
        M1["/mnt/data"] --> LV1(Logical Volume 1: lv_data)
        M2["/"] --> LV2(Logical Volume 2: lv_root)
    end
    
    subgraph LVM Allocation Pool
        LV1 & LV2 --> VG1[(Volume Group: vg_system)]
    end
    
    subgraph Physical Hardware Layer
        VG1 --> PV1(Physical Volume: /dev/sda)
        VG1 --> PV2(Physical Volume: /dev/sdb)
        PV1 --> Disk1[Physical HDD 1]
        PV2 --> Disk2[Physical SSD 2]
    end
    
    style VG1 fill:#f9f,stroke:#333,stroke-width:2px
    style LV1 fill:#bbf,stroke:#333,stroke-width:1px
    style LV2 fill:#bbf,stroke:#333,stroke-width:1px

```

### Creating a Logical Volume

Setting up a logical volume takes six steps, from initializing the physical disk to writing data. The following flowchart outlines the full process, with the corresponding command at each stage:

```mermaid
flowchart TD
    Start([Start]) --> Step1
    
    Step1[1. Initialize Physical Volume] -->|Command: pvcreate /dev/sdb1| Step2
    
    Step2[2. Create Volume Group] -->|Command: vgcreate vg_data /dev/sdb1| Step3
    
    Step3[3. Create Logical Volume] -->|Command: lvcreate -n lv_data -L 10G vg_data| Step4
    
    Step4[4. Create Filesystem] -->|Command: mkfs.ext4 /dev/vg_data/lv_data| Step5
    
    Step5[5. Mount Volume] -->|Command: mkdir -p /mnt/data \n mount /dev/vg_data/lv_data /mnt/data| Step6
    
    Step6[6. Write Data] -->|Command: echo 'Hello, World!' > /mnt/data/data.txt| Finish([Done])

```

### References

- [LVM](https://ubuntu.com/server/docs/explanation/storage/about-lvm/)