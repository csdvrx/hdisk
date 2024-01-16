#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed

## Dump the MBR partitions

use strict;
use warnings;
use Data::Dumper;

# Check if a block device name is given as an argument
my $device = shift @ARGV or die "Usage: $0 <block device>\n";

# Look for el torito records inside an ISO device for up to partition X
my $isodetect=0;

# Open the block device for reading in binary mode
open my $fh, "<:raw", $device or die "Can't open $device: $!\n";

# Seek to 440 (near the MBR end at offset 446)
seek $fh, 440, 0 or die "Can't seek to offset 440 near the end of the MBR: $!\n";
my $sigs;
read $fh, $sigs, 6 or die "Can't read the signatures in 6 bytes: $!\n";
# at 440 there are 4 bytes for the disk number (signature)
# at 444 there should be 2 null bytes that have been historically reserved
my ($disksig, $nullsig) = unpack 'H8a2', $sigs;

# Then read the 64 bytes of the MBR partition table starting at 446:
# 16 bytes x 4 primary partitions
my $mbr;
read $fh, $mbr, 64 or die "Can't read MBR: $!\n";

# Then check that at 510, there's the expected 2 bytes boot signature
# (0x55aa in little endian)
seek $fh, 510, 0 or die "Can't seek to boot signature: $!\n";
my $bootsig;
read $fh, $bootsig, 2 or die "Can't read boot signature: $!\n";

# Close the block device
close $fh or die "Can't close $device: $!\n";

# Show the disk information
my $disksig_le=unpack ("V", pack ("H8", $disksig));
printf "MBR disk id %08x\n", $disksig_le;
if ($nullsig eq "\x00\x00") {
 print "MBR partitions are preceded by 2 null bytes\n";
}
if ($bootsig eq "\x55\xaa") {
 print "MBR partitions are suffixed by boot signature 0x55aa\n";
}

# Parse the MBR partition table into four 16-byte entries
my @partitions = unpack "(a16)4", $mbr;

# Keep a track of what's been explored
my %explored;

