# hdisk: a programmatic hybrid partition editor and reader making GPT ♡ ❤ ♡ MBR

After studying how booting works, I wanted to make a xorriso-based iso9660 [cosmopolinux to complement the ntfs3 image](https://github.com/csdvrx/cosmopolinux/) to get something like Ubuntulive for demo/install/rescue purposes - except that IT'D BE MULTIPLATFORM, because, *COSMOPOLITAN*!

I started by doing experiments with qemu, but they progressed much faster after discovering [Thomas Schmitt work on debian, with his arm64 based experiments](https://lists.debian.org/debian-cd/2015/01/msg00104.html) and [his x86-64 improvements](https://lists.debian.org/debian-cd/2019/07/msg00007.html): [make sure to check his notes](http://bazaar.launchpad.net/~libburnia-team/libisofs/scdbackup/view/head:/doc/boot_sectors.txt) to understand why [it's better to minimize changes](https://lists.debian.org/debian-user/2017/03/msg01262.html) to well-known and well-tested layouts, like the MJG59 layout that's still very popular, with GPT partitions + MBR partitions + using type 0x00 for the first MBR partition to look like an optical drive to let the firmware boot through El Torito while still offering usable partitions on the thumbdrive.

I was very hopeful, and [I got more or less what I wanted](https://gitlab.com/csdvrx/cosmopolinux/-/blob/main/cosmopolinux.iso.bz2?ref_type=heads) but it was very difficult to get precisely what I wanted for both the MBR and the GPT at the same time, including labels, alignments, precise GUIDS etc: I had to use dd and hexedit more than I wanted to.

When I realized I was trying to use xorriso to fit round peg in a square hole, I decided instead to write my own partition tools.

First it was to get a precise analysis of the existing medias, then for tweaking both the GPT and the MBR, and how I got hdisk: it's not fancy, but that's how it got started: to check what makes some ISO images boot better than others!

# 1. What's hdisk

hdisk is currently a set of scripts to read and programatically write hybrid partition tables to the MBR, the GPT and the backup GPT.

The 'h' stands for "hybrid", but 'h' is also the letter right after 'f' (fdisk) and 'g' (of gdisk, which replaced fdisk). This makes 'hdisk' looks very nice: since I want to eventually write a user interface to manage partitions, this 'h' will make hdisk look *so much better* that the 'f' and 'g' stuff lol

Note that hdisk is abusing both the MBR and GPT partition scheme, but is perfectly suitable for the installation media.

On an actual drive, it creates the risk of having the MBR and GPT go out-of-sync when the partitios are updated, which could break the boot, but 1) I think it's generally safe if you use 4 partitions or less, and 2) I really wanted to try, so 3) I did and it really works!

For more permanent uses, nothing prevents you to do the same, and making a MBR that's not just protective: some 0xEE partitions can be created to signal there's a GPT scheme too, while letting you experiment with MBR bootable partitions.

Just please be comfortable with the risk of making you drive unbootable. Make backups. Learn how booting (and partitions) work to avoid that risk!

### 1.1) Keeping the MBR and GPT in sync

You are supposed to use *either* the MBR partition scheme *or* the GPT partition scheme, not *both* but ¿¿Porque no los dos?? 

hdisk makes that not just possible but easy:

 - in theory, a disk with GPT partitions should have a single 0xEE "protective" MBR partition to let applications know the MBR partition scheme is deprecated, and that they should check the records from the GPT partition scheme instead

 - in practice, partitions can be defined to point to the same range for each partition scheme, while being defined separately and independently for each schemes:

  - in the MBR partition scheme, at LBA 0, so after the 446 first bytes of the first stage bootloader

  - in the GPT partition scheme, at LBA 2, so at 1024 bytes=512x2 for disks with a 512 bytes sector size, or at 8192 bytes=4096x2 for disks with a 4096 bytes sector size

 - but then it's on you to have the partitions declared in the MBR and the GPT to always "match" the same real partitions and never go out of sync!

There's a limit: you can only do that for the first 4 partitions.

The limiting factor is the MBR partition scheme, for which 4 primary partitions are easier to handle as "extended" partition are weird and require more space: the GPT starting at LBA 1 is the #1 issue, since extended MBR partitions can make the MBR go past 512 bytes.

However, LBA 1 is at 512 bytes only if the sector size is 512, and that's not the case for 4kn disks where LBA 1 is at 4096 bytes.

More than 4 MBR partitions could then be supported by adding as many extended partitions as needed (and as can fit): the limit on the number of partitions to 4 is just because existing tools only handle primary MBR partitions (not extended partitions), and this is only because most disks are not 4kn. Yet these limits could be bypassed by creating better tools and using 4kn drives.

Even if staying within a limit of 4 partitions, it should be possible to keep both schemes in syncsay if the bootloader was aware of the trick, and either itself or the OS kept a log of changes.

## 1.2) Wait, isn't that risky?
 
 There's [extensive documentation of the risks and what to be careful with](https://www.rodsbooks.com/gdisk/hybrid.html) by the author of gdisk who also explains he decided not to write such tools: *"I’ve decided not to open that particular can of worms. Even if I were willing to deal with the squirmy creatures, adding this “feature” would mean I’d be dumping the worms into the laps of the authors of every OS and utility that supports GPT, and I consider that very rude at best."*
 
Yet I've started creating hdisk, so I guess this makes me very rude on top of finding worms cute i
n their own way lol

Also a can of squirmy worms would make a cute logo for hdisk lol

## 1.3) What's planned

I want to have a fine control of the boot image. I want to have an equivalent of Xorriso, that A) at least uses similar tricks as xorriso uses for iso9660, but B) that can also use new tricks for other common filesystems.

