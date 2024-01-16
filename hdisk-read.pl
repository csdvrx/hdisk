#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed
#
## Check block device name and optional block size given as an argument for:
# - MBR partitions (with potential ISO signatures)
# - GPT partitions (checks the CRC32, and that backups are correct)
# - *BUT* first check for headers, to correct the block size if forgotten

use strict;
use warnings;
use Data::Dumper;  # Dirty debug
use String::CRC32; # CRC32 calculations of the GPT headers and records

## Hardcoded
# The default block size that'll be guessed from EFI headers if wrong
my $hardcoded_default_block_size=512;
# GPT size
my $hardcoded_gpt_header_size=92;
# MBR sizes
my $hardcoded_mbr_bootcode_size=440;
my $hardcoded_mbr_signature_size=6;
my $hardcoded_mbr_bootsig=510;
my $hardcoded_mbr_bootsig_size=2;
my $hardcoded_mbr_size=64;

## Options
# Justify the assignments of the types in the hashes
my $justify=0;
# Only print the partitions, nothing about the MBR or GPT headers
my $noheaders=0;
# And don't talk about the device size
my $nodevinfo=0;
# Or look for ISO signatures (while you really should...)
my $noisodetect=0;
# Look very carefully for ISO signatures in MBR partitions declared as "empty":
my $debug_isodetect=0;

# https://wiki.osdev.org/El-Torito#Hybrid_Setup_for_BIOS_and_EFI_from_CD.2FDVD_and_USB_stick:
# Several distributions offer a layout that does not comply to either of the UEFI alternatives.
# The MBR marks the whole ISO by a partition of type 0x00.
# Another MBR partition of type 0xef marks a data file inside the ISO 
# with the image of the EFI System Partition FAT filesystem.
# Nevertheless there is a GPT which also marks the EFI System Partition image file.
# This GPT is to be ignored by any UEFI compliant firmware.
# The nesting is made acceptable by giving the outer MBR partition the type 0x00
# UEFI specifies to ignore MBR partitions 0x00"

## CHS decoding
sub hcs_to_chs {
 my $bin=shift;
 # c and h are 0-based, s is 1-based
 # for (h,c,s)=(1023, 255, 63) as bytes
 #     <FE>,   <FF>   ,<FF>
 # head    ,  sector  ,  cylinder
 # 11111110,  11111111,  11111111
 #            xx <- cut away the first 2 bytes
 #         ,  111111  ,xx11111111 <- add them to cylinder
 #cf https://thestarman.pcministry.com/asm/mbr/PartTables.htm
 my ($x1, $x2, $x3) = unpack("CCC", $bin);

 # byte 1: h bits 7,6,5,4,3,2,1,0
 # h value stored in the upper 6 bits of the first byte?
 #my $h = $c2 >> 2;
 my $h = $x1;

 # byte 2: c bits 9,8 then s bits 5,4,3,2,1
 # ie c value stored in the lower 10 bits of the last two bytes
 my $c = (($x2 & 0b11) << 8) | $x3;
 # s value stored in the lower 6 bits of the second byte
 my $s = $x2 & 0b00111111;
 return ($c, $h, $s);
}

## GPT attributes bits
# GPT partitions binary attributes
my @gpt_attributes;
#cf https://superuser.com/questions/1771316/
$gpt_attributes[0]="Platform required partition";
$gpt_attributes[1]="EFI please ignore this, no block IO protocol";
$gpt_attributes[2]="Legacy BIOS bootable";
#3-47 are reserved, cf https://en.wikipedia.org/wiki/GUID_Partition_Table?#Partition_entries_(LBA_2%E2%80%9333)
$gpt_attributes[56]="Chromebook boot succes";
$gpt_attributes[55]="Chromebook 16-bit attempt remain value bit 1";
$gpt_attributes[54]="Chromebook 16-bit attempt remain value bit 2";
$gpt_attributes[53]="Chromebook 16-bit attempt remain value bit 3";
$gpt_attributes[52]="Chromebook 16-bit attempt remain value bit 4";
$gpt_attributes[51]="Chromebook 16-bits priority value bit 1";
$gpt_attributes[50]="Chromebook 16-bits priority value bit 2";
$gpt_attributes[49]="Chromebook 16-bits priority value bit 3";
$gpt_attributes[48]="Chromebook 16-bits priority value bit 4";
#cf https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/gpt
$gpt_attributes[60]="Windows Read-only";
$gpt_attributes[61]="Windows Shadow copy";
$gpt_attributes[62]="Windows Hidden";
$gpt_attributes[63]="Windows No automount";
# In general, nick ef00: bit 0+1, nick 0700: bit 60+62+63
# on windows: nick 0c01: bit 0,   nick 2700: bit 0+62

## GPT GUID: recode
# The first field is 8 bytes long and is big-endian,
# the second and third fields are 2 and 4 bytes long and are big-endian,
# but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
sub guid_proper {
 my $input=shift;
 my ($guid1, $guid2, $guid3, $guid4, $guid5) = unpack "H8 H4 H4 H4 H12", $input;
 # reverse the endianness of the first 3 fields
 my $guid1_le=unpack ("V", pack ("H8", $guid1));
 my $guid2_le=unpack ("v", pack ("H4", $guid2));
 my $guid3_le=unpack ("v", pack ("H4", $guid3));
 my $output=sprintf ("%08x-%04x-%04x-%s-%s", $guid1_le, $guid2_le, $guid3_le, $guid4, $guid5);
 # use upper case for the returns
 return (uc($output));
}

# Make a few hashes:
#  - for description and conversion
my %guid_to_nick;
my %nick_to_guid;
# - for verbose description
my %guid_to_text;
my %nick_to_text;
# - in case the mbr and gpt description differs
my %nick_to_mbrtext;

# Ugly af but I wanted to reuse the existing definitions with minimal changes
sub add_type {
 my $nick = shift;
 my $guid = shift;
 my $text = shift;
 # optional:
 my $nick_wins= shift;
 my $mbr_text;
 if (defined ($nick_wins)) {
  # if defined:
  #  - specific text for describing mbr nick
  #  (otherwise collapsing to the same guid)
  #  - need to check which one wins as the default
  $mbr_text = shift;
 } else {
  # if not defined:
  #  - text applies both to gpt and mbr
  $mbr_text = $text;
 } # if defined nick wins

 # optional: if not defined, text=both gpt_text and mbr_text
 if (defined($nick_wins)) {
  if ($nick_wins >0 and defined($guid_to_nick{$guid})) {
   if ($justify >0) {
    print "1c. Redefining $guid from $guid_to_nick{$guid} to $nick due to $nick_wins\n";
   }
   $guid_to_nick{$guid}=$nick;
  } elsif (! defined($guid_to_nick{$guid})) {
   if ($justify >0) {
    print "1b. Defining $guid to $nick given $nick_wins\n";
   }
   $guid_to_nick{$guid}=$nick;
  } else {
   if ($justify >0) {
    print "1d. Not overwriting $guid_to_nick{$guid} to $nick for $guid given $nick_wins\n";
   }
  }# elsif
  if ($nick_wins >0 and defined($guid_to_text{$guid})) {
   if ($justify >0) {
    print "2c. Redefining $guid from $guid_to_text{$guid} to $text due to $nick_wins\n";
   }
   $guid_to_text{$guid}=$text;
  } elsif (! defined($guid_to_text{$guid})) {
   if ($justify >0) {
    print "2b. Defining $guid to $text given $nick_wins\n";
   }
   $guid_to_text{$guid}=$text;
  } else {
   if ($justify >0) {
    print "2d. Not overwriting $guid_to_nick{$guid} to $nick for $nick given $nick_wins\n";
   }
  }# elsif
 } else {
  if (! defined($guid_to_nick{$guid})) {
   if ($justify >0) {
    print "1. Defining $guid to $nick \n";
   }
   $guid_to_nick{$guid}=$nick;
  } else {
   if ($justify >0) {
    print "1a. Refusing to overwrite $guid_to_nick{$guid} by $nick for $guid\n";
   }
  }
  if (! defined($guid_to_text{$guid})) {
   if ($justify >0) {
    print "2. Defining guid $guid to text $text\n";
   }
   $guid_to_text{$guid}=$text;
  } else {
   if ($justify >0) {
    print "2a. Refusing to overwrite $guid_to_text{$guid} by $text for $guid\n";
   }
  }
  if (! defined($nick_to_guid{$nick})) {
   if ($justify >0) {
    print "3. Defining $nick to $guid\n";
   }
   $nick_to_guid{$nick}=$guid;
  } else {
   if ($justify >0) {
    print "3a. Refusing to overwrite $nick_to_guid{$nick} by $guid for $nick\n";
   }
  }
  if (! defined($nick_to_text{$nick})) {
   if ($justify >0) {
    print "4. Defining $nick to $text\n";
   }
   $nick_to_text{$nick}=$text;
  } else {
   if ($justify >0) {
    print "4a. Refusing to overwrite $nick_to_text{$nick} by $text for $nick\n";
   }
  }
 }
 $nick_to_mbrtext{$nick}=$mbr_text;
}

# Exhaustive table of facts matching more or less gptdisk format by Rod Smith:
# The nick type is the MBR type *100, which is shorter to type that a GUID
# there are not so many well-known GUID, so nicks are easier to show
#cf https://www.rodsbooks.com/gdisk/download.html
#  Nick type, GUID, GPT description, bool if should be shown for creation, MBR description.
# Changed the definition of the bool ot winning in case of non bijective {GUID-nick} relation
# Use for:
# - MBR to GPT conversion: read the first 2 characters of the nick type, write the GUID
# - GPT to MBR conversion: read the GUID, write the first 2 characters of the nick type
# - partition description: depending on GPT or MBR, read the correct description
# - partition creation: read the nick type 4 characters, write the first 2 or the GUID depending on GPT or MBR creation
add_type("0000", "00000000-0000-0000-0000-000000000000", "Unused entry", 1, "Empty or unused (but also seen in hybrids)");

