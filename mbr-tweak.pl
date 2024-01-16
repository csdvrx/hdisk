#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed
#
## Change MBR partitions to what cosmopolinux prefers:
# - If partition 1 type 0 has CD001 iso signatures, start it at 0
# - Mark partition 2 active if 0xef (EFISP)
# - Type partition 3 as NTFS if 0x83 (Linux)

use strict;
use warnings;
use Data::Dumper;

# Check if a block device name is given as an argument
my $device = shift @ARGV or die "Usage: $0 <block device>\n";

# Option: try to detect ISO9660 CD001 marker? -1 to disable
# with 0, won't detect El Toritos records besides partition 0
my $isodetect=0;

# Open the block device for reading and writing in binary mode
open my $fh, "+<:raw", $device or die "Can't open for read/write $device: $!\n";

# Seek to the MBR location at offset 446
seek $fh, 446, 0 or die "Can't seek to MBR: $!\n";

# Then read the 64 bytes of the MBR
my $mbr;
read $fh, $mbr, 64 or die "Can't read MBR: $!\n";

# Parse the MBR partition table into four 16-byte entries
my @partitions_initial = unpack "(a16)4", $mbr;

# What we want, seeded from what initially is the hash:
my %partitions;

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

print "# INITIAL PARTITIONS:\n";

# Loop through each partition entry
for my $i (0 .. 3) {
 my $dump_i=unpack "H16", $partitions_initial[$i];
 # Extract the partition status, type, start sector, and size
 my ($status, $hcs_a, $hcs_b, $hcs_c, $type, $hcs_x, $hcs_y, $hcs_z, $lba_start, $size) = unpack "C CCC C CCC C V V", $partitions_initial[$i];
 my $hcs_first=pack ("CCC", $hcs_a, $hcs_b, $hcs_c);
 my $hcs_final=pack ("CCC", $hcs_x, $hcs_y, $hcs_z);

 # Calculate the partition end and the number of sectors
 my $lba_final = $lba_start + $size - 1;
 # TODO: yes, this assumes LBA, should improve CHS support
 my $sectors = $size;

 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "Partition %d: Status: %02x, Type: %02x, Start: %d, End: %d, Size: %d, Sectors: %d\n", $i + 1, $status, $type, $lba_start, $lba_final, $size, $sectors;
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
  } # if first or final
 } else {
  my ($c_first, $h_first, $s_first) = hcs_to_chs($hcs_first);
  my ($c_final, $h_final, $s_final) = hcs_to_chs($hcs_final);
  # bin to hex, should have used sprintf
  my $first = unpack ("H*", $hcs_first);
  my $final = unpack ("H*", $hcs_final);
  print " HCS decoded to (c,h,s): span ($c_first, $h_final, $s_final) =$first to ($c_final, $h_final, $s_final) = $final\n";
 } # if elsif

 # Populate the data structure
 $partitions{$i}{status}=$status;
 $partitions{$i}{hcs_first_raw}=$hcs_first;
 $partitions{$i}{type}=$type;
 $partitions{$i}{hcs_final_raw}=$hcs_final;
 $partitions{$i}{start}=$lba_start;
 $partitions{$i}{end}=$lba_final;
 $partitions{$i}{size}=$size;

 # Simple version of ISO detection: hardcoded only a few offsets from well-known LBAs
 my $isosigs;
 if ($isodetect >=$i) {
  if ($type==0) {
   my @offsetsiso=(32769,34817,36865);
   for my $offset (@offsetsiso) {
    seek $fh, $offset, 0 or die "Can't seek to $offset for iso signature: $!\n";
    my $sig;
    read $fh, $sig, 64 or die "Can't read offset $offset: $!\n";
    my $isosig= unpack "A5", $sig;
    print "\tISO signature at $offset: $isosig\n";
    if ($isosig =~ m/^CD001$/) {
     unless (defined($isosigs)) {
      $isosigs=0;
     }
     $isosigs=$isosigs+1;
    } # if
   } # for
   # Keep the number of signatures found somewhere
   $partitions{$i}{isosigs}=$isosigs;
  } # if type 0
 } # if isodetection 

 if (defined($isosigs)) {
  print "\tmaked empty but not really: has $isosigs ISO signatures inside at well-known offsets\n";
 }
} # for

# And show the starting poit
for my $i (0 .. 3) {
 my ($hcs_c, $hcs_b, $hcs_a) = unpack ("CCC", $partitions{$i}{hcs_first_raw});
 my ($hcs_z, $hcs_y, $hcs_x) = unpack ("CCC", $partitions{$i}{hcs_final_raw});
# XXX
# $hcs_a, $hcs_b, $hcs_c,
#  $partitions{$i}{z},
#  $partitions{$i}{hcs_first_raw},
 my $partition_entry= pack 'C CCC C CCC V V', 
  $partitions{$i}{status},
  $hcs_a, $hcs_b, $hcs_c,
  $partitions{$i}{type},
  $hcs_x, $hcs_y, $hcs_z,
  $partitions{$i}{start},
  $partitions{$i}{size};
  my $mbr_i=unpack "H16", $partition_entry;
  print "Initial $i is $mbr_i\n";
}