These tricks could be made safer by tweaking existing bootloaders or partitions, to make them aware of these tricks at the partition or filesystem level (for example: updating the $BadClus system file that indicates the resident bad cluster stream on NTFS, [as it's already possible with other tools](https://github.com/jamersonpro/ntfsmarkbad), but this time to stuff bootable payloads there.

For cosmopolinux, I want to do the regular baremetal boot through EFI whenever possible:

 - either with an UKI inside the existing drive EFI VFAT partition,

 - or with an UKI started though the [Akeo UEFI:NTFS bootloader](https://github.com/pbatard/uefi-ntfs) as the EFI partition can be too small

However, hdisk will give more leeway by:

 - also allowomg old BIOS boot: it's seems reliable, since it's still supported and existing, it's more likely to keep existing in the future

 - making BIOS boot and UEFI boot work hand-in-hand by marrying MBR and GPT in hybrid MBRs (note to self: alternative idea for a logo:  MBR ♡ ❤ ♡ GPT)

# 2. What's ready

There is:

 - mbr-read.pl to print the GPT partitions
 - gpt-read.pl to print the MBR partitions
 - hdisk-read.pl to synthesize the information in an easy-to-digest format, guessing the block size if it's not 4096 by looking where the EFI signature is
 - mbr-tweak.pl to tweak the MBR of an image to make it look the way I want

# 2.1) What's coming next

I'm still working on the gpt-tweak.pl (CRC32 everything!) and the more generic hdisk-tweak.pl that'll change both the MBR and the GPT at the same time.

Once it's done, it should put hdisk on-par with other partition editing tools like the fancy parted or the cool kid gdisk - with the *tiny exception* of the lack of any user interface, even as mere commandline flags!

But when you can have the power of a perl script, who needs that '''interface''' thing? 😅

I've just started on my next main step, a script that defines a disk image sector-by-sector. Once it's done, the next move would be tweaking the NTFS partitions to mark some sectors as 'bad' to reserve them, so I can stuff there the boot payloads I want.

I think I'll do it like a defrag would, using empty sectors: then hdisk will have to learn about a few filesystems, at least enough to use these fake bad areas to stuff the boot payloads there, while presenting them on the GPT and the MBR in a way that's suitable for the firmware to boot from.

I have no idea how I'll do it yet: GPT MBR bootable parts? El Toritos? A mini iso9660 inside? I'll see!

# 3. How it works

## 3.1) Reading partitions

You use `hdisk-read.pl` over a file (like cosmopolinux.iso) or a block device, and you get all the partition data.

For example, on the test image I made with xorriso then tweaked with hdisk to look like an Ubuntu 22 iso (with a 0xee protective MBR partition), `hdisk-read.pl ../cosmopolinux.iso` gives me this output:
```
# DEVICE
Checking ../cosmopolinux.iso.gpt with a LBA block size 512
(block size irrelevant for the MBR at LBA0, but important for GPT at LBA1)
Size 0.31 G, rounds to 640031 LBA blocks for 640031.998046875
WARNING: this is more than LBA-28 can handle (many MBR use LBA-32)

MBR HEADER:
Disk UUID: 00000000
Signature (valid): 55aa
2 null bytes (valid): (obviously not visible)

MBR PARTITIONS:
Partition #1: Start: 1, Stops: 640031, Sectors: 640031, Size: 312 M
 Nick: ee00, Text: MBR protective partition, MBR type: EE, Status: 00
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        seen CD001 at lba: 32, offset: 65536, type: 1
        seen CD001 at lba: 33, offset: 67584, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT HEADER:
Signature (valid): EFI PART
Revision: 00010000
Header size (hardcoded 92): 92
Header CRC32 (valid): 5af5d325
Current header (main) LBA: 1
Other header (backup) LBA: 640031
First LBA: 64
Final LBA: 639968
Disk GUID: 20405E0B-262D-4AD5-999E-38DC783C65FD
GPT current (main) LBA: 2
Number of partitions: 248
Partition record size: 128
Partitions CRC32 (validity unknown yet):  4146acb2

# MAIN GPT PARTITIONS:
Partitions CRC32 (valid): 4146acb2
Partition #0: Start 64, Stops: 133119, Sectors: 133056, Size: 64 M
 Nick: 0700, Text: Microsoft basic data, Name: ElTorito, GUID: EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
 Attributes bits set: 0 (Platform required partition), 60 (Read-only),
Partition #1: Start 133120, Stops: 229767, Sectors: 96648, Size: 47 M
 Nick: ef00, Text: EFI system partition, Name: EFISP, GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
Partition #2: Start 229768, Stops: 639367, Sectors: 409600, Size: 200 M
 Nick: 0700, Text: Microsoft basic data, Name: Cosmopolinux, GUID: EBD0A0A2-B9E5-4433-87C0-68B6B72699C7

# BACKUP GPT header (valid offset for LBA-1 -> 327695872): 640031
BACKUP CRC32 (valid): d7d9d150
BACKUP GPT current (backup) LBA: 639969

# BACKUP GPT PARTITIONS:
# BACKUP GPT AT (WARNING: UNEXPECTED AT 327695360 SINCE LBA-2 -> 640030): 639969
BACKUP Partition CRC32
```

I'm still working on the GPT backup offset: I get similar warnings on my NVMe when I run `hdisk-read.pl /dev/nvme0n1` (note how I forgot to specify 4096 as a parameter for 4kn)

```
# DEVICE
Checking /dev/nvme0n1 with a LBA block size 512
(block size irrelevant for the MBR at LBA0, but important for GPT at LBA1)
Size 1907.73 G, rounds to 4000797359 LBA blocks for 4000797359.99805
WARNING: this is more than LBA-28 can handle (many MBR use LBA-32)
WARNING: this is more than LBA-32 can handle (many MBR use LBA-32)
(...)

GPT HEADER:
Signature (WARNING: INVALID):
 Trying again after setting bsize=512,2048,4096, and this worked.
WARNING: Wrong bsize was given, should have been 4096
Size 1907.73 G, rounds to 500099669 LBA blocks for 500099669.999756

(...)

# BACKUP GPT header (valid offset for LBA-1 -> 2048408244224): 500099669
BACKUP CRC32 (valid): c891d90c
BACKUP GPT current (backup) LBA: 500099665

# BACKUP GPT PARTITIONS:
# BACKUP GPT AT (WARNING: UNEXPECTED AT 2048408240128 SINCE LBA-2 -> 500099668): 500099665
BACKUP Partition CRC32 (valid): d1609950
```

It think it may be related to rounding issues of the offset bytes, since bot 500099668-500099665 and 640030-639969 are very close.

## 3.2) Writing partitions

If you want to write partition data, edit the scripts to either write directly what you want, or to go through a simple 'if-this-then-that logic' using your partitions data, like in mbr-tweak.pl:

```
# Part 1 starting at 64, even if type 0 could be an issue?
# make it start at 0 if type 0 and contains iso records
if (defined($partitions{0}{isosigs})) {
 if ($partitions{0}{isosigs}>2) {
  if ($partitions{0}{type}==0) {
   $partitions{0}{start}=0;
  }
 }
}

# Mark partition 2 active if EFISP
if ($partitions{1}{type}==0xef) {
 $partitions{1}{status}=0x80;
}

# Type partition 3 as NTFS if linux
if ($partitions{2}{type}==0x83) {
 $partitions{2}{type}=0x07;
}
```

Note that this is just for the MBR. When the GPTs are added to hdisk-tweak, you'll have 3 hash you can use in your logic:

 - %partitions_mbr
 - %partitions_gpt
 - %partitions_gptbackup

The end result should be synchronized on all 3 unless you decide to do things differently for your own reasons.

# 4) Using hdisk to look at a few ISOs

## 4.1) Ubuntu

Here I only compare the LTS, to discard potential experiments or A/B testing on non-LTS uses. I've also removed the headers and the secondary GPT to keep the summaries shorter.

You may want to jump directly to Ubuntu 22, as something new started happening with it!

I'm impatient to see if Ubuntu 24 will keep this charge, or revert to the previous ways?

### 4.1.1) Ubuntu 16

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: 3100799, Sectors: 3100800, Size: 1514 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 3006684, Stops: 3011355, Sectors: 4672, Size: 2 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 0, Stops: 3100743, Sectors: 3100744, Size: 1514 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 3006684, Stops: 3011355, Sectors: 4672, Size: 2 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
```

### 4.1.2) Ubuntu 18

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: 3753599, Sectors: 3753600, Size: 1832 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 3672780, Stops: 3677451, Sectors: 4672, Size: 2 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 0, Stops: 3753543, Sectors: 3753544, Size: 1832 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 3672780, Stops: 3677451, Sectors: 4672, Size: 2 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
```

### 4.1.3) Ubuntu 20

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: 5439487, Sectors: 5439488, Size: 2656 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 5017392, Stops: 5025327, Sectors: 7936, Size: 3 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 0, Stops: 5439431, Sectors: 5439432, Size: 2655 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 5017392, Stops: 5025327, Sectors: 7936, Size: 3 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
```

### 4.1.4) Ubuntu 22

```
MBR PARTITIONS:
Partition #1: Start: 1, Stops: 7138587, Sectors: 7138587, Size: 3485 M
 Nick: ee00, Text: MBR protective partition, MBR type: EE, Status: 00
Partition #2: Start: 0, Stops: 0, Sectors: 1, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        seen CD001 at lba: 32, offset: 65536, type: 1
        seen CD001 at lba: 33, offset: 67584, type: 2
        seen CD001 at lba: 34, offset: 69632, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 64, Stops: 7129427, Sectors: 7129364, Size: 3481 M
 Nick: 0700, Text: Microsoft basic data, Name: ISO9660, Attrib: 1000000000000001
Partition #2: Start 7129428, Stops: 7137923, Sectors: 8496, Size: 4 M
 Nick: ef00, Text: EFI system partition, Name: Appended2, Attrib: 0000000000000000
Partition #3: Start 7137924, Stops: 7138523, Sectors: 600, Size: 0 M
 Nick: 0700, Text: Microsoft basic data, Name: Gap1, Attrib: 1000000000000001
```

### 4.1.5) Ubuntu conclusions

We can see the MBR partitions have started using a 0xEE protective partition that's defined as the first MBR partition, with the ISO ("empty") partition being in the 2nd position, and the GPT partition 1 containing the same ISO9660 having the El Torito records, with the partition being declared as type 0700 on the GPT while it's not!

It's a change that hasn't been adopted by the Ubuntu-based PopOS as of the 22.04 version (see below)

## 4.2) Windows

### 4.2.1) Windows 7 32 bits

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.2.2) Windows 7 64 bits

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.2.3) Windows 8

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 255
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
```

### 4.2.4) Windows 10 from 2016

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.2.5) Windows 10 21H2

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.2.6) Windows 11 2200

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.2.7) Windows 11 22H2

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.2.8) Windows conclusions