# DOS/Windows partition types
add_type("0100", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"FAT-12");
add_type("0400", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"FAT-16 < 32M");
add_type("0600", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"FAT-16");
add_type("0700", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 1,"NTFS or HPFS");
add_type("0701", "558D43C5-A1AC-43C0-AAC8-D1472B2923D1", "Microsoft Storage Replica", 1);
add_type("0702", "90B6FF38-B98F-4358-A21F-48F35B4A8AD3", "ArcaOS Type 1", 1);
add_type("0b00", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"FAT-32");
add_type("0c00", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"FAT-32 LBA");
add_type("0c01", "E3C9E316-0B5C-4DB8-817D-F92DF00215AE", "Microsoft reserved");
add_type("0e00", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"FAT-16 LBA");
add_type("1100", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden FAT-12");
add_type("1400", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden FAT-16 < 32M");
add_type("1600", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden FAT-16");
add_type("1700", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden NTFS or HPFS");
add_type("1b00", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden FAT-32");
add_type("1c00", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden FAT-32 LBA");
add_type("1e00", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "Microsoft basic data", 0,"Hidden FAT-16 LBA");
# WARNING: previously listed 2700 nick wrong with C9A8D5-F78A-48B2-B2AA-B389EB160717
add_type("2700", "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC", "Windows RE");

# Open Network Install Environment (ONIE) specific types.
# See http:#www.onie.org/ and
# https:#github.com/opencomputeproject/onie/blob/master/patches/gptfdisk/add-onie-partition-types.patch
add_type("3000", "7412F7D5-A156-4B13-81DC-867174929325", "ONIE boot");
add_type("3001", "D4E6E2CD-4469-46F3-B5CB-1BFF57AFC149", "ONIE config");

# Plan 9; see http:#man.cat-v.org/9front/8/prep
add_type("3900", "C91818F9-8025-47AF-89D2-F030D7000C2C", "Plan 9");

# PowerPC reference platform boot partition
add_type("4100", "9E1A2D38-C612-4316-AA26-8B49521E5A8B", "PowerPC PReP boot");

# Windows LDM ("dynamic disk") types
add_type("4200", "AF9B60A0-1431-4F62-BC68-3311714A69AD", "Windows LDM data", 2, "Logical disk manager");
add_type("4201", "5808C8AA-7E8F-42E0-85D2-E1E90434CFB3", "Windows LDM metadata", 2, "Logical disk manager");
add_type("4202", "E75CAF8F-F680-4CEE-AFA3-B001E56EFC2D", "Windows Storage Spaces", 2, "A newer LDM-type setup");

# An oddball IBM filesystem....
add_type("7501", "37AFFC90-EF7D-4E96-91C3-2D7AE055B174", "IBM GPFS", 2, "General Parallel File System (GPFS)");

# ChromeOS-specific partition types...
# Values taken from vboot_reference/firmware/lib/cgptlib/include/gpt.h in
# ChromeOS source code, retrieved 12/23/2010. They're also at
# http:#www.chromium.org/chromium-os/chromiumos-design-docs/disk-format.
# These have no MBR equivalents, AFAIK, so I'm using 0x7Fxx values, since they're close
# to the Linux values.
add_type("7f00", "FE3A2A5D-4F32-41A7-B725-ACCC3285A309", "ChromeOS kernel");
add_type("7f01", "3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC", "ChromeOS root");
add_type("7f02", "2E0A753D-9E48-43B0-8337-B15192CB1B5E", "ChromeOS reserved");
add_type("7f03", "CAB6E88E-ABF3-4102-A07A-D4BB9BE3C1D3", "ChromeOS firmware");
add_type("7f04", "09845860-705F-4BB5-B16C-8A8A099CAF52", "ChromeOS mini-OS");
add_type("7f05", "3F0F8318-F146-4E6B-8222-C28C8F02E0D5", "ChromeOS hibernate");

# Linux-specific partition types....
add_type("8200", "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F", "Linux swap", 2, "Linux swap (or Solaris on MBR)");
add_type("8300", "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "Linux filesystem", 2, "Linux native");
add_type("8301", "8DA63339-0007-60C0-C436-083AC8230908", "Linux reserved");
# See https:#www.freedesktop.org/software/systemd/man/systemd-gpt-auto-generator.html
# and https:#systemd.io/DISCOVERABLE_PARTITIONS
add_type("8302", "933AC7E1-2EB4-4F13-B844-0E14E2AEF915", "Linux /home", 2, "Linux /home (auto-mounted by systemd)");
add_type("8303", "44479540-F297-41B2-9AF7-D131D5F0458A", "Linux x86 root (/)", 2, "Linux / on x86 (auto-mounted by systemd)");
add_type("8304", "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709", "Linux x86-64 root (/)", 2, "Linux / on x86-64 (auto-mounted by systemd)");
add_type("8305", "B921B045-1DF0-41C3-AF44-4C6F280D3FAE", "Linux ARM64 root (/)", 2, "Linux / on 64-bit ARM (auto-mounted by systemd)");
add_type("8306", "3B8F8425-20E0-4F3B-907F-1A25A76F98E8", "Linux /srv", 2, "Linux /srv (auto-mounted by systemd)");
add_type("8307", "69DAD710-2CE4-4E3C-B16C-21A1D49ABED3", "Linux ARM32 root (/)", 2, "Linux / on 32-bit ARM (auto-mounted by systemd)");
add_type("8308", "7FFEC5C9-2D00-49B7-8941-3EA10A5586B7", "Linux dm-crypt");
add_type("8309", "CA7D7CCB-63ED-4C53-861C-1742536059CC", "Linux LUKS");
add_type("830A", "993D8D3D-F80E-4225-855A-9DAF8ED7EA97", "Linux IA-64 root (/)", 2, "Linux / on Itanium (auto-mounted by systemd)");
add_type("830B", "D13C5D3B-B5D1-422A-B29F-9454FDC89D76", "Linux x86 root verity");
add_type("830C", "2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5", "Linux x86-64 root verity");
add_type("830D", "7386CDF2-203C-47A9-A498-F2ECCE45A2D6", "Linux ARM32 root verity");
add_type("830E", "DF3300CE-D69F-4C92-978C-9BFB0F38D820", "Linux ARM64 root verity");
add_type("830F", "86ED10D5-B607-45BB-8957-D350F23D0571", "Linux IA-64 root verity");
add_type("8310", "4D21B016-B534-45C2-A9FB-5C16E091FD2D", "Linux /var", 2, "Linux /var (auto-mounted by systemd)");
add_type("8311", "7EC6F557-3BC5-4ACA-B293-16EF5DF639D1", "Linux /var/tmp", 2, "Linux /var/tmp (auto-mounted by systemd)");
# https:#systemd.io/HOME_DIRECTORY/
add_type("8312", "773F91EF-66D4-49B5-BD83-D683BF40AD16", "Linux user's home", 2, "used by systemd-homed");
add_type("8313", "75250D76-8CC6-458E-BD66-BD47CC81A812", "Linux x86 /usr ", 2, "Linux /usr on x86 (auto-mounted by systemd)");
add_type("8314", "8484680C-9521-48C6-9C11-B0720656F69E", "Linux x86-64 /usr", 2, "Linux /usr on x86-64 (auto-mounted by systemd)");
add_type("8315", "7D0359A3-02B3-4F0A-865C-654403E70625", "Linux ARM32 /usr", 2, "Linux /usr on 32-bit ARM (auto-mounted by systemd)");
add_type("8316", "B0E01050-EE5F-4390-949A-9101B17104E9", "Linux ARM64 /usr", 2, "Linux /usr on 64-bit ARM (auto-mounted by systemd)");
add_type("8317", "4301D2A6-4E3B-4B2A-BB94-9E0B2C4225EA", "Linux IA-64 /usr", 2, "Linux /usr on Itanium (auto-mounted by systemd)");
add_type("8318", "8F461B0D-14EE-4E81-9AA9-049B6FB97ABD", "Linux x86 /usr verity");
add_type("8319", "77FF5F63-E7B6-4633-ACF4-1565B864C0E6", "Linux x86-64 /usr verity");
add_type("831A", "C215D751-7BCD-4649-BE90-6627490A4C05", "Linux ARM32 /usr verity");
add_type("831B", "6E11A4E7-FBCA-4DED-B9E9-E1A512BB664E", "Linux ARM64 /usr verity");
add_type("831C", "6A491E03-3BE7-4545-8E38-83320E0EA880", "Linux IA-64 /usr verity");

# Used by Intel Rapid Start technology
add_type("8400", "D3BFE2DE-3DAF-11DF-BA40-E3A556D89593", "Intel Rapid Start");
# This is another Intel-associated technology, so I'm keeping it close to the previous one....
add_type("8401", "7C5222BD-8F5D-4087-9C00-BF9843C7B58C", "SPDK block device");

# Type codes for Container Linux (formerly CoreOS; https:#coreos.com)
add_type("8500", "5DFBF5F4-2848-4BAC-AA5E-0D9A20B745A6", "Container Linux /usr");
add_type("8501", "3884DD41-8582-4404-B9A8-E9B84F2DF50E", "Container Linux resizable rootfs");
add_type("8502", "C95DC21A-DF0E-4340-8D7B-26CBFA9A03E0", "Container Linux /OEM customizations");
add_type("8503", "BE9067B9-EA49-4F15-B4F6-F36F8C9E1818", "Container Linux root on RAID");

# Another Linux type code....
add_type("8e00", "E6D6D379-F507-44C2-A23C-238F2A3DF928", "Linux LVM");

# Android type codes....
# from Wikipedia, https:#gist.github.com/culots/704afd126dec2f45c22d0c9d42cb7fab,
# and my own Android devices' partition tables
add_type("a000", "2568845D-2332-4675-BC39-8FA5A4748D15", "Android bootloader");
add_type("a001", "114EAFFE-1552-4022-B26E-9B053604CF84", "Android bootloader 2");
add_type("a002", "49A4D17F-93A3-45C1-A0DE-F50B2EBE2599", "Android boot 1");
add_type("a003", "4177C722-9E92-4AAB-8644-43502BFD5506", "Android recovery 1");
add_type("a004", "EF32A33B-A409-486C-9141-9FFB711F6266", "Android misc");
add_type("a005", "20AC26BE-20B7-11E3-84C5-6CFDB94711E9", "Android metadata");
add_type("a006", "38F428E6-D326-425D-9140-6E0EA133647C", "Android system 1");
add_type("a007", "A893EF21-E428-470A-9E55-0668FD91A2D9", "Android cache");
add_type("a008", "DC76DDA9-5AC1-491C-AF42-A82591580C0D", "Android data");
add_type("a009", "EBC597D0-2053-4B15-8B64-E0AAC75F4DB1", "Android persistent");
add_type("a00a", "8F68CC74-C5E5-48DA-BE91-A0C8C15E9C80", "Android factory");
add_type("a00b", "767941D0-2085-11E3-AD3B-6CFDB94711E9", "Android fastboot/tertiary");
add_type("a00c", "AC6D7924-EB71-4DF8-B48D-E267B27148FF", "Android OEM");
add_type("a00d", "C5A0AEEC-13EA-11E5-A1B1-001E67CA0C3C", "Android vendor");
add_type("a00e", "BD59408B-4514-490D-BF12-9878D963F378", "Android config");
add_type("a00f", "9FDAA6EF-4B3F-40D2-BA8D-BFF16BFB887B", "Android factory (alt)");
add_type("a010", "19A710A2-B3CA-11E4-B026-10604B889DCF", "Android meta");
add_type("a011", "193D1EA4-B3CA-11E4-B075-10604B889DCF", "Android EXT");
add_type("a012", "DEA0BA2C-CBDD-4805-B4F9-F428251C3E98", "Android SBL1");
add_type("a013", "8C6B52AD-8A9E-4398-AD09-AE916E53AE2D", "Android SBL2");
add_type("a014", "05E044DF-92F1-4325-B69E-374A82E97D6E", "Android SBL3");
add_type("a015", "400FFDCD-22E0-47E7-9A23-F16ED9382388", "Android APPSBL");
add_type("a016", "A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4", "Android QSEE/tz");
add_type("a017", "E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A", "Android QHEE/hyp");
add_type("a018", "098DF793-D712-413D-9D4E-89D711772228", "Android RPM");
add_type("a019", "D4E0D938-B7FA-48C1-9D21-BC5ED5C4B203", "Android WDOG debug/sdi");
add_type("a01a", "20A0C19C-286A-42FA-9CE7-F64C3226A794", "Android DDR");
add_type("a01b", "A19F205F-CCD8-4B6D-8F1E-2D9BC24CFFB1", "Android CDT");
add_type("a01c", "66C9B323-F7FC-48B6-BF96-6F32E335A428", "Android RAM dump");
add_type("a01d", "303E6AC3-AF15-4C54-9E9B-D9A8FBECF401", "Android SEC");
add_type("a01e", "C00EEF24-7709-43D6-9799-DD2B411E7A3C", "Android PMIC");
add_type("a01f", "82ACC91F-357C-4A68-9C8F-689E1B1A23A1", "Android misc 1");
add_type("a020", "E2802D54-0545-E8A1-A1E8-C7A3E245ACD4", "Android misc 2");
add_type("a021", "65ADDCF4-0C5C-4D9A-AC2D-D90B5CBFCD03", "Android device info");
add_type("a022", "E6E98DA2-E22A-4D12-AB33-169E7DEAA507", "Android APDP");
add_type("a023", "ED9E8101-05FA-46B7-82AA-8D58770D200B", "Android MSADP");
add_type("a024", "11406F35-1173-4869-807B-27DF71802812", "Android DPO");
add_type("a025", "9D72D4E4-9958-42DA-AC26-BEA7A90B0434", "Android recovery 2");
add_type("a026", "6C95E238-E343-4BA8-B489-8681ED22AD0B", "Android persist");
add_type("a027", "EBBEADAF-22C9-E33B-8F5D-0E81686A68CB", "Android modem ST1");
add_type("a028", "0A288B1F-22C9-E33B-8F5D-0E81686A68CB", "Android modem ST2");
add_type("a029", "57B90A16-22C9-E33B-8F5D-0E81686A68CB", "Android FSC");
add_type("a02a", "638FF8E2-22C9-E33B-8F5D-0E81686A68CB", "Android FSG 1");
add_type("a02b", "2013373E-1AC4-4131-BFD8-B6A7AC638772", "Android FSG 2");
add_type("a02c", "2C86E742-745E-4FDD-BFD8-B6A7AC638772", "Android SSD");
add_type("a02d", "DE7D4029-0F5B-41C8-AE7E-F6C023A02B33", "Android keystore");
add_type("a02e", "323EF595-AF7A-4AFA-8060-97BE72841BB9", "Android encrypt");
add_type("a02f", "45864011-CF89-46E6-A445-85262E065604", "Android EKSST");
add_type("a030", "8ED8AE95-597F-4C8A-A5BD-A7FF8E4DFAA9", "Android RCT");
add_type("a031", "DF24E5ED-8C96-4B86-B00B-79667DC6DE11", "Android spare1");
add_type("a032", "7C29D3AD-78B9-452E-9DEB-D098D542F092", "Android spare2");
add_type("a033", "379D107E-229E-499D-AD4F-61F5BCF87BD4", "Android spare3");
add_type("a034", "0DEA65E5-A676-4CDF-823C-77568B577ED5", "Android spare4");
add_type("a035", "4627AE27-CFEF-48A1-88FE-99C3509ADE26", "Android raw resources");
add_type("a036", "20117F86-E985-4357-B9EE-374BC1D8487D", "Android boot 2");
add_type("a037", "86A7CB80-84E1-408C-99AB-694F1A410FC7", "Android FOTA");
add_type("a038", "97D7B011-54DA-4835-B3C4-917AD6E73D74", "Android system 2");
add_type("a039", "5594C694-C871-4B5F-90B1-690A6F68E0F7", "Android cache");
add_type("a03a", "1B81E7E6-F50D-419B-A739-2AEEF8DA3335", "Android user data");
add_type("a03b", "98523EC6-90FE-4C67-B50A-0FC59ED6F56D", "LG (Android) advanced flasher");
add_type("a03c", "2644BCC0-F36A-4792-9533-1738BED53EE3", "Android PG1FS");
add_type("a03d", "DD7C91E9-38C9-45C5-8A12-4A80F7E14057", "Android PG2FS");
add_type("a03e", "7696D5B6-43FD-4664-A228-C563C4A1E8CC", "Android board info");
add_type("a03f", "0D802D54-058D-4A20-AD2D-C7A362CEACD4", "Android MFG");
add_type("a040", "10A0C19C-516A-5444-5CE3-664C3226A794", "Android limits");

# Atari TOS partition type
add_type("a200", "734E5AFE-F61A-11E6-BC64-92361F002671", "Atari TOS basic data");

# FreeBSD partition types....
# Note: Rather than extract FreeBSD disklabel data, convert FreeBSD
# partitions in-place, and let FreeBSD sort out the details....
add_type("a500", "516E7CB4-6ECF-11D6-8FF8-00022D09712B", "FreeBSD disklabel");
add_type("a501", "83BD6B9D-7F41-11DC-BE0B-001560B84F0F", "FreeBSD boot");
add_type("a502", "516E7CB5-6ECF-11D6-8FF8-00022D09712B", "FreeBSD swap");
add_type("a503", "516E7CB6-6ECF-11D6-8FF8-00022D09712B", "FreeBSD UFS");
add_type("a504", "516E7CBA-6ECF-11D6-8FF8-00022D09712B", "FreeBSD ZFS");
add_type("a505", "516E7CB8-6ECF-11D6-8FF8-00022D09712B", "FreeBSD Vinum/RAID");
add_type("a506", "74BA7DD9-A689-11E1-BD04-00E081286ACF", "FreeBSD nandfs");

# Midnight BSD partition types....
add_type("a580", "85D5E45A-237C-11E1-B4B3-E89A8F7FC3A7", "Midnight BSD data");
add_type("a581", "85D5E45E-237C-11E1-B4B3-E89A8F7FC3A7", "Midnight BSD boot");
add_type("a582", "85D5E45B-237C-11E1-B4B3-E89A8F7FC3A7", "Midnight BSD swap");
add_type("a583", "0394Ef8B-237E-11E1-B4B3-E89A8F7FC3A7", "Midnight BSD UFS");
add_type("a584", "85D5E45D-237C-11E1-B4B3-E89A8F7FC3A7", "Midnight BSD ZFS");
add_type("a585", "85D5E45C-237C-11E1-B4B3-E89A8F7FC3A7", "Midnight BSD Vinum");

# OpenBSD partition type....
add_type("a600", "824CC7A0-36A8-11E3-890A-952519AD3F61", "OpenBSD disklabel");

# A MacOS partition type, separated from others by NetBSD partition types...
add_type("a800", "55465300-0000-11AA-AA11-00306543ECAC", "Apple UFS", 2, "Mac OS X");

# NetBSD partition types. Note that the main entry sets it up as a
# FreeBSD disklabel. I'm not 100% certain this is the correct behavior.
add_type("a900", "516E7CB4-6ECF-11D6-8FF8-00022D09712B", "FreeBSD disklabel", 0,"NetBSD disklabel");
add_type("a901", "49F48D32-B10E-11DC-B99B-0019D1879648", "NetBSD swap");
add_type("a902", "49F48D5A-B10E-11DC-B99B-0019D1879648", "NetBSD FFS");
add_type("a903", "49F48D82-B10E-11DC-B99B-0019D1879648", "NetBSD LFS");
add_type("a904", "2DB519C4-B10F-11DC-B99B-0019D1879648", "NetBSD concatenated");
add_type("a905", "2DB519EC-B10F-11DC-B99B-0019D1879648", "NetBSD encrypted");
add_type("a906", "49F48DAA-B10E-11DC-B99B-0019D1879648", "NetBSD RAID");

# Mac OS partition types (See also 0xa800, above)....
add_type("ab00", "426F6F74-0000-11AA-AA11-00306543ECAC", "Recovery HD");
add_type("af00", "48465300-0000-11AA-AA11-00306543ECAC", "Apple HFS/HFS+");
add_type("af01", "52414944-0000-11AA-AA11-00306543ECAC", "Apple RAID");
add_type("af02", "52414944-5F4F-11AA-AA11-00306543ECAC", "Apple RAID offline");
add_type("af03", "4C616265-6C00-11AA-AA11-00306543ECAC", "Apple label");
add_type("af04", "5265636F-7665-11AA-AA11-00306543ECAC", "AppleTV recovery");
add_type("af05", "53746F72-6167-11AA-AA11-00306543ECAC", "Apple Core Storage");
add_type("af06", "B6FA30DA-92D2-4A9A-96F1-871EC6486200", "Apple SoftRAID Status");
add_type("af07", "2E313465-19B9-463F-8126-8A7993773801", "Apple SoftRAID Scratch");
add_type("af08", "FA709C7E-65B1-4593-BFD5-E71D61DE9B02", "Apple SoftRAID Volume");
add_type("af09", "BBBA6DF5-F46F-4A89-8F59-8765B2727503", "Apple SoftRAID Cache");
add_type("af0a", "7C3457EF-0000-11AA-AA11-00306543ECAC", "Apple APFS");
add_type("af0b", "69646961-6700-11AA-AA11-00306543ECAC", "Apple APFS Pre-Boot");
add_type("af0c", "52637672-7900-11AA-AA11-00306543ECAC", "Apple APFS Recovery");

# U-Boot boot loader
#cf https:#lists.denx.de/pipermail/u-boot/2020-November/432928.html
#cf https:#source.denx.de/u-boot/u-boot/-/blob/v2021.07/include/part_efi.h#L59-61
add_type("b000", "3DE21764-95BD-54BD-A5C3-4ABE786F38A8", "U-Boot boot loader");

# QNX Power-Safe (QNX6)
add_type("b300", "CEF5A9AD-73BC-4601-89F3-CDEEEEE321A1", "QNX6 Power-Safe");

# Barebox boot loader
#cf https:#barebox.org/doc/latest/user/state.html?highlight=guid#sd-emmc-and-ata
add_type("bb00", "4778ED65-BF42-45FA-9C5B-287A1DC4AAB1", "Barebox boot loader");

# Acronis Secure Zone
add_type("bc00", "0311FC50-01CA-4725-AD77-9ADBB20ACE98", "Acronis Secure Zone");

# Solaris partition types (one of which is shared with MacOS)
add_type("be00", "6A82CB45-1DD2-11B2-99A6-080020736631", "Solaris boot");
add_type("bf00", "6A85CF4D-1DD2-11B2-99A6-080020736631", "Solaris root");
add_type("bf01", "6A898CC3-1DD2-11B2-99A6-080020736631", "Solaris /usr & Mac ZFS", 2, "Solaris/MacOS");
add_type("bf02", "6A87C46F-1DD2-11B2-99A6-080020736631", "Solaris swap");
add_type("bf03", "6A8B642B-1DD2-11B2-99A6-080020736631", "Solaris backup");
add_type("bf04", "6A8EF2E9-1DD2-11B2-99A6-080020736631", "Solaris /var");
add_type("bf05", "6A90BA39-1DD2-11B2-99A6-080020736631", "Solaris /home");
add_type("bf06", "6A9283A5-1DD2-11B2-99A6-080020736631", "Solaris alternate sector");
add_type("bf07", "6A945A3B-1DD2-11B2-99A6-080020736631", "Solaris Reserved 1");
add_type("bf08", "6A9630D1-1DD2-11B2-99A6-080020736631", "Solaris Reserved 2");
add_type("bf09", "6A980767-1DD2-11B2-99A6-080020736631", "Solaris Reserved 3");
add_type("bf0a", "6A96237F-1DD2-11B2-99A6-080020736631", "Solaris Reserved 4");
add_type("bf0b", "6A8D2AC7-1DD2-11B2-99A6-080020736631", "Solaris Reserved 5");

# No MBR equivalents, but on Wikipedia page for GPT, so here we go....
add_type("c001", "75894C1E-3AEB-11D3-B7C1-7B03A0000000", "HP-UX data");
add_type("c002", "E2A1E728-32E3-11D6-A682-7B03A0000000", "HP-UX service");

# Open Network Install Environment (ONIE) partitions....
add_type("e100", "7412F7D5-A156-4B13-81DC-867174929325", "ONIE boot");
add_type("e101", "D4E6E2CD-4469-46F3-B5CB-1BFF57AFC149", "ONIE config");

# Veracrypt (https:#www.veracrypt.fr/en/Home.html) encrypted partition
add_type("e900", "8C8F8EFF-AC95-4770-814A-21994F2DBC8F", "Veracrypt data");

# Systemd cf https:#systemd.io/BOOT_LOADER_SPECIFICATION/
add_type("ea00", "BC13C2FF-59E6-4262-A352-B275FD6F7172", "XBOOTLDR partition");

# Type code for Haiku; uses BeOS MBR code as hex code base
add_type("eb00", "42465331-3BA3-10F1-802A-4861696B7521", "Haiku BFS");

# Manufacturer-specific ESP-like partitions (in order in which they were added)
add_type("ed00", "F4019732-066E-4E12-8273-346C5641494F", "Sony system partition");
add_type("ed01", "BFBFAFE7-A34F-448A-9A5B-6213EB736C22", "Lenovo system partition");

# EFI protective partition
add_type("ee00", "", "If this is displayed there is an error", 2, "MBR protective partition");
# EFI system and related partitions
add_type("ef00", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI system partition"); # 2, "Parted says the 'boot flag' is set"
add_type("ef01", "024DEE41-33E7-11D3-9D69-0008C781F39F", "MBR partition scheme"); # Used to nest MBR in GPT officially
add_type("ef02", "21686148-6449-6E6F-744E-656564454649", "BIOS boot partition (used by grub)"); # Used by GRUB

# Fuchsia OS codes
# cf https:#cs.opensource.google/fuchsia/fuchsia/+/main:zircon/system/public/zircon/hw/gpt.h
add_type("f100", "FE8A2634-5E2E-46BA-99E3-3A192091A350", "Fuchsia boot loader (slot A/B/R)");
add_type("f101", "D9FD4535-106C-4CEC-8D37-DFC020CA87CB", "Fuchsia durable mutable encrypted system data");
add_type("f102", "A409E16B-78AA-4ACC-995C-302352621A41", "Fuchsia durable mutable boot loader");
add_type("f103", "F95D940E-CABA-4578-9B93-BB6C90F29D3E", "Fuchsia factory ro system data");
add_type("f104", "10B8DBAA-D2BF-42A9-98C6-A7C5DB3701E7", "Fuchsia factory ro bootloader data");
add_type("f105", "49FD7CB8-DF15-4E73-B9D9-992070127F0F", "Fuchsia Volume Manager");
add_type("f106", "421A8BFC-85D9-4D85-ACDA-B64EEC0133E9", "Fuchsia verified boot metadata (slot A/B/R)");
add_type("f107", "9B37FFF6-2E58-466A-983A-F7926D0B04E0", "Fuchsia Zircon boot image (slot A/B/R)");
add_type("f108", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "Fuchsia ESP");
add_type("f109", "606B000B-B7C7-4653-A7D5-B737332C899D", "Fuchsia System");
add_type("f10a", "08185F0C-892D-428A-A789-DBEEC8F55E6A", "Fuchsia Data");
add_type("f10b", "48435546-4953-2041-494E-5354414C4C52", "Fuchsia Install");
add_type("f10c", "2967380E-134C-4CBB-B6DA-17E7CE1CA45D", "Fuchsia Blob");
add_type("f10d", "41D0E340-57E3-954E-8C1E-17ECAC44CFF5", "Fuchsia FVM");
add_type("f10e", "DE30CC86-1F4A-4A31-93C4-66F147D33E05", "Fuchsia Zircon boot image (slot A)");
add_type("f10f", "23CC04DF-C278-4CE7-8471-897D1A4BCDF7", "Fuchsia Zircon boot image (slot B)");
add_type("f110", "A0E5CF57-2DEF-46BE-A80C-A2067C37CD49", "Fuchsia Zircon boot image (slot R)");
add_type("f111", "4E5E989E-4C86-11E8-A15B-480FCF35F8E6", "Fuchsia sys-config");
add_type("f112", "5A3A90BE-4C86-11E8-A15B-480FCF35F8E6", "Fuchsia factory-config");
add_type("f113", "5ECE94FE-4C86-11E8-A15B-480FCF35F8E6", "Fuchsia bootloader");
add_type("f114", "8B94D043-30BE-4871-9DFA-D69556E8C1F3", "Fuchsia guid-test");
add_type("f115", "A13B4D9A-EC5F-11E8-97D8-6C3BE52705BF", "Fuchsia verified boot metadata (A)");
add_type("f116", "A288ABF2-EC5F-11E8-97D8-6C3BE52705BF", "Fuchsia verified boot metadata (B)");
add_type("f117", "6A2460C3-CD11-4E8B-80A8-12CCE268ED0A", "Fuchsia verified boot metadata (R)");
add_type("f118", "1D75395D-F2C6-476B-A8B7-45CC1C97B476", "Fuchsia misc");
add_type("f119", "900B0FC5-90CD-4D4F-84F9-9F8ED579DB88", "Fuchsia emmc-boot1");
add_type("f11a", "B2B2E8D1-7C10-4EBC-A2D0-4614568260AD", "Fuchsia emmc-boot2");

# Ceph type codes
# cf https:#github.com/ceph/ceph/blob/9bcc42a3e6b08521694b5c0228b2c6ed7b3d312e/src/ceph-disk#L76-L81
add_type("f800", "4FBD7E29-9D25-41B8-AFD0-062C0CEFF05D", "Ceph OSD", 2, "Ceph Object Storage Daemon");
add_type("f801", "4FBD7E29-9D25-41B8-AFD0-5EC00CEFF05D", "Ceph dm-crypt OSD", 2, "Ceph Object Storage Daemon (encrypted)");
add_type("f802", "45B0969E-9B03-4F30-B4C6-B4B80CEFF106", "Ceph journal");
add_type("f803", "45B0969E-9B03-4F30-B4C6-5EC00CEFF106", "Ceph dm-crypt journal");
add_type("f804", "89C57F98-2FE5-4DC0-89C1-F3AD0CEFF2BE", "Ceph disk in creation");
add_type("f805", "89C57F98-2FE5-4DC0-89C1-5EC00CEFF2BE", "Ceph dm-crypt disk in creation");
add_type("f806", "CAFECAFE-9B03-4F30-B4C6-B4B80CEFF106", "Ceph block");
add_type("f807", "30CD0809-C2B2-499C-8879-2D6B78529876", "Ceph block DB");
add_type("f808", "5CE17FCE-4087-4169-B7FF-056CC58473F9", "Ceph block write-ahead log");
add_type("f809", "FB3AABF9-D25F-47CC-BF5E-721D1816496B", "Ceph lockbox for dm-crypt keys");
add_type("f80a", "4FBD7E29-8AE0-4982-BF9D-5A8D867AF560", "Ceph multipath OSD");
add_type("f80b", "45B0969E-8AE0-4982-BF9D-5A8D867AF560", "Ceph multipath journal");
add_type("f80c", "CAFECAFE-8AE0-4982-BF9D-5A8D867AF560", "Ceph multipath block 1");
add_type("f80d", "7F4A666A-16F3-47A2-8445-152EF4D03F6C", "Ceph multipath block 2");
add_type("f80e", "EC6D6385-E346-45DC-BE91-DA2A7C8B3261", "Ceph multipath block DB");
add_type("f80f", "01B41E1B-002A-453C-9F17-88793989FF8F", "Ceph multipath block write-ahead log");
add_type("f810", "CAFECAFE-9B03-4F30-B4C6-5EC00CEFF106", "Ceph dm-crypt block");
add_type("f811", "93B0052D-02D9-4D8A-A43B-33A3EE4DFBC3", "Ceph dm-crypt block DB");
add_type("f812", "306E8683-4FE2-4330-B7C0-00A917C16966", "Ceph dm-crypt block write-ahead log");
add_type("f813", "45B0969E-9B03-4F30-B4C6-35865CEFF106", "Ceph dm-crypt LUKS journal");
add_type("f814", "CAFECAFE-9B03-4F30-B4C6-35865CEFF106", "Ceph dm-crypt LUKS block");
add_type("f815", "166418DA-C469-4022-ADF4-B30AFD37F176", "Ceph dm-crypt LUKS block DB");
add_type("f816", "86A32090-3647-40B9-BBBD-38D8C573AA86", "Ceph dm-crypt LUKS block write-ahead log");
add_type("f817", "4FBD7E29-9D25-41B8-AFD0-35865CEFF05D", "Ceph dm-crypt LUKS OSD");

# VMWare ESX partition types codes
add_type("fb00", "AA31E02A-400F-11DB-9590-000C2911D1B8", "VMWare VMFS");
add_type("fb01", "9198EFFC-31C0-11DB-8F78-000C2911D1B8", "VMWare reserved");
add_type("fc00", "9D275380-40AD-11DB-BF97-000C2911D1B8", "VMWare kcore crash protection");

# A straggler Linux partition type....
add_type("fd00", "A19D880F-05FC-4D3B-A006-743F0F84911E", "Linux RAID");

## Tests

# Simple assertion to be able to detect LBA / non LBA
# LBA is indicated by setting the max values ie 1023, 254, 63:
# stands for the 1024th cylinder, 255th head and 63rd sector
# because cylinder and head counts begin at zero.
# on disk as three bytes: FE FF FF in that order because little endian
# 111111101111111111111111 ie <FE><FF><FF> for (c,h,s)=(1023, 255, 63)
# show that as a hex string and with packing
for my $bin ("\xFE\xFF\xFF", pack("H*", "FEFFFF")) {
 my ($c_lba, $h_lba, $s_lba)=hcs_to_chs($bin);
 unless ($c_lba==1023 and $h_lba==254 and $s_lba==63) {
  print "LBA detection assertion failed with $bin";
  print "<FE><FF><FF> little endian does not give c,h,s=1023,254,63\n";
  die;
 } # unless
} # for

# Simple assertions to check the hashes are correctly assembled:
my $check_0700_nick= $guid_to_nick{"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"};
unless ($check_0700_nick=~m/0700/) {
 print "Failed assertion: GUID EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 should be MBR type 07 therefore nick 0700\n";
 print "Instead, is $check_0700_nick\n";
 die;
}
my $check_0700_text= $guid_to_text{"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"};
unless ($check_0700_text=~m/Microsoft basic data/) {
 print "Failed assertion: GUID EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 should be 'Microsoft basic data'\n";
 print "Instead, is $check_0700_text\n";
 die;
}

my $check_ef00_nick= $guid_to_nick{"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"};
unless ($check_ef00_nick=~m/ef00/) {
 print "Failed assertion: GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B should be MBR type EF therefore nick EF00\n";
 print "Instead, is $check_ef00_nick\n";
 die;
}
my $check_ef00_text= $guid_to_text{"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"};
unless ($check_ef00_text=~m/EFI system partition/) {
 print "Failed assertion: GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B should be 'EFI system partition'\n";
 print "Instead, is $check_ef00_text\n";
 die;
}

## Actual beginning
my $device = shift @ARGV or die "Usage: $0 <block device> [<blocksize>]\n";
my $bsize;
unless ($bsize=shift @ARGV) {
 # Assign a default value to the second argument
 $bsize=$hardcoded_default_block_size;
}

## Device information like size and LBA blocks
if ($nodevinfo <1) {
 print "# DEVICE:\n";
}
my %device;

if ($nodevinfo <1) {
 print "Checking $device with a LBA block size $bsize\n";
 print "(block size irrelevant for the MBR at LBA0, but important for GPT at LBA1)\n";
}

# Open the block device for reading in binary mode
open my $fh, "<:raw", $device or die "Can't open $device: $!\n";

# Estimate the size
seek $fh, -1, 2 or die "Can't seek to the end: $!\n";
my $offset_end=tell $fh;
$device{end}=$offset_end;
my $device_size_G=$offset_end/(1024**3);
my $lba=$offset_end/$bsize;
$device{lba}=$lba;
my $lba_int=int($lba);
if ($nodevinfo <1) {
 printf "Size %.2f G, rounds to $lba_int LBA blocks for $lba\n", $device_size_G;
}
# Check if goes beyond the end of a few usual LBA-bit MBR space:
# 22 bit (original IDE), 28 bit (ATA-1 from 1994), 48 bit (ATA-6 from 2003)
for my $i (28, 32, 48) {
 if ($offset_end > (2**$i) ) {
  # Warn that MBR entries store LBA offsets and sizes as 32 bit little endians
  if ($nodevinfo <1) {
   print "WARNING: this is more than LBA-$i can handle (many MBR use LBA-32)\n";
  } # if
 } # if
} # for my i

## MBR
if ($noheaders <1) {
 print "\n# MBR HEADER:\n";
}
my %mbr_header;

my $mbrbootcode;
read $fh, $mbrbootcode, $hardcoded_mbr_bootcode_size, 0;
if ($mbrbootcode=~ m/^\0*$/) {
 print "Note: MBR bootcode empty, must be a GPT system\n";
}

# Seek to 440 (near the MBR end at offset 446)
seek $fh, $hardcoded_mbr_bootcode_size, 0 or die "Can't seek to offset 440 near the end of the MBR: $!\n";
my $mbrsigs;
read $fh, $mbrsigs, $hardcoded_mbr_signature_size or die "Can't read the MBR signatures: $!\n";
# at 440 there are 4 bytes for the disk number (signature)
# at 444 there should be 2 null bytes that have been historically reserved
my ($disksig, $nullsig) = unpack 'H8a2', $mbrsigs;

# Then check that at 510, there's the expected 2 bytes boot signature
# (0x55aa in little endian)
seek $fh, $hardcoded_mbr_bootsig, 0 or die "Can't seek to MBR boot signature: $!\n";
my $bootsig;
read $fh, $bootsig, $hardcoded_mbr_bootsig_size or die "Can't read MBR boot signature: $!\n";
my $bootsig_le=unpack ("H4", $bootsig);
my $disksig_le=unpack ("V", pack ("H8", $disksig));

# Show the MBR headers
if ($noheaders <1) {
 printf "Disk UUID: %08x\n", $disksig_le;
 if ($bootsig eq "\x55\xaa") {
  printf "Signature (valid): $bootsig_le\n";
 } else {
  printf "Signature (WARNING: INVALID): $bootsig_le\n";
 }
 if ($nullsig eq "\x00\x00") {
  printf "2 null bytes (valid): $nullsig(obviously not visible)\n";
 } else {
  printf "2 null bytes (WARNING: NOT NULL): $nullsig\n";
 }
} # if noheader

# Populate the mbr header hash
$mbr_header{bootsig}=$bootsig_le;
$mbr_header{disksig}=$disksig_le;
$mbr_header{nullsig}=$nullsig;

## GPT header before MBR partitions to correct bsize as needed for isodetect
if ($noheaders <1) {
 print "\n# GPT HEADER:\n";
}
my %gpt_main_header;

# Seek to the GPT header location at LBA1 ie 1*(block size)
seek $fh, $bsize, 0 or die "Can't seek to the MAIN GPT header: $!\n";

# Read 92 bytes of GPT header
my $gpt_header;
read $fh, $gpt_header, $hardcoded_gpt_header_size or die "Can't read MAIN GPT header: $!\n";

# Parse the GPT header into fields
my ($signature,
 $revision, $header_size, $header_crc32own, $reserved,
 $current_lba, $other_lba, $first_lba, $final_lba, $guid,
 $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own) = unpack "a8 L L L L Q Q Q Q a16 Q L L L",
 $gpt_header;

# Check the GPT signature and revision
if ($signature eq "EFI PART") {
 if ($noheaders <1) {
  printf "Signature (valid): %s\n", $signature;
 }
} else {
 if ($noheaders <1) {
  printf "Signature (WARNING: INVALID): %s\n", $signature;
 }
 # This should NOT happen, so try again after changing bsize
 if ($noheaders <1) {
  print "WARNING: Trying again after setting bsize=";
 }
 for my $try_bsize (512, 2048, 4096) {
  $bsize=$try_bsize;
  if ($noheaders <1) {
   print "$bsize,";
  }
  seek $fh, $bsize, 0 or die "Can't seek to the MAIN GPT header: $!\n";
  # Read 92 bytes of GPT header
  read $fh, $gpt_header, $hardcoded_gpt_header_size or die "Can't read MAIN GPT header: $!\n";
  # Reparse the GPT header into fields
  ($signature,
   $revision, $header_size, $header_crc32own, $reserved,
   $current_lba, $other_lba, $first_lba, $final_lba, $guid,
   $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own) = unpack "a8 L L L L Q Q Q Q a16 Q L L L",
  $gpt_header;
  if ($signature eq "EFI PART") {
   if ($noheaders <1) {
    printf " and this worked.\n";
    printf "WARNING: Was given wrong paramer, now using bsize=$bsize\n";
    printf "Signature (valid): %s\n", $signature;
   }
   # noheaders or not, if the wrong information was given, say something
   $lba=$offset_end/$bsize;
   # Update the LBA
   $device{lba}=$lba;
   $lba_int=int($lba);
   if ($nodevinfo <1) {
    printf "Size %.2f G, rounds to $lba_int LBA blocks for $lba\n", $device_size_G;
   }
   # Check if goes beyond the end of a few usual LBA-bit MBR space:
   # 22 bit (original IDE), 28 bit (ATA-1 from 1994), 48 bit (ATA-6 from 2003)
   for my $i (28, 32, 48) {
    if ($offset_end > (2**$i) ) {
     # Warn that MBR entries store LBA offsets and sizes as 32 bit little endians
     if ($nodevinfo <1) {
      print "WARNING: this is more than LBA-$i can handle (many MBR use LBA-32)\n";
     }
    } # if
   } # for i
  } # if signature 2nd attempt
 } # for try_bsize
} # else signature

# Check the GPT signature and revision
if ($noheaders <1) {
 if ($revision == 0x00010000) {
  printf "Revision: %08x\n", $revision;
 } else {
  printf "Revision (WARNING: UNKNOWN): %08x\n", $revision;
 }
 # Print the rest of the GPT header information
 printf "Header size (hardcoded $hardcoded_gpt_header_size): %d\n", $header_size;
} # if noheaders
# Check if the CRC is correct by reproducing its calculation: field zeroed out
#my $header_nocrc32 = substr ($header, 0, 16) . "\x00\x00\x00\x00" . substr ($header, 20);
# But here, reassembles everything from the variables to facilitate tweaks
my $header_nocrc32 = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $signature, $revision, $header_size, ord("\0"), $reserved,
 $current_lba, $other_lba, $first_lba, $final_lba, $guid,
 $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own);
my $header_crc32check=crc32($header_nocrc32);
if ($noheaders <1) {
 if ($header_crc32check == $header_crc32own) {
  printf "Header CRC32 (valid): %08x\n", $header_crc32own;
 } else {
  printf "Header CRC32 (WARNING: INVALID BECAUSED EXPECTED %08x", $header_crc32check;
  printf "): %08x\n", $header_crc32own;
 }
 printf "Current header (main) LBA: %d\n", $current_lba;
 printf "Other header (backup) LBA: %d\n", $other_lba;
 printf "First LBA: %d\n", $first_lba;
 printf "Final LBA: %d\n", $final_lba;
 #printf "GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $guid;
 # GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
 # but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
 printf "Disk GUID: %s\n", guid_proper($guid);
 printf "GPT current (main) LBA: %d\n", $gptparts_lba;
 printf "Number of partitions: %d\n", $num_parts;
 printf "Partition record size: %d\n", $part_size;
 printf "Partitions CRC32 (validity unknown yet):  %08x\n", $gptparts_crc32own;
}
# Populate the gpt main header hash
$gpt_main_header{signature}=$signature;
$gpt_main_header{revision}=$revision;
$gpt_main_header{header_size}=$header_size;
$gpt_main_header{header_crc32own}=$header_crc32own;
$gpt_main_header{reserved}=$reserved;
$gpt_main_header{current_lba}=$current_lba;
$gpt_main_header{other_lba}=$other_lba;
$gpt_main_header{first_lba}=$first_lba;
$gpt_main_header{final_lba}=$final_lba;
$gpt_main_header{guid_as_stored}=$guid;
$gpt_main_header{guid}=guid_proper($guid);
$gpt_main_header{gptparts_lba}=$gptparts_lba;
$gpt_main_header{num_parts}=$num_parts;
$gpt_main_header{part_size}=$part_size;
$gpt_main_header{gptparts_crc32own}=$gptparts_crc32own;
if ($header_crc32check == $header_crc32own) {
 $gpt_main_header{header_crc32}{valid}=1;
} else {
 $gpt_main_header{header_crc32}{valid}=0;
}

## Primary MBR partitions & iso signatures exploration
if ($noheaders <1) {
 print "\n# MBR PARTITIONS:\n";
}
my %mbr_partitions;
# Keep track separately of what LBAs have been explored for CD001 signatures
# (in case of partitions overlap)
my %isosig_explored;

# Seek back to the MBR location at offset 446
seek $fh, $hardcoded_mbr_bootcode_size+$hardcoded_mbr_signature_size, 0 or die "Can't seek to MBR: $!\n";

# Read 64 bytes of MBR partition table
my $mbr;
read $fh, $mbr, $hardcoded_mbr_size or die "Can't read MBR: $!\n";

# Parse the MBR partition table into four 16-byte entries
my @partitions = unpack "(a16)4", $mbr;

# Loop through each MBR partition entry
for my $i (0 .. 3) {
 # Extract the partition status, CHS first, type, CHS final, LBA start, and LBA sectors 
 my ($status, $hcs_a, $hcs_b, $hcs_c, $type, $hcs_x, $hcs_y, $hcs_z, $start, $sectors) = unpack "C C3 C C3 V V", $partitions[$i];

 # Preserve deprecated CHS fields as they can be used to decide on a LBA scheme
 my $hcs_first=pack ("CCC", $hcs_a, $hcs_b, $hcs_c);
 my $hcs_final=pack ("CCC", $hcs_x, $hcs_y, $hcs_z);

 #next if $type == 0;
 # DON'T skip empty partitions: it may be an isohybrid with a iso9660 filesystem
 # fdisk will say "The device contains 'iso9660' signature and it will be removed by a write command."
 # if so, the first 32kb 0x00-0x0f are the reserved system area:
 # it will contain the boot information (ex: mbr, gpt, apm...)
 # after that, can find volume descriptors starting at 0x10 ie 32768:
 # each is 2k (2048b), starting with a type at offset 0 and a length at offset 1
 # => can count how many volume descriptors, if they follow the iso structure
 # not an "empty" partition if many such signatures, and type 255 for the last

 # Calculate the partition end and the number of sectors
 my $end = $start + $sectors - 1;
 # Use that to get the size in M: use the block sector size optional argument
 my $size = ($sectors * $bsize)/(1024*1024);
 # Suffix the type to project to the nick
 my $nick = lc(sprintf("%02x",$type)) . "00";

 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "MBR Partition #%d: Start: %d, Stops: %d, Sectors: %d, Size: %d M\n", $i + 1, $start, $end, $sectors, $size;
 if ($hcs_first eq "\xFF\xFF\xFF" and $hcs_final eq $hcs_first) {
  print " HCS fields both 0xFFFFFF indicates LBA-48 mode\n";
 } elsif ($hcs_first eq "\0\0\0" and $hcs_final eq $hcs_first) {
  print " HCS fields both 0 indicates LBA-32 mode\n";
 } elsif ($hcs_first eq "\xFE\xFF\xFF" or $hcs_final eq "\xFE\xFF\xFF") {
  # WARNING: little endian
  if ($hcs_first eq "\xFE\xFF\xFF") {
   print " HCS first <FE><FF><FF> (LE) maxes out (c,h,s) to (1023, 255, 63), check partition type\n";
  }
  if ($hcs_final eq "\xFE\xFF\xFF") {
   print " HCS final <FE><FF><FF> (LE) maxes out (c,h,s) to (1023, 255, 63), check partition type\n";
  } else {
   my ($c_first, $h_first, $s_first) = hcs_to_chs($hcs_first);
   my ($c_final, $h_final, $s_final) = hcs_to_chs($hcs_final);
   # bin to hex, should have used sprintf
   my $first = unpack ("H*", $hcs_first);
   my $final = unpack ("H*", $hcs_final);
   print " HCS decoded to (c,h,s): span ($c_first, $h_final, $s_final) =$first to ($c_final, $h_final, $s_final) = $final\n";
  } # <FE><FF><FF> either first or final
 } # hcs fields

 # Populate the mbr partition hash
 $mbr_partitions{$i}{status}=$status;
 $mbr_partitions{$i}{hcs_first_raw}=$hcs_first;
 $mbr_partitions{$i}{type}=$type;
 $mbr_partitions{$i}{hcs_final_raw}=$hcs_final;
 $mbr_partitions{$i}{nick}=$nick;
 $mbr_partitions{$i}{start}=$start;
 $mbr_partitions{$i}{sectors}=$sectors;

 my $stat= sprintf ("%02x", $status);
 my $mbrtype= uc(sprintf ("%02x", $type));
 # WARNING: use {"$nick"} or 0700 becomes 7
 my $test= $nick_to_mbrtext{"$nick"};
 print " Nick: $nick, Text: $nick, MBR type: $mbrtype, Status: $stat\n";
 # if multiple partitions are defined to start at the same address, will only explore once
 if ($type == 0 and $noisodetect<1) {
  # look for ISO9660 signature: ASCII string CD001 and count how many there are
  # usually occurs at offset 32769 (0x8001), 34817 (0x8801), or 36865 (0x9001):
  #  32769 is the Primary Volume Descriptor (PVD) of an ISOFS:
  #    at LBA 0x10=16, and each block is 2048 bytes long
  #    so offset: 16 * 2048 + 1 = 32769
  #  34817 is the Supplementary Volume Descriptor (SVD) for Joliet extensions:
  #    at the LBA 17, so the offset is 17 * 2048 + 1 = 34817
  #  37633: is the Boot Record Volume Descriptor (BRVD):
  #    at the LBA 19, so the offset is 19 * 2048 + 1 = 37633
  #
  # And so on: 18*2048+1=36865, 19*2048+1= 38913: just check final type=255
  open my $fh, "<:raw", $device or die "Can't open $device: $!\n";
  my $isosig_nbr=0;
  # volume descriptors start at LBA X+16, can start again at LBA X+32
  # should check at different LBAs:
  #  - from the beginning of the drive: X=0, LBA=X+vd_lba_start
  #  - from the beginning of the partition: X=start, LBA=X+vd_lba_start
  for my $begin (0, $start) {
   my @vd_lbas_starts=(0, 16, 32);
   for my $vd_start (@vd_lbas_starts) {
    # so add this vd_lba_start 
    my $lba=$begin + $vd_start;
    # don't explore again the same lba: check the hash
    if ($debug_isodetect>0) {
     if (exists $isosig_explored{$lba}) {
      print " (already shown its data at $lba in previous partition #$isosig_explored{$lba})\n";
     }
     print " - checking LBA $lba for volume descriptor start $vd_start at partition start $start\n";
    } # if debug
    unless (defined $isosig_explored{$lba}) {
     # mark it as explored
     $isosig_explored{$lba}=$i+1;
     my $type=0;
     until ($type > 254) {
      my $offset=$lba*2048;
      seek $fh, $offset, 0 or die "Can't seek to iso signature at LBA $lba: $!\n";
      my $vd;
      read $fh, $vd, 64 or die "Can't read volume: $!\n";
      my $isosig;
      ($type, $isosig)= unpack ("C A5", $vd);
      if ($isosig =~ m/^CD001$/) {
       print "\tseen CD001 at lba: $lba, offset: $offset, type: $type\n";
       $isosig_nbr=$isosig_nbr+1;
      } else {
       # not really, but will serve to break the loop
       $type=256;
      }
      $lba=$lba+1;
     } # until type
    } # unless isosig_explored
   } # for my vd_start
  } # for my begin
  if ($isosig_nbr>2) {
   print ("\tthus not type 00=empty but has an ISO9600 filesystem\n");
  }
  # Save to the hash, regardless of the value
  $mbr_partitions{$i}{isosig}=$isosig_nbr;
 } # if type 0
} # for my i

## Secondary GPT header
my %gpt_backup_header;
# should have $other_lba by the end of the disk:
# LBA      Z-33: last usable sector
# LBA       Z-2:  GPT partition table (backup)
# LBA       Z-1:  GPT header (backup)
# LBA         Z: end of disk

# Use a negative number to go in the other direction, from the end
seek $fh, -1*$bsize, 2 or die "Can't seek to BACKUP header at LBA-2: $!\n";
# Then get the actual position
my $other_offset = tell $fh;
my $other_lba_offset=int($other_offset/$bsize);

# And check if it matches: then $other_lba is by the end of the disk
if ($noheaders <1) {
 print "\n";
 if ($other_lba == $other_lba_offset) {
  print "# BACKUP GPT header (valid offset for LBA-1 -> $other_offset): $other_lba\n";
 } else {
  print "# BACKUP GPT header (WARNING: INVALID OFFSET SINCE LBA-1 -> $other_lba_offset != $other_offset): $other_lba\n";
 }
}
# Yet store that possible discrepency in the hash
$gpt_main_header{other_lba_expected}=$other_lba_offset;

my $backup_header;
read $fh, $backup_header, $hardcoded_gpt_header_size or die "Can't read backup GPT header: $!\n";

# Parse the backup GPT header into fields
my ($backup_signature, $backup_revision, $backup_header_size, $backup_header_crc32own, $backup_reserved,
 $backup_current_lba, $backup_other_lba, $backup_first_lba, $backup_final_lba, $backup_guid,
 $backup_gptparts_lba, $backup_num_parts, $backup_part_size, $backup_gptparts_crc32own) = unpack "a8 L L L L Q Q Q Q a16 Q L L L", $backup_header;

# Check the GPT signature and revision
# But don't die if the backup is wrong, as it could simply be missing
#die "Unsupported GPT revision: $backup_revision\n" unless $backup_revision == 0x00010000;
if ($noheaders <1) {
 # Check the GPT signature and revision
 if ($signature ne $backup_signature) {
  if ($backup_signature eq "EFI PART") {
   printf "DIVERGENCE: BACKUP Signature (valid): %s\n", $backup_signature;
  } else {
   printf "DIVERGENCE: BACKUP Signature (WARNING: INVALID): %s\n", $backup_signature;
  }
  if ($backup_revision == 0x00010000) {
   printf "DIVERGENCE: BACKUP Revision: %08x\n", $backup_revision;
  } else {
   printf "DIVERGENCE: BACKUP Revision (WARNING: UNKNOWN): %08x\n", $backup_revision;
  }
  if ($header_size != $backup_header_size) {
   print "DIVERGENCE: BACKUP Header size (hardcoded $hardcoded_gpt_header_size): $backup_header_size\n";
  }
 }
}

# Do a quick check if the CRC is ok: reproduce it with own field zeroed out
my $backup_header_nocrc32 = substr ($backup_header, 0, 16) . "\x00\x00\x00\x00" . substr ($backup_header, 20);
my $backup_header_crc32check=crc32($backup_header_nocrc32);
if ($noheaders <1) {
 if ($backup_header_crc32check == $backup_header_crc32own) { 
  printf "BACKUP CRC32 (valid): %08x\n", $backup_header_crc32own;
 } else {
  printf "BACKUP CRC32 (WARNING: INVALID BECAUSED EXPECTED %08x", $backup_header_crc32check;
  printf "): %08x\n", $backup_header_crc32own;
 }
}
# Then prepare CRC32 if the backup was canonical or primary wasn't primary:
# - as usual, remove own header crc32
# - swap backup_current_lba and backup_other_lba
# - swap gptparts_lba and backup_gptparts_lba
# This allow divergence checks and shows helpful information (hexedit/tweaks)
my $backup_header_nocrc32_if_canonical= pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $backup_signature, $backup_revision, $backup_header_size, ord("\0"), $backup_reserved,
 $backup_other_lba, $backup_current_lba, $backup_first_lba, $backup_final_lba, $backup_guid,
 $gptparts_lba, $backup_num_parts, $backup_part_size, $backup_gptparts_crc32own);
my $header_nocrc32_if_noncanonical = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $signature, $revision, $header_size, ord("\0"), $reserved,
 $other_lba, $current_lba, $first_lba, $final_lba, $guid,
 $backup_gptparts_lba, $num_parts, $part_size, $gptparts_crc32own);

# Only show the differences
if ($noheaders <1) {
 if (crc32($backup_header_nocrc32_if_canonical) ne $header_crc32own) {
  printf "DIVERGENCE: BACKUP CRC32 if BACKUP Canonical: %08x (if backup became main at main LBA)\n", crc32($backup_header_nocrc32_if_canonical);
 }
 if (crc32($header_nocrc32_if_noncanonical) ne $backup_header_crc32own) {
  printf "DIVERGENCE: MAIN CRC2 if MAIN Non-Canonical: %08x (if main became backup at backup LBA)\n", crc32($header_nocrc32_if_noncanonical);
 }
 if ($backup_current_lba != $other_lba) {
  printf "DIVERGENCE: BACKUP Current (backup) LBA: %d\n", $backup_current_lba;
 }
 if ($current_lba != $backup_other_lba) {
  printf "DIVERGENCE: BACKUP Other (main) LBA: %d\n", $backup_other_lba;
 }
 if ($first_lba != $backup_first_lba) {
  printf "DIVERGENCE: BACKUP First LBA: %d\n", $backup_first_lba;
 }
 if ($final_lba != $backup_final_lba) {
  printf "DIVERGENCE: BACKUP Final LBA: %d\n", $backup_final_lba;
 }
  #printf "GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $backup_guid;
  # GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
  # but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
 if ($guid ne $backup_guid) {
  printf "DIVERGENCE: BACKUP GUID: %s\n", guid_proper($backup_guid);
 }
 # gptparts_lba from main must diverge from backup_gptparts_lba
 printf "BACKUP GPT current (backup) LBA: %d\n", $backup_gptparts_lba;
 if ($num_parts != $backup_num_parts) {
  printf "DIVERGENCE: BACKUP Number of partitions: %d\n", $backup_num_parts;
 }
 if ($part_size != $backup_part_size) {
  printf "DIVERGENCE: BACKUP Partition size: %d\n", $backup_part_size;
 }
}

# Now populate the gpt backup header hash
$gpt_backup_header{signature}=$backup_signature;
$gpt_backup_header{revision}=$backup_revision;
$gpt_backup_header{header_size}=$backup_header_size;
$gpt_backup_header{header_crc32own}=$backup_header_crc32own;
$gpt_backup_header{reserved}=$backup_reserved;
$gpt_backup_header{current_lba}=$backup_current_lba;
$gpt_backup_header{other_lba}=$backup_other_lba;
$gpt_backup_header{first_lba}=$backup_first_lba;
$gpt_backup_header{final_lba}=$backup_final_lba;
$gpt_backup_header{guid}=$backup_guid;
$gpt_backup_header{gptparts_lba}=$backup_gptparts_lba;
$gpt_backup_header{num_parts}=$backup_num_parts;
$gpt_backup_header{part_size}=$backup_part_size;
$gpt_backup_header{gptparts_crc32own}=$backup_gptparts_crc32own;
if ($backup_header_crc32check == $backup_header_crc32own) {
 $gpt_backup_header{header_crc32}{valid}=1;
} else {
 $gpt_backup_header{header_crc32}{valid}=0;
}

# Having both gpt headers, can decide to replace one by the other
# however, this requires knowing if it would work given the crc32 + swaps
if (crc32($backup_header_nocrc32_if_canonical) ne $header_crc32own) {
 $gpt_backup_header{header_crc32}{valid_as_main}=0;
} else {
 $gpt_backup_header{header_crc32}{valid_as_main}=1;
}
if (crc32($header_nocrc32_if_noncanonical) ne $backup_header_crc32own) {
 $gpt_main_header{header_crc32}{valid_as_backup}=0;
} else {
 $gpt_main_header{header_crc32}{valid_as_backup}=1;
}
# The same will be done with the partitions after reading them

## Main GPT partitions
print "\n# MAIN GPT PARTITIONS:\n";
my %gpt_main_partitions;

# Go to the start LBA offset
my $offset=$gptparts_lba*$bsize;
seek $fh, $offset, 0 or die "Can't seek to the GPT lba $gptparts_lba: $!\n";

# The GPT hould have several partitions of 128 bytes each, but nothing hardcoded
my $gptparts;
my $span=$num_parts*$part_size;
read $fh, $gptparts, $span or die "Can't read the GPT at $num_parts*$part_size: $!\n";

# crc32 what we just read to inform the gpt main header hash of the validity
if ($gptparts_crc32own == crc32($gptparts)) {
 printf "Partition CRC32 (valid): %08x\n", $gptparts_crc32own;
 $gpt_main_header{gptparts_crc32}{valid}=1;
} else {
 printf "Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($gptparts);
 printf "): %08x\n", $gptparts_crc32own;
 $gpt_main_header{gptparts_crc32}{valid}=0;
}

# Read the gpt partitions records
my @partitions_records=unpack "(a$part_size)$num_parts", $gptparts;

# Then populate a partition hash by unpacking each partition entry
my $i=0;
my $partition_entry_empty="\x00" x $part_size;
for my $partition_entry (@partitions_records) {
 # Unpack each partition entry into fields
 my ($type_guid, $part_guid, $first_lba, $final_lba, $attr, $name) = unpack "a16 a16 Q Q Q a*", $partition_entry;
 # Skip empty partitions?
 #next if $type_guid eq "\x00" x 16;
 # Don't skip empties as could have the 1st partition be the nth, n!=1
 # Instead, mark as empty
 # Populate the gpt main partitions hash
 if ($partition_entry eq $partition_entry_empty) {
  $gpt_main_partitions{$i}{empty}=1;
 } else {
  $gpt_main_partitions{$i}{type_guid}=$type_guid;
  $gpt_main_partitions{$i}{nick}=$type_guid;
  $gpt_main_partitions{$i}{part_guid}=$part_guid;
  $gpt_main_partitions{$i}{first_lba}=$first_lba;
  $gpt_main_partitions{$i}{final_lba}=$final_lba;
  $gpt_main_partitions{$i}{attr}=$attr;
  # Strip null bytes from the name
  $name=~tr/\0//d;
  $gpt_main_partitions{$i}{name}=$name;
  # Store the guid as it's expected
  my $guid_seps=guid_proper($type_guid);
  my $nick=$guid_to_nick{$guid_seps};
  $gpt_main_partitions{$i}{guid}=$guid_seps;
  # And the nick to facilitate MBR<->GPT operations
  $gpt_main_partitions{$i}{nick}=$nick;
 }
 $i=$i+1;
} # for @partitions_records

# Find the maximal value for non empty partition to stop showing past that
my $partitions_max_nonempty;
for my $r ( sort { $a <=> $b } keys %gpt_main_partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 unless (defined($gpt_main_partitions{$c}{empty})) {
  $partitions_max_nonempty=$c;
 } # unless defined
} # for

# No need to loop through each partition entry: show from the hash
for my $r ( sort { $a <=> $b } keys %gpt_main_partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 if (defined($gpt_main_partitions{$c}{empty})) {
  if ($gpt_main_partitions{$c}{empty}==1) {
   if ($c <$partitions_max_nonempty) {
    print "Partition $c: (empty)\n";
   }
  }
 } else {
  my $type_guid=$gpt_main_partitions{$c}{type_guid};
  my $guid=$gpt_main_partitions{$c}{guid};
  my $part_guid=$gpt_main_partitions{$c}{part_guid};
  my $first_lba=$gpt_main_partitions{$c}{first_lba};
  my $final_lba=$gpt_main_partitions{$c}{final_lba};
  my $attr= $gpt_main_partitions{$c}{attr};
  my $name=$gpt_main_partitions{$c}{name};
  my $nick=$gpt_main_partitions{$c}{nick};
  # Print the partition number and information
  my $sectors=$final_lba - $first_lba + 1;
  my $size = int (($sectors * $bsize)/(1024*1024));
  print "GPT Partition #$c: Start $first_lba, Stops: $final_lba, Sectors: $sectors, Size: $size M\n";
  # Get the short nick from the guid, and likewise for the textual description
  print " Nick: $nick, Text: $guid_to_text{$guid}, Name: $name, GUID: $guid\n";
  if ($attr>0) {
   print " Attributes bits set: ";
   # loop through the bits of the attributes
   for my $j (0 .. 63) {
    # check if the bit is set
    if ($attr & (1 << $j)) {
     print "$j";
     # give the meaning too
     if (defined($gpt_attributes[$j])) {
      print " ($gpt_attributes[$j])";
     } # if text
     print ", ";
    } # if bit
   } # for
   print "\n";
  } # if attr
 } # else empty
} # for

## Backup GPT partitions
print "\n";
print "# BACKUP GPT PARTITIONS:\n";

# Should *end* at LBA -2, meaning must take into account the partition size
# by default 128 partitions, 128 bytes each: so 16k before LBA-2

# Use a negative number to go in the other direction, from the end
seek $fh, (-128*128)-1*$bsize, 2 or die "Can't seek to backup GPT ending at LBA-2: $!\n";
# Then get the actual position
my $gptbackup_offset = tell $fh;
my $gptbackup_lba_offset=int($gptbackup_offset/$bsize);

# And check if it matches: then $other_lba is by the end of the disk
if ($backup_gptparts_lba == $gptbackup_lba_offset) {
 print "BACKUP GPT AT (valid offset for LBA-2 -> $gptbackup_offset): $backup_gptparts_lba\n";
} else {
 print "BACKUP GPT AT (WARNING: UNEXPECTED AT $gptbackup_offset SINCE LBA-2 -> $gptbackup_lba_offset): $backup_gptparts_lba\n";
}
# Yet store that possible discrepency in the hash
$gpt_backup_header{expected_current_lba}=$gptbackup_lba_offset;

# Go to the start LBA offset
my $backup_offset=$backup_gptparts_lba*$bsize;
seek $fh, $backup_offset, 0 or die "Can't seek to the BACKUP GPT lba $backup_gptparts_lba: $!\n";

# The GPT hould have several partitions of 128 bytes each, but nothing hardcoded
my $backup_gptparts;
my $backup_span=$num_parts*$part_size;
read $fh, $backup_gptparts, $span or die "Can't read the BACKUP GPT at $backup_num_parts*$backup_part_size: $!\n";

# We're now done with the reading
close $fh or die "Can't close $device: $!\n";

# Crc32 what we just read, to update the backup header crc32 validity
if ($backup_gptparts_crc32own == crc32($backup_gptparts)) {
 printf "BACKUP Partition CRC32 (valid): %08x\n", $gptparts_crc32own;
 $gpt_backup_header{gptparts_crc32}{valid}=1;
} else {
 printf "BACKUP Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($backup_gptparts);
 printf "): %08x\n", $backup_gptparts_crc32own;
 $gpt_backup_header{gptparts_crc32}{valid}=0;
}

# Read the gpt partitions records
my @backup_partitions_records=unpack "(a$backup_part_size)$backup_num_parts", $backup_gptparts;

# Then populate a partition hash by unpacking each partition entry
# need to do the partition CRC, but doing a hash will help after for output
my %gpt_backup_partitions;
my $j=0;
for my $partition_entry (@backup_partitions_records) {
 # Unpack each partition entry into fields of the hash
 my ($type_guid, $part_guid, $first_lba, $final_lba, $attr, $name) = unpack "a16 a16 Q Q Q a*", $partition_entry;
 # Skip empty partitions?
 #next if $type_guid eq "\x00" x 16;
 # Don't skip empties as could have the 1st partition be the nth, n!=1
 # Instead, mark as empty
 # Populate the hash
 if ($partition_entry eq $partition_entry_empty) {
  $gpt_backup_partitions{$j}{empty}=1;
 } else {
  $gpt_backup_partitions{$j}{type_guid}=$type_guid;
  $gpt_backup_partitions{$j}{part_guid}=$part_guid;
  $gpt_backup_partitions{$j}{first_lba}=$first_lba;
  $gpt_backup_partitions{$j}{final_lba}=$final_lba;
  $gpt_backup_partitions{$j}{attr}=$attr;
  # Strip null bytes from the name
  $name=~tr/\0//d;
  $gpt_backup_partitions{$j}{name}=$name;
  # Store the guid as it's expected
  my $guid_seps=guid_proper($type_guid);
  my $nick=$guid_to_nick{$guid_seps};
  $gpt_backup_partitions{$j}{guid}=$guid_seps;
  # And the nick to facilitate MBR<->GPT operations
  $gpt_backup_partitions{$j}{nick}=$nick;
 }
 $j=$j+1;
} # for @partitions_records

# Find the maximal value for non empty partition to stop showing past that
my $backup_partitions_max_nonempty;
for my $r ( sort { $a <=> $b } keys %gpt_backup_partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 unless (defined($gpt_backup_partitions{$c}{empty})) {
  $backup_partitions_max_nonempty=$c;
 } # unless defined
} # for

# Count the divergences checked to tell if everything is normal
my $divergences_checked=0;
my $diverged_even_once=0;

# No need to loop through each partition entry: show from the hash
for my $r ( sort { $a <=> $b } keys %gpt_backup_partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 if (defined($gpt_backup_partitions{$c}{empty})) {
  # but what if not in main?
  unless (defined($gpt_main_partitions{$c}{empty})) {
     print "DIVERGENCE: BACKUP Partition $c: (empty) while MAIN is NOT empty\n";
  }
  if ($gpt_backup_partitions{$c}{empty}==1) {
   if ($c < $backup_partitions_max_nonempty) {
    # only show if there's a difference somewhere:
    if ($gpt_backup_partitions{$c}{empty} != $gpt_main_partitions{$c}{empty}) {
     print "DIVERGENCE: BACKUP Partition $c: (empty)\n";
    }
   }
  }
 } else {
  my $type_guid=$gpt_backup_partitions{$c}{type_guid};
  my $guid=$gpt_backup_partitions{$c}{guid};
  my $nick=$gpt_backup_partitions{$c}{nick};
  my $part_guid=$gpt_backup_partitions{$c}{part_guid};
  my $first_lba=$gpt_backup_partitions{$c}{first_lba};
  my $final_lba=$gpt_backup_partitions{$c}{final_lba};
  my $attr=$gpt_backup_partitions{$c}{attr};
  my $name=$gpt_backup_partitions{$c}{name};
  my $divergent=0;

  # Detect differences to only show the different entries
  if ($gpt_main_partitions{$c}{type_guid} ne $type_guid
   or $gpt_main_partitions{$c}{part_guid} ne $part_guid
   or $gpt_main_partitions{$c}{first_lba} ne $first_lba
   or $gpt_main_partitions{$c}{final_lba} ne $final_lba
   or $gpt_main_partitions{$c}{attr} ne $attr
   or $gpt_main_partitions{$c}{name} ne $name) {
    $divergent=1;
    $diverged_even_once=1;
  }
  # But at least we checked!
  $divergences_checked=$divergences_checked+1;

  # Print the partition number and information
  my $sectors=$backup_final_lba - $backup_first_lba + 1;
  my $size = int (($sectors * $bsize)/(1024*1024));
  # New simpler format
  if ($divergent>0) {
   print "DIVERGENCE: BACKUP GPT Partition #$c: Start $first_lba, Stops: $final_lba, Sectors: $sectors, Size: $size M\n";
   # Show the details
   print " Nick: $nick, Text: $guid_to_text{$guid}, Name: $name, GUID: $guid\n";
   if ($attr>0) {
    print " Attributes bits set: ";
    # loop through the bits of the attributes
    for my $j (0 .. 63) {
     # check if the bit is set
     if ($attr & (1 << $j)) {
      print "$j";
      # give the meaning too
      if (defined($gpt_attributes[$j])) {
       print " ($gpt_attributes[$j])";
      } # if text
      print ", ";
     } # if bit
    } # for
    print "\n";
   } # if attr
  } # if divergent
 } # else emptpy
} # for my r

if ($diverged_even_once==0) {
 print "BACKUP GPT PARTITIONS: Strictly identical, checked for divergence $divergences_checked times (once for each known GPT partition)\n"
}