#cf https://thestarman.pcministry.com/asm/mbr/PartTables.htm
sub hcs_to_chs {
 my $bin=shift;
 # c and h are 0-based, s is 1-based
 # for (h,c,s)=(1023, 255, 63) as bytes
 #     <FE>,   <FF>   ,<FF>
 # head    ,  sector  ,  cylinder
 # 11111110,  11111111,  11111111
 #            xx <- cut away the first 2 bytes
 #         ,  111111  ,xx11111111 <- add them to cylinder
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

# Loop through each partition entry
for my $i (0 .. 3) {
 # Extract the partition status, type, start sector, and size
 #my ($status, $type, $start, $size) = unpack "C x3 C x3 V V", $partitions[$i];
 # No longer ignoring the 24 bits of each chs fields:
 my ($status, $hcs_a, $hcs_b, $hcs_c, $type, $hcs_x, $hcs_y, $hcs_z, $lba_start, $size) = unpack "C CCC C CCC C V V", $partitions[$i];
 my $hcs_first=pack ("CCC", $hcs_a, $hcs_b, $hcs_c);
 my $hcs_final=pack ("CCC", $hcs_x, $hcs_y, $hcs_z);

 # Pack-Unpack types:
 #cf https://catonmat.net/ftp/perl.pack.unpack.printf.cheat.sheet.pdf
 # A=binary data null padded
 # 1 byte:
 # C=unsigned char 8bit            C       65    -> \x41
 # 2 bytes:
 # H=hex string high nibble first  H4    1234    -> \x12\x34
 # 4 bytes:
 # N=32bit unsigned in big endian  N 12345678    -> \x12\x34\x56\x78
 # V=32bit unsigned in little end  V 12345678    -> \x78\x56\x34\x12

 # Calculate the partition end and the number of sectors
 my $end = $lba_start + $size - 1;
 my $sectors = $size;

 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "Partition #%d: Status: %02x, Type:%02x, Start: %d, End: %d, Size: %d, Sectors: %d\n", $i + 1, $status, $type, $lba_start, $end, $size, $sectors;
 my $dump_i=unpack "H16", $partitions[$i];
 print " Hexdump: $dump_i\n";
 # if multiple partitions are defined to start at the same address, will only explore once
 if ($type == 0) {
  # DON'T skip empty partitions: it may be an isohybrid with a iso9660 filesystem
  # fdisk will say "The device contains 'iso9660' signature and it will be removed by a write command."
  # if so, the first 32kb 0x00-0x0f are the reserved system area:
  # it will contain the boot information (ex: mbr, gpt, apm...)
  # after that, can find volume descriptors starting at 0x10 ie 32768: each is
  # a record of 2048b starting with a type at offset 0 and a length at offset 1
  # can count how many volume descriptors and if they follow the iso structure 
  # not an "empty" partition if many such signatures and type 255 for the last
  #
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
  if ($isodetect >=$i) {
   my $isosig_nbr=0;
   # volume descriptors start at +16, can start again at +32
   my @pluses=(16, 32);
   for my $plus (@pluses) {
    my $lba=$lba_start + $plus;
    # don't explore again the same lba: check the hash
 #   if (exists $explored{$lba}) {
 #    print " (already shown its data at $lba in previous partition #$explored{$lba})\n";
 #   }
 #   print " - checking LBA $lba at LBA_start $lba_start\n";
    unless (defined $explored{$lba}) {
     # mark it as explored
     $explored{$lba}=$i+1;
     my $type=0;
     until ($type > 254) {
      my $offset=$lba*2048;
      seek $fh, $offset, 0 or die "Can't seek to iso signature at LBA $lba: $!\n";
      my $vd;
      read $fh, $vd, 64 or die "Can't read volume: $!\n";
      my $isosig;
      ($type, $isosig)= unpack ("C A5", $vd);
      if ($isosig =~ m/^CD001$/) {
       print "\tbut CD001 at lba: $lba, offset: $offset, type: $type\n";
       $isosig_nbr=$isosig_nbr+1;
      } else {
       # not really, but will serve to break the loop
       $type=256;
      }
      $lba=$lba+1;
     } # until type
    } # unless explored
   } # for my lba_start
   if ($isosig_nbr>2) {
    print ("\tthus not type 00=empty but has an ISO9600\n");
   }
  } # if isodetect
 } # if type 0
 if ($type == 0x05 or $type == 0x0F or $type == 0x85) {
  #cf https://thestarman.pcministry.com/asm/mbr/PartTables2.htm
  print " WARNING: Partition type means extended partitions, not supported yet\n";
 }
 if ($type == 0xee) {
  print " WARNING: Partition type means protective, you should check the GPT partitions\n"
 }
 ## Then the CHS value (stored on disk in weird ways) for LBA detection
 # TODO: support old LBA-22 (max 2G), LBA-28 (max 128G) and historical modes
 #cf https://en.wikipedia.org/wiki/Cylinder-head-sector
 #cf https://en.wikipedia.org/wiki/Logical_block_addressing
 #cf https://wiki.osdev.org/Disk_access_using_the_BIOS_(INT_13h)
 # bitspace needs depend on the number of logical blocks to represent:
 # LBA > 0xFFFFFFF -> LBA-48
 # LBA > 0xFFFFFF  -> LBA-32
 # LBA > 0x3FFFFF  -> LBA-28
 # LBA<= 0x3FFFFF  -> LBA-22
 # For now, only bothering with the LBA modes still used: LBA-32 and LBA-48
 # LBA-32: hcs_first==hcs_last==0xFFFFFF -> lba_start=LBA address in 32 bit 
 # LBA-48: hcs_first==hcs_last==0           lba_start=LBA address in 48 bit
 # Just treating the HCS as magics, 
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
  }
 } else {
  my ($c_first, $h_first, $s_first) = hcs_to_chs($hcs_first);
  my ($c_final, $h_final, $s_final) = hcs_to_chs($hcs_final);
  # bin to hex, should have used sprintf
  my $first = unpack ("H*", $hcs_first);
  my $final = unpack ("H*", $hcs_final);
  print " HCS decoded to (c,h,s): span ($c_first, $h_final, $s_final) =$first to ($c_final, $h_final, $s_final) =$final\n";
 }
} # for i