Windows seems to be extremely stable it its choices: only MBR, no GPT!

## 4.3) Other linux distributions

### 4.3.1) Alpine 3.17 x64

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: 313343, Sectors: 313344, Size: 153 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 300, Stops: 3179, Sectors: 2880, Size: 1 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 0, Stops: 313279, Sectors: 313280, Size: 152 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 300, Stops: 3179, Sectors: 2880, Size: 1 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
```

### 4.3.2) Fedora 36-1-5

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: 3941695, Sectors: 3941696, Size: 1924 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 172, Stops: 20455, Sectors: 20284, Size: 9 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 20456, Stops: 63127, Sectors: 42672, Size: 20 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 0, Stops: 3941631, Sectors: 3941632, Size: 1924 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 172, Stops: 20455, Sectors: 20284, Size: 9 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
Partition #3: Start 20456, Stops: 63127, Sectors: 42672, Size: 20 M
 Nick: af00, Text: Apple HFS/HFS+, Name: ISOHybrid2, Attrib: 1000000000000001
```

### 4.3.3) PopOS 22

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: 6416255, Sectors: 6416256, Size: 3132 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 484, Stops: 8675, Sectors: 8192, Size: 4 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 0, Stops: 6416191, Sectors: 6416192, Size: 3132 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 484, Stops: 8675, Sectors: 8192, Size: 4 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
```

### 4.3.4) Arch 2024.01

```
MBR PARTITIONS:
Partition #1: Start: 64, Stops: 1777663, Sectors: 1777600, Size: 867 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 80
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        seen CD001 at lba: 32, offset: 65536, type: 1
        seen CD001 at lba: 33, offset: 67584, type: 2
        seen CD001 at lba: 34, offset: 69632, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 1777664, Stops: 1808383, Sectors: 30720, Size: 15 M
 Nick: ef00, Text: EFI system partition, MBR type: EF, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

