# Goal: achieving multiplatform boot for APEs

While [Cosmopolitan APEs](https://cosmo.zip/pub/cosmos/bin/) offer OS independance and can even work baremetal in a specific case (MBR), there can be times and usecases where it's desirable to have the intermediate layers offered by an OS (ex: drivers, networking)

[Cosmopolinux is based on the Linux kernel and made for these usecases](https://github.com/csdvrx/cosmopolinux/), so it should also facilitate working baremetal without depending on MBR boot.

However, booting the Linux kernel can be complicated, especially it baremetal: this document summarizes my understanding of the different ways the [baremetal firmware boot process works and can be "lured"](https://lists.debian.org/debian-qa-packages/2016/01/msg00201.html) to start cosmopolinux.

If you find any error in this document, please tell me!

# TLDR; Conclusions first please!

[Xorriso integrates and automates the various ways to boot](https://www.gnu.org/software/xorriso/) that are described in this document, with the only drawback of using a ISO9660 filesystem.

Most of our current hardware uses UEFI which mandates VFAT, but neither NTFS nor ISO9660. ISO9660 support risks being deprecated along with optical media boot some day.

NTFS is widely supported thanks to Windows popularity, but booting a NTFS directly requires using Rufus due the lack of UEFI drivers in most firmware. A menu based solution like Grub can be used, but shouldn't be relied on: bootloaders and menus are nice to have, but inherently fragile.

ISO9660 is a nice way to boot, but only:

- because of its tolerance for large initial blank spaces (8K, the next best is EXT4: 1K) that allows hybridizing with partition schemes like MBR or GPT,
- thanks the long history of using optical media for installation: the addition of El Torito extensions to ISO9660 sealed its position and ensured its still present dominance.

However, ISO9660 is already old, so much that it may create more problems than it solves due to the bagage and limitations it brings.

Other filesystems are not as tolerant for initial blank spaces as ISO9660 can be, so it doesn't seem easy to use these other filesystems to make a hybrid (polyglot) firmware boot.

On top of that, there's far less tooling that what Xorriso can offer right now.

Yet there's no justification for bringing-in the requirement of another filesystem (ISO9660) on top of what's required for UEFI boot (VFAT) and for multiplatform support (NTFS), especially considering ISO9660 read-only nature, given how universal UEFI has now become.

Floppy disks had been an historically reliable method to boot before being replaced by optical media. Bringing in floppies previous limitations into ISO9660 as a boot option was a necessary, yet temporary solution: emulated floppy images boot is now mostly useless.

It seems better to bring the good ideas from ISO9660 boot, without bringing in everything else.

# The "3 boots"

Historically, the firmware that was booting from the MBR partition scheme was called a BIOS.

The BIOS has been replaced by a firmware called UEFI which boots from a GPT partition scheme, more specifically from the EFI partition.

Before UEFI became the accepted solution, many hacks were added: some of them still work and can be used to boot.

Here I present what I call the "3 boots" (MBR, UEFI, optical media): if each one of them is supported, I believe the firmware differences can be fully abstracted away, and (*) most hardware should be able to boot a linux kernel.

(*): Note that while UEFI is supported by some hardware using ARM CPUs (both for Microsoft Windows or Apple MacOS), for most ARM devices like Google Android cellphones and tablets, UEFI is not yet an acceptable solution: instead, these devices use a devicetree and a custom bootloader like uBoot.

The exception is Google chromebooks which use coreboot, a free-software BIOS, which can interface with these boots through seabios (BIOS) or tianocore (UEFI).

Overall, this means the boot can't yet be UEFI only: it needs to be supplemented by at least another boot method, and maybe more.

For cosmopolinux, I decided against a "full" ISO9660, but how it can be used to boot through El Torito is worth studying.

## 1) "Historical" BIOS MBR boot

### 1.1) Boot from inside the MBR directly

[As explained in ArchWiki page](https://wiki.archlinux.org/title/Partitioning#Master_Boot_Record_(bootstrap_code)), the first 512 bytes of a storage device contain a bootloader: the bootstrap code is the first 446 bytes, containing the first stage of the bootloader:

 - 3 bytes to jump to the boot code

 - 8 bytes for a disk signature or OEM Id (shown as PTUUID in blkid)

 - 435 bytes for the boot code, starting at offset 0x00B

The MBR first stage bootloader usually jumps to a second stage bootloader, located in the partition header, so the offset depends on the partition type:

 - the first 62 bytes of FAT or NTFS partitions contain the partition boot record (PBR), so on these partitions the second stage bootloader is located at 0x3E

 - the first 1024 bytes of EXT2/3/4 partitions contain the PBR, so on these partitions the second stage is located at offset 0x400

### 1.2) Boot with a bootable MBR partition

The MBR is located at the physical offset 0, and the 446 bytes of the bootstrap code are followed by 4 entries of 16 bytes each: these 4 MBR partitions defined right after the bootstrap code are then suffixed by a 2 bytes boot signature 0x55AA.

Each one of the MBR 4 primary partitions can also be marked bootable.

A MBR partition can be marked bootable (1 byte boot flag at offset 0x00: 0x80 means active), but it can only be chainloaded if whatever bootloader that was reached through the bootstrap stages decides to: the MBR boot code searches the MBR for a bootable partition, then loads the partition PBR, passing the partition size to the PBR.

The bootloader decision can be controlled by a bootloader boot menu (ex: grub) or through predefined scenarios [like holding the Ctrl key for isolinux](https://wiki.syslinux.org/wiki/index.php?title=Isohybrid): in either case, the bootloader may decide to load into memory the first sector of this partition marked bootable.

### 1.3) Hybrid MBR boot over the 32 bit limit

The [e09127r3 EDD-4 Hybrid MBR boot code annex](https://www.fpmurphy.com/public/EDD-4_Hybrid_MBR_boot_code_annex.pdf) overview on the first page, and note 3 on the last page reminds how this can only happen within the 32 bit MBR LBA limit, and how the MBR can be used to boot GPT partitions with hybrid MBR boot code passing extra information beyond the MBR LBA-32 limits thanks to the GPT partitions.

### 1.4) The special case of "MBR boot" with only GPT partitions

When no MBR partitions are defined, bootloaders like grub still need to put their stages somewhere: a specific GPT GUID is defined (21686148-6449-6E6F-744E-6565644546492) to tell grub it can use a given GPT partition for that purpose: the partition has to be at least 1M.

As a shortcut to the GUID, gdisk uses the nickname EF02, and parted defines this as "bios_grub".

### 1.5) PBR vs VBR

When there's no MBR partition, the PBR tend to be called Volume Boot Records (VBR) instead, but PBR and VBR refer to the same concept. The main difference is the PBR is located at the first sector of a partition, while the VBR is at the first sector of a volume which can span multiple partitions.

This tiny detail is important, because unlike xorriso, hdisk will try to create El Torito VBR that map to PBR, by presenting as a ISO9660 volume without using the whole ISO9600 read-only filesystem.

## 2) El Torito boot for ISO9660

When a media is defined as an optical media (CD, DVD, BD), the firmware expects a partitionless-disk made of just an [ISO9660 filesystem](https://en.wikipedia.org/w/index.php?title=ISO_9660), and knows to look for the equivalent of Volume-Boot-Record (VBR): they are called ["El Torito" records](http://bazaar.launchpad.net/~libburnia-team/libisofs/scdbackup/view/head:/doc/boot_sectors.txt)

There are different types of El Torito records: they can be identified with a hex number, and some type of eltoritos are known for a specific use (xorriso mentions "bios", "mac", "ppc", "uefi")

### 2.1) El Torito emulation of floppies or hard drives

El Torito records may contain an image file of either a floppy disk (assigned the BIOS ID 0x00) or a hard drive (assigned the BIOS ID 0x80): these are called the "emulation modes", and are mostly useful for old operating systems.

There's also a "non emulation" mode, which just gives the binary payload: it is useful for booting modern operating systems.

### 2.2) El Torito non emulation as another bridge to the MBR mode

Booting from optical media can then piggyback on the MBR boot by having an El Torito "bios" record providing an MBR bootloader like isolinux as the binary payload.

However, there's an obvious limitation: when the media is not an optical media (or if the media is not identifiable as such), the firmware will not look for El Torito records.

This can be a problem: in that case, a USB thumbdrive with just a ISO9660 filesystem only containing El Torito records wouldn't be bootable, as it wouldn't be identified as an optical media.

However, it's possible to hack a 512 byte MBR header into the ISO file: this is called making an ISOHybrid record.

The same ISO file can then serve as a template for making both optical medias (now rare) and thumbdrives (more frequent).

### 2.2.1.A) Going back to direct MBR boot with ISOHybrid records

Having ISOHybrid records means the same image can be written to an optical drive or a thumb drive, and that you can produce a bootable thumbdrive with just `cat image.iso > /dev/sda` - or the fancier shell version with `dd`, or the GUIs like Rufus, [Win32DiskImager](https://sourceforge.net/projects/win32diskimager/) etc.

The only drawback is the first partition will be a read-only ISO9660 partition, for which no official MBR partition type exists (0xCD is a linuxism).

Not declaring a patition type but using 0x00 instead creates a ["Barely specs compliant MBR partition table with nested partitions"](https://lists.gnu.org/archive/html/bug-xorriso/2015-12/msg00062.html) which is not UEFI compliant, as nesting is disallowed by UEFI: as explained on osdev: ["Several popular Linux distributions offer a layout that does not comply to either of the UEFI alternatives. The MBR marks the whole ISO by a partition of type 0x00. Another MBR partition of type 0xef marks a data file inside the ISO filesystem with the image of the EFI System Partition FAT filesystem. Nevertheless there is a GPT which also marks the EFI System Partition image file. This GPT is to be ignored by any UEFI compliant firmware. The nesting of the MBR partitions is made acceptable by giving the outer MBR partition the type 0x00, which UEFI specifies to be ignored"](https://wiki.osdev.org/El-Torito#Hybrid_Setup_for_BIOS_and_EFI_from_CD.2FDVD_and_USB_stick)

However, it works very well in practice.

### 2.2.1.B) Other types of ISOHybrids

The ISOHybrid presented is just one type of ISOHybrid (the MBR one is called isohybrid-mbr). There's also a GPT version called 'gpt-basdat' in xorriso.

There are more types of ISOHybrid records:

 - historically, 'apm_hfsplus' was used for Macs (which required hfsplus to boot) to mention the boot image in an invalid GPT

 - the less ancient 'gpt_hfsplus' did the same for GPT and hfsplus

 - for Apple Silicon ARM-based Macs, APFS partition scheme hybrids could also be defined?

These APFS hybrids are based on GPT, but support extra features like space sharing, cloning etc.

### 2.2.2) El Torito as a bridge to UEFI boot

El Torito was designed when the firmware could only be a BIOS, but El Torito was planned to be future proof and to support multiple different architectures called "platforms": there are multiple type of El Torito records (including one for UEFI) and there can be multiple El Torito records within one optical media, so it's possible to have:

 - one El Torito for the BIOS platform, supplemented by ISOHybrids for media that will not be seen as optical media

 - another El Torito for the UEFI platform, supplemented by actual EFI partitions and paths for non-optical media

UEFI boot uses partitions instead staged bootstrap like the BIOS, so the [UEFI El-Torito record will contain the image of a EFI boot partition, but it may also contain a link to it](https://lists.debian.org/debian-cd/2019/07/msg00007.html)

## 3) "Modern" UEFI boot

UEFI boot is more complicated to explain, but is well summarized [in the UEFI Arch wiki page](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface)

UEFI can boot like the BIOS, but it can do more:

 - UEFI can offers menus without having to use a bootloader thanks to "special" UEFI variables (with the GUID 8BE4DF61-93CA-11D2-AA0D-00E098032B8C) to define a boot order and boot options. The variables like BootOrder, BootCurrent, BootNext, Boot####, and Timeout are handled by the UEFI firmware:

  - this is what `efibootmgr` lists and can change on Linux

  - this is what `bcdedit /enum firmware` lists on Windows, and what [GetSetVariable can manipulate on Windows](https://github.com/ProSlatisa/GetSetVariable)

 - For the paths to the payloads on the disks, UEFI can use:

  - EDD1.0 BIOS IDs (ex: 0x80)

  - EDD3.0 full device paths (starting at the PCIe root device)

  - abbreviated HD paths (using GPT PARTUUID, even if it's limited to VFAT partition in practice)

  - Even better: UEFI can also look inside a "special" EFI partition (GPT GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B, MBR type 0xEF) to look at the defaults bootloader stored inside at some well-known path, and select one depending on the platform

 - As a failback, if none of these path works, the UEFI shell will execute "startup.nsh"

UEFI variables are nice to configure an ordered boot sequence, eventually with a custom booloader, but [like all boot menus they are fragile](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface#Boot_entries_are_randomly_removed): it seems better to let UEFI handle the bootloader selection using the special EFI partition, as it's based on paths and well-known names that can be automatized, with startup.nsh as a fallback.

## 3.1) UEFI boot with the special EFI partition

The default bootloaders are stored in the /EFI/BOOT path of the EFI partition which must be type vfat, and there are 2 standard names prefix: "boot" and "shell", followed by the architecture, then the ".efi" suffix, so for "boot"

  - on x86-64 (x64 also called amd64): bootx64.efi as /EFI/BOOT/BOOTX64.EFI

  - on IA-32 (ia32 also called x86 or i386): bootia32.efi as /EFI/BOOT/BOOTX64.EFI

  - on ARM 64 bit (aa64): bootaa64.efi as /EFI/BOOT/BOOTAA64.EFI

  - on ARM 32-bit (ar32): bootar32.efi as /EFI/BOOT/BOOTAR32.EFI

These default bootloaders are what's used when booting while pressing the Option key on a Mac, to override the configured bootloader and use the default instead, which is:

 - /EFI/BOOT/BOOTIA32.EFI on Intel Macs from 2006-2007

 - /EFI/BOOT/BOOTX64.EFI on Intel Macs 2007+

 - /EFI/BOOT/BOOTAA64.EFI on ARM Apple Silicon M1+ Macs?

## 3.2) UEFI multiplatform boot with just 2 paths

The well known path and prefix could be used to boot both PC and Macs by creating multiple bootloaders, essentially:

 - /EFI/BOOT/BOOTX64.EFI for PCs, [making an UKI the Arch way](https://wiki.archlinux.org/title/Unified_kernel_image) [with systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html) [EFI stub](https://wiki.archlinux.org/title/EFISTUB)

 - /EFI/BOOT/BOOTAA64.EFI for Apple Silicon (M1+) Macs, using an Asahi optimized kernel in the UKI

 - /System/Library/CoreServices/boot.efi could be an alternative path to use for Asahi exclusively, and excluding Windows laptops with a Qualcomm ARM64 CPU or [RK3xxx series CPU](https://archlinuxarm.org/forum/viewtopic.php?f=8&t=15777) which could otherwise use /EFI/BOOT/BOOTAA64.EFI (these Qualcomm based laptops haven't been very successful so it may not matter, also TODO: it's not clear if /System/Library/CoreServices/boot.efi is as robust as /EFI/BOOT/BOOTAA64.EFI)

Some old rare PC based on the Silvermont-based Bay-Trail CPU, like the Intel Atom Processor E3800 and Z3700 and the Intel Pentium and Celeron Processor N- and J-Series) would benefit from /EFI/BOOT/BOOTIA32.EFI, but there're too few of them, and [mixed-mode UEFI loaders already exist to load a 64 bit kernel from 32 bit EFI](https://github.com/lamadotcare/bootia32-efi)

Unsupported architectures could have a grub-based menu, to avoid leaving their users in the dust during boot problems: something that can help rescue your system is better than the alternative of "nothing".

Asahi partition schemes uses [NVMe namespaces and containing partitions](https://leo3418.github.io/asahi-wiki-build/partitioning-cheatsheet/)

## 3.3) UEFI boot without the special EFI partition

On top of the EFI partition of the internal drive, many UEFI firmware can find an EFI bootloader standard path (like /EFI/BOOT/BOOTX64.EFI) from the main partition of the thumbdrive, but sometimes with a lesser priority, unless the thumbdrive "looks like" an optical drive due to an apparently missing first partition.

This is another reason to have an hybrid MBR/GPT partition setup, with the 1st MBR partition being "invisible" due to type 0x00 and therefore pointing to the bare media - but where an EFI/ path has also been created just in case.

If using this "invisible main partition" fails, having a second MBR partition type 0xEF matched by a second GPT partition with the GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B means the UEFI firmware will find one one these EFI partition!

However, the hybrid GPT partitions created by xorriso are not made with type EFI (GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B) but with type Microsoft Basic Data (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7) or even Linux IDs by default, which seems to be a bug due to incomplete mappings between MBR partition types and GPT partition GUID (TODO: check if it is)

An alternative would be to have a mix of partitions (TODO: in what order?) like Ubuntu:
 - 0xEE but not covering the whole disk, to indicate GPT should be preferred,
 - 0x1B or 0xEF yet marked bootable to try to trick the firmware into booting them by their PBR.
 - in an hybrid MBR with a partition type 0x00 yet also bootable to look like an optical media.

# 4) Looking at actual media for how to do it

However, this Ubuntu 22 layout seems more problematic for some firmwares: checking the ISOs of various distributions has shown Ubuntu 22 to be an outlier, even for Ubuntu LTS.

I started by writting 2 basic tools, mbr-read.pl (for MBR) and gpt-read.pl (quite obviously for GPT!) to not make assumptions about the partitions going by the rules, but to instead show me separately the content of the GPT and MBR: in case they diverge, I could then quickly see how!

After I started looking at existing boot media, the differences where so interesting that I merged them into one tool which became the base of [hdisk](http://github.com/csdvrx/hdisk/): this is the output presented by hdisk-print
