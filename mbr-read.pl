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

# Loop through each partition entry
for my $i (0 .. 3) {
 # Extract the partition status, type, start sector, and size
 my ($status, $type, $start, $size) = unpack "C x3 C x3 V V", $partitions[$i];

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
 my $end = $start + $size - 1;
 my $sectors = $size;

 # Print the partition number, status, type, start sector, end sector, size, and number of sectors
 printf "Partition #%d: Status: %02x, Type: %02x, Start: %d, End: %d, Size: %d, Sectors: %d\n", $i + 1, $status, $type, $start, $end, $size, $sectors;
 # if multiple partitions are defined to start at the same address, will only explore once
 if ($type == 0) {
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
   # volume descriptors start at LBA 16, can start again at LBA 32
   my @lbas_start=(16, 32);
   for my $lba_start (@lbas_start) {
    my $lba=$lba_start + $start;
    # don't explore again the same lba: check the hash
 #   if (exists $explored{$lba}) {
 #    print " (already shown its data at $lba in previous partition #$explored{$lba})\n";
 #   }
 #   print " - checking LBA start $lba_start at partition start $start\n";
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
} # for i