GPT PARTITIONS:
Partition #1: Start 64, Stops: 1777663, Sectors: 1777600, Size: 867 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid, Attrib: 1000000000000001
Partition #2: Start 1777664, Stops: 1808383, Sectors: 30720, Size: 15 M
 Nick: 0700, Text: Microsoft basic data, Name: ISOHybrid1, Attrib: 1000000000000001
```

### 4.3.5) Conclusion on other linux distributions

There is not much diversity - only Fedora stands out by embedding an Apple HFS partition (visible in the GPT, hidden in the MBR, but sharing the same offsets), but they all include an EFI partition right.

Arch is similar to Ubuntu 20, but without a GPT EFISP (nick ef00).

The names "ISOHybrid" followed by a sequential number and some other giveaways like "Gap" suggests all these iso are created by xorriso.

## 4.4) Random tools

### 4.4.1) Lenovo X1 Nano "bios" (firmware) update

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 2
        seen CD001 at lba: 19, offset: 38912, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

### 4.4.2) Memtest86 Pro

```
MBR PARTITIONS:
Partition #1: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
        seen CD001 at lba: 16, offset: 32768, type: 1
        seen CD001 at lba: 17, offset: 34816, type: 0
        seen CD001 at lba: 18, offset: 36864, type: 255
        thus not type 00=empty but has an ISO9600 filesystem
