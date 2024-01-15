#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed

## First naive approach for dumping MBR partitions

use strict;
use warnings;

# Check if a block device name is given as an argument
my $device = shift @ARGV or die "Usage: $0 <block device>\n";

# Open the block device for reading in binary mode
open my $fh, "<:raw", $device or die "Can't open $device: $!\n";

# Seek to the MBR location at offset 446
seek $fh, 446, 0 or die "Can't seek to MBR: $!\n";

# Read 64 bytes of MBR partition table
my $mbr;
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

    if (defined($isosigs)) {
     print "\tmaked empty but not really: has $isosigs ISO signatures inside at well-known offsets\n";
    }
}

# Close the block device
close $fh or die "Can't close $device: $!\n";