# Pad the new mbr with zeros as needed to make it 64 bytes:

# Can now overwrite what's been read in %partitions on a as needed basis
print "# TWEAKING PARTITIONS:\n";

# Part 1 starting at 64, even if type 0 could be an issue?
# make it start at 0 if type 0 and contains iso records
# TODO: consider making it stop at -1
if (defined($partitions{0}{isosigs})) {
 if ($partitions{0}{isosigs}>2) {
  if ($partitions{0}{type}==0) {
   print "Making partition 1 start at 0\n";
   $partitions{0}{start}=0;
  }
 }
}
# Mark partition 2 active if EFISP
if ($partitions{1}{type}==0xef) {
 print "Making partition 2 active\n";
 $partitions{1}{status}=0x80;
}
# Type partition 3 as NTFS if linux
if ($partitions{2}{type}==0x83) {
 print "Changing partition 3 type from 0x83 to 0x07\n";
 $partitions{2}{type}=0x07;
}

# Can then pack a new tweaked MBR
my $mbr_tweaked;
# And show the result
for my $i (0 .. 3) {
 my ($hcs_c, $hcs_b, $hcs_a) = unpack ("CCC", $partitions{$i}{hcs_first_raw});
 my ($hcs_z, $hcs_y, $hcs_x) = unpack ("CCC", $partitions{$i}{hcs_final_raw});
 my $partition_entry= pack 'C CCC C CCC V V', 
  $partitions{$i}{status},
  $hcs_a, $hcs_b, $hcs_c,
  $partitions{$i}{type},
  $hcs_x, $hcs_y, $hcs_z,
  $partitions{$i}{start},
  $partitions{$i}{size};
  my $mbr_i=unpack "H16", $partition_entry;
  print "Tweaked $i is $mbr_i\n";
 $mbr_tweaked .= $partition_entry;
}

# Pad the new mbr with zeros as needed to make it 64 bytes:
$mbr_tweaked .= "\x00" x (64 - length $mbr_tweaked);

# Add the mbr signature as the final 2 bytes
$mbr_tweaked .= "\x55\xaa";

print "# WRITING PARTITIONS:\n";

# Return to the MBR offset
seek $fh, 446, 0 or die "Can't seek back to the MBR: $!\n";

# Then can just write the boot code back to the MBR
print $fh $mbr_tweaked or die "Can't write boot code: $!";

# Let's check using the same decoding
print "# CHECKING PARTITIONS:\n";
seek $fh, 446, 0 or die "Can't seek to MBR: $!\n";
read $fh, $mbr, 64 or die "Can't read MBR: $!\n";

# Parse the MBR partition table into four 16-byte entries
my @partitions_fresh = unpack "(a16)4", $mbr;

# Loop through each partition entry
for my $i (0 .. 3) {
 # Extract the partition status, type, start sector, and size
 my ($status, $hcs_a, $hcs_b, $hcs_c, $type, $hcs_x, $hcs_y, $hcs_z, $lba_start, $size) = unpack "C CCC C CCC C V V", $partitions_fresh[$i];
 my $hcs_first=pack ("CCC", $hcs_a, $hcs_b, $hcs_c);
 my $hcs_final=pack ("CCC", $hcs_x, $hcs_y, $hcs_z);

 # Calculate the partition end and the number of sectors
 my $lba_final = $lba_start + $size - 1;
 # TODO: yes, this assumes LBA, should improve CHS support
 my $sectors = $size;


 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "Partition %d: Status: %02x, Type: %02x, Start: %d, End: %d, Size: %d, Sectors: %d\n", $i + 1, $status, $type, $lba_start, $lba_final, $size, $sectors;
 # simple version of ISO detection: hardcoded only a few offsets from well-known LBAs
 my $isosigs;
 if ($isodetect >=$i) {
  if ($type==0) {
   my @offsetsiso=(32769,34817,36865);
   for my $offset (@offsetsiso) {
    seek $fh, $offset, 0 or die "Can't seek to $offset for iso signature: $!\n";
    my $sig;
    read $fh, $sig, 64 or die "Can't read offset $offset: $!\n";
    my $isosig= unpack "A5", $sig;
    print "\tISO signature at $offset: $isosig\n";
    if ($isosig =~ m/^CD001$/) {
     unless (defined($isosigs)) {
      $isosigs=0;
     }
     $isosigs=$isosigs+1;
    } # if
   } # for
  } # if type 0
 } # if isodetection 
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
  } # if first or final
 } else {
  my ($c_first, $h_first, $s_first) = hcs_to_chs($hcs_first);
  my ($c_final, $h_final, $s_final) = hcs_to_chs($hcs_final);
  # bin to hex, should have used sprintf
  my $first = unpack ("H*", $hcs_first);
  my $final = unpack ("H*", $hcs_final);
  print " HCS decoded to (c,h,s): span ($c_first, $h_final, $s_final) =$first to ($c_final, $h_final, $s_final) = $final\n";
 } # if elsif

 if (defined($isosigs)) {
  print "\tmaked empty but not really: has $isosigs ISO signatures inside at well-known offsets\n";
 }
}

# Close the block device
close $fh or die "Can't close $device: $!\n";