Partition #2: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #3: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00
Partition #4: Start: 0, Stops: -1, Sectors: 0, Size: 0 M
 Nick: 0000, Text: Empty or unused (but also seen in hybrids), MBR type: 00, Status: 00

Invalid GPT signature:
```

## 4.4) Conclusions

The installation media for Windows and even firmware updates themselves are perfectly fine doing a MBR-only boot.

Most computers are made for Windows and to support firmware updates, so it's likely MBR boot will remain supported for a while!

Linux distributions are more daring, mixing MBR and GPT partitions:

 - Fedora is trying to support Macs
 - Ubuntu has started using a slightly different scheme with an 0xEE partition first
 - Arch is surprisingly less innovative than Ubuntu

Arch being less innovative was strange, so I decided to investigate why it seems sufficient for Ubuntu 22 to:

 - have a 0xEE protective MBR partition as the first MBR partition, covering most of the LBA blocks
 - follow it by an extremely small ISOFS partition as the second MBR partition, containing the El Torito records but being just links to the payloads,
 - have the ISO9660 GPT partition declared as a Windows partition: on Ubuntu, it contains an actual ISO9660, and given how popular Ubuntu is, it isn't causing problems in Windows!
 - an EFISP partition folows

There have been discussions for Arch to more or less match Ubuntu 22 format:

 - [have a 0xEE protective MBR partition as the first MBR partition](https://gitlab.archlinux.org/archlinux/archiso/-/commit/729d16b48c99c5d9b23a89123ecde4ecacfa8705)
 - follow by a 0xEF partition 
 - follow it by a 0x83 partition for the ISO9660 filesystem

However, Arch then [removed the 0xEE protective MBR partition since it prevents booting on some Lenovos](https://gitlab.archlinux.org/archlinux/archiso/-/commit/09b6127fe8cabaf9a54a3bb864b0e3e009ca8476) and as [documented and well discussed](https://bbs.archlinux.org/viewtopic.php?id=264096), some rules have to be broken to make an image that will boot on most platforms

# 5) My current ideas for cosmopolinux boot

It seems wise to do as everyone else is doing, and mix MBR and GPT partitions, with the MBR partition being marked as empty but containing an ISO9660 (or at least El Torito records as explained below), without using an 0xEE protective MBR partition if possible, since it disturbs at least some Lenovos which adhere to a strict interpretation of the UEFI specifications

In the worst case, supporting MBR as a fallback means the GPT tricks don't have to be absolutely perfect!

A slightly different method could be based on what Ubuntu 22 has started doing by marking the ISO9600 as Microsoft Basic Data (nick 0700), showing the need for an actual ISO9660 filesystem is debatable: [Arch could almost get away with having /EFI/BOOT/BOOTx64.efi as the only file in the ISO9660](https://gitlab.archlinux.org/archlinux/archiso/-/issues/48#note_12190)

Maybe doing an MBR + GPT hybrid, just embedding the El Torito records for both MBR and EFI boot in an otherwise "empty-ish" partition with no actual ISO9660 content besides these records, then concatenating the actual partition images would be enough?

There should be plenty to boot from:

 - UEFI boot would use the VFAT EFISP (nick ef00) by defining a partition whose content would come from efiboot.img
 - El Torito would points to this efiboot.img and to the MBR to support both modes
 - BIOS boot would have an MBR partition marked bootable, at the same LBA as where the efiboot.img file ended
 - a [sufficient amount of padding would be left before the start of the first partition](https://dev.lovelyhq.com/libburnia/libisoburn/src/branch/master/doc/partition_offset.wiki) which also [prevents disturbing partition editors](https://lists.fedoraproject.org/archives/list/devel@lists.fedoraproject.org/message/DRFSPVZNNN4GVTAKU4RLIG2S57YWLKJ5/)

It may look complicated, but if the partitions are created and kept in sync by hdisk, the only difficulty is finding where to stuff the boot images.

## 5.1) A polyglot bootable image using filesystems bad sectors to stuff the boot payloads

It looks possible to do this better with a polyglot filesystem not depending on ISO9660:

 - the simplest would be to mark some sectors of VFAT and NTFS partitions as 'unusuable'
 - the space for boot records could be kept aside through other ways, [such as using "slack space"](https://www.marshall.edu/forensics/files/RusbarskyKelsey_Research-Paper-Summer-2012.pdf) for VFAT
 - there would be no need to show a read-only iso9660 partition anywhere!

I think marking the sectors as unusable is the safest method to stuff bootable payloads: it can be done on most filesystems, for example:

 - on NTFS, by adding them to the $BadClus system file that indicates the resident bad cluster stream on NTFS
 - on VFAT, by using the special 0xFFFFFF7 value to mark a bad cluster

Maybe it's even possible to directly reuse El Torito records, by having a "mini ISO9660" inside the bad clusters?

Then:

 - the filesystem will mark these areas as "off limit" for the regular OS, which will leave them alone
 - hdisk would create an empty partition before the actual partition
 - as long as the right conditions (MBR partition type 0x00 declaring the partition as "Empty" and starting at 0, yet status 0x80 so bootable) are present, the firmware should start looking inside this empty partition at some well known offsets, since the only way to separate an actualy empty partition from a partition filled with El Torito records is to check if the CD001 signatures are present, so the firmware must be doing just that
 - in the case there's some "negative detection" that makes the firmware stop looking when it recognizes the signature of another filesystem, the El Torito records could be prefixed with enough empty space similar to how padding is added to avoid disturbing partition editors
 - to cover both cases, the El Torito records could be presented in 2 different "0x00 empty" MBR partitions, using different start offsets (0, or not 0) for different firmware tastes (wanting to start at 0, wanting to check the precise LBA)

## 5.2) Proposed partition scheme

I think this should work:

   - MBR part 1 would be 0x00, trying the expose the El Torito records through the usual "start at sector 0" approach, hoping the firmware is just looking for the "CD001" string regardless of the precise offset, but trying to have the CD001 markers at the correct well known offsets of 2048x[16,17,18,19,32,33,34]
   - enough space would be left before the actual partitions start to stuff things at the right well known offsets, which can be calculated by remembering the 2048 record size for ISO9660 has to be translated to a sector size of 512:
    - the first CD001 (at lba: 16, offset: 32768, type: 1) would therefore be at LBA 64 (64=16x2048/512) 
    - the last CD001 (lba: 34, offset: 69632, type: 255) would be at LBA 136 (136=34x2048/512)
   - MBR part 2 would be 0xEF, exposing as the EFISP the VFAT partition also marked bootable (0x80), and contain a Volume Boot Record (VBR) for BIOS MBR boot but a modified bootloader to avoid considering bootable partitions when the type is 0
    - unless this partition starts past LBA 136 (ex: LBA 2048 to get 1 MiB aligned), the CD001 sectors would have have to be marked as defective
   - MBR part 3 would be 0x07, exposing as-is the NTFS partition
   - MBR part 4 would be left free to the user, who could decide to create a 4th partition for advanced filesystems (ex:ZFS) or create a 0xEE protective MBR if more partitions are needed

To get an actual GPT-MBR hybrid, the GPT partitions shouldn't be too difficult to create to match these offsets, now that I understand how the GPT crc32 works.

Regardless of which is used (MBR or GPT), only the firmware should be tricked, and after the boot, the OS wouldn't care about any of that:

 - the specific space used by El Torito records would be marked as unusuable
 - a non-primary MBR may not even be needed, since most OS should ignore the MBR partition thanks to 0xEE (if it can be tolerated by the firmware, so not for Lenovos..)

If the NTFS partition contains a redudant copy of the EFI directory (or whatever is shown by default when the thumbdrive is plugged contains a copy of the NTFS partition data), it should be possible for end users to copy the content of this partition straight to another bootable drive, and [have it work as they expect](https://lists.fedoraproject.org/archives/list/devel@lists.fedoraproject.org/message/DRFSPVZNNN4GVTAKU4RLIG2S57YWLKJ5/)

That should be fun! More experiments are needed!

# 6) Appendix

## 6.1) About the Ubuntu 22 image

Analyzing Ubuntu 22 shows it was created by xorriso with the options:

```
$ xorriso -indev ubuntu-22.04-desktop-amd64.iso -report_system_area plain -report_el_torito plain -report_el_torito as_mkisofs
xorriso 1.5.6 : RockRidge filesystem manipulator, libburnia project.

