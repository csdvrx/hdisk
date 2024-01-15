#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed
#
## Change MBR partitions to what cosmopolinux prefers:
# - If partition 1 type 0 has CD001 iso signatures, start it at 0
# - Mark partition 2 active if 0xef (EFISP)
# - Type partition 3 as NTFS if 0x83 (Linux)

use strict;
use warnings;

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

print "# INITIAL PARTITIONS:\n";

# Loop through each partition entry
for my $i (0 .. 3) {
 # Extract the partition status, type, start sector, and size
 my ($status, $type, $start, $size) = unpack "C x3 C x3 V V", $partitions_initial[$i];

 # DON'T Skip empty partitions
 #next if $type == 0;

 # Calculate the partition end and the number of sectors
 my $end = $start + $size - 1;
 my $sectors = $size;

 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "Partition %d: Status: %02x, Type: %02x, Start: %d, End: %d, Size: %d, Sectors: %d\n", $i + 1, $status, $type, $start, $end, $size, $sectors;

 # Populate the data structure
 $partitions{$i}{status}=$status;
 $partitions{$i}{type}=$type;
 $partitions{$i}{start}=$start;
 $partitions{$i}{end}=$end;
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

# Can now overwrite what's been read in %partitions on a as needed basis
print "# TWEAKING PARTITIONS:\n";

# Part 1 starting at 64, even if type 0 could be an issue?
# make it start at 0 if type 0 and contains iso records
# TODO: consider making it stop at -1
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

# Can then pack a new tweaked MBR
my $mbr_tweaked;
for my $i (0 .. 3) {
 my $partition_entry= pack 'C x3 C x3 V V', 
  $partitions{$i}{status},
  $partitions{$i}{type},
  $partitions{$i}{start},
  $partitions{$i}{size};
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
my @partitions = unpack "(a16)4", $mbr;

# Loop through each partition entry
for my $i (0 .. 3) {
 # Extract the partition status, type, start sector, and size
 my ($status, $type, $start, $size) = unpack "C x3 C x3 V V", $partitions[$i];

 # DON'T Skip empty partitions
 #next if $type == 0;

 # Calculate the partition end and the number of sectors
 my $end = $start + $size - 1;
 my $sectors = $size;

 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "Partition %d: Status: %02x, Type: %02x, Start: %d, End: %d, Size: %d, Sectors: %d\n", $i + 1, $status, $type, $start, $end, $size, $sectors;
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

 if (defined($isosigs)) {
  print "\tmaked empty but not really: has $isosigs ISO signatures inside at well-known offsets\n";
 }
}

# Close the block device
close $fh or die "Can't close $device: $!\n";