xorriso : NOTE : Loading ISO image tree from LBA 0
xorriso : UPDATE :     940 nodes read in 1 seconds
libisofs: NOTE : Found hidden El-Torito image for EFI.
libisofs: NOTE : EFI image start and size: 1782357 * 2048 , 8496 * 512
xorriso : NOTE : Detected El-Torito boot information which currently is set to be discarded
Drive current: -indev '/iso/ubuntu-22.04-desktop-amd64.iso'
Media current: stdio file, overwriteable
Media status : is written , is appendable
Boot record  : El Torito , MBR protective-msdos-label grub2-mbr cyl-align-off GPT
Media summary: 1 session, 1784647 data blocks, 3486m data,  290g free
Volume id    : 'Ubuntu 22.04 LTS amd64'
System area options: 0x00004201
System area summary: MBR protective-msdos-label grub2-mbr cyl-align-off GPT
ISO image size/512 : 7138588
Partition offset   : 16
MBR heads per cyl  : 0
MBR secs per head  : 0
MBR partition table:   N Status  Type        Start       Blocks
MBR partition      :   1   0x00  0xee            1      7138587
MBR partition      :   2   0x80  0x00            0            1
GPT                :   N  Info
GPT disk GUID      :      b8b29da0f6b5ae43afb391e0a90189a1
GPT entry array    :      2  248  separated
GPT lba range      :      64  7138524  7138587
GPT partition name :   1  490053004f003900360036003000
GPT partname local :   1  ISO9660
GPT partition GUID :   1  b8b29da0f6b5ae43afb291e0a90189a1
GPT type GUID      :   1  a2a0d0ebe5b9334487c068b6b72699c7
GPT partition flags:   1  0x1000000000000001
GPT start and size :   1  64  7129364
GPT partition name :   2  41007000700065006e006400650064003200
GPT partname local :   2  Appended2
GPT partition GUID :   2  b8b29da0f6b5ae43afb191e0a90189a1
GPT type GUID      :   2  28732ac11ff8d211ba4b00a0c93ec93b
GPT partition flags:   2  0x0000000000000000
GPT start and size :   2  7129428  8496
GPT partition name :   3  4700610070003100
GPT partname local :   3  Gap1
GPT partition GUID :   3  b8b29da0f6b5ae43afb091e0a90189a1
GPT type GUID      :   3  a2a0d0ebe5b9334487c068b6b72699c7
GPT partition flags:   3  0x1000000000000001
GPT start and size :   3  7137924  600
El Torito catalog  : 696  1
El Torito cat path : /boot.catalog
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00      4         697
El Torito boot img :   2  UEFI  y   none  0x0000  0x00   8496     1782357
El Torito img path :   1  /boot/grub/i386-pc/eltorito.img
El Torito img opts :   1  boot-info-table grub2-boot-info
El Torito img blks :   2  2124
-V 'Ubuntu 22.04 LTS amd64'
--modification-date='2022041910231900'
--grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:'/iso/ubuntu-22.04-desktop-amd64.iso'
--protective-msdos-label
-partition_cyl_align off
-partition_offset 16
--mbr-force-bootable
-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b --interval:local_fs:7129428d-7137923d::'/iso/ubuntu-22.04-desktop-amd64.iso'
-appended_part_as_gpt
-iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7
-c '/boot.catalog'
-b '/boot/grub/i386-pc/eltorito.img'
-no-emul-boot
-boot-load-size 4
-boot-info-table
--grub2-boot-info
-eltorito-alt-boot
-e '--interval:appended_partition_2_start_1782357s_size_8496d:all::'
-no-emul-boot
-boot-load-size 8
```

## 6.2) About the Arch 2024.01 image

We can see an hidden El Torito image for EFI:


```
$ xorriso -indev archlinux-2024.01.01-x86_64.iso -report_system_area plain -report_el_torito plain -report_el_torito as_mkisofs
xorriso 1.5.6 : RockRidge filesystem manipulator, libburnia project.

xorriso : NOTE : ISO image bears MBR with  -boot_image any partition_offset=16
xorriso : NOTE : Loading ISO image tree from LBA 0
xorriso : UPDATE :     112 nodes read in 1 seconds
libisofs: NOTE : Found hidden El-Torito image for EFI.
libisofs: NOTE : EFI image start and size: 444416 * 2048 , 30720 * 512
xorriso : NOTE : Detected El-Torito boot information which currently is set to be discarded
Drive current: -indev '/home/charlotte/Downloads/archlinux-2024.01.01-x86_64.iso'
Media current: stdio file, overwriteable
Media status : is written , is appendable
Boot record  : El Torito , MBR isohybrid cyl-align-all GPT
Media summary: 1 session, 452262 data blocks,  883m data,  288g free
Volume id    : 'ARCH_202401'
System area options: 0x00000302
System area summary: MBR isohybrid cyl-align-all GPT
ISO image size/512 : 1809048
Partition offset   : 16
MBR heads per cyl  : 64
MBR secs per head  : 32
MBR partition table:   N Status  Type        Start       Blocks
MBR partition      :   1   0x80  0x00           64      1777600
MBR partition      :   2   0x00  0xef      1777664        30720
GPT                :   N  Info
GPT disk GUID      :      3230323430313041b130303634343534
GPT entry array    :      2  248  separated
GPT lba range      :      64  1808984  1809047
GPT partition name :   1  490053004f00480079006200720069006400
GPT partname local :   1  ISOHybrid
GPT partition GUID :   1  3230323430313041b131303634343534
GPT type GUID      :   1  a2a0d0ebe5b9334487c068b6b72699c7
GPT partition flags:   1  0x1000000000000001
GPT start and size :   1  64  1777600
GPT partition name :   2  490053004f004800790062007200690064003100
GPT partname local :   2  ISOHybrid1
GPT partition GUID :   2  3230323430313041b132303634343534
GPT type GUID      :   2  a2a0d0ebe5b9334487c068b6b72699c7
GPT partition flags:   2  0x1000000000000001
GPT start and size :   2  1777664  30720
El Torito catalog  : 118  1
El Torito cat path : /boot/syslinux/boot.cat
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00      4         119
El Torito boot img :   2  UEFI  y   none  0x0000  0x00  30720      444416
El Torito img path :   1  /boot/syslinux/isolinux.bin
El Torito img opts :   1  boot-info-table isohybrid-suitable
El Torito img blks :   2  7680
-V 'ARCH_202401'
--modification-date='2024010116445400'
-isohybrid-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:'/home/charlotte/Downloads/archlinux-2024.01.01-x86_64.iso'
-partition_cyl_align all
-partition_offset 16
-partition_hd_cyl 64
-partition_sec_hd 32
--mbr-force-bootable
-append_partition 2 0xef --interval:local_fs:1777664d-1808383d::'/home/charlotte/Downloads/archlinux-2024.01.01-x86_64.iso'
-iso_mbr_part_type 0x00
-c '/boot/syslinux/boot.cat'
-b '/boot/syslinux/isolinux.bin'
-no-emul-boot
-boot-load-size 4
-boot-info-table
-eltorito-alt-boot
-e '--interval:appended_partition_2_start_444416s_size_30720d:all::'
-no-emul-boot
-boot-load-size 30720
-isohybrid-gpt-basdat
```
