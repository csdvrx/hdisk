#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed

## Dump GPT partitions, carefully check primary and secondary for divergences

use strict;
use warnings;

# CRC32 calculations of the GPT headers and records
use String::CRC32;
use Data::Dumper;

# Option for debug
my $partition_hash_debug=0;

# Hardcoding the GPT header size for revision 0x00010000
my $hardcoded_gpt_header_size=92;

# GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
# but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
sub guid_proper {
 my $input=shift;
 my ($guid1, $guid2, $guid3, $guid4, $guid5) = unpack "H8 H4 H4 H4 H12", $input;
 # reverse the endianness of the first 3 fields
 my $guid1_le=unpack ("V", pack ("H8", $guid1));
 my $guid2_le=unpack ("v", pack ("H4", $guid2));
 my $guid3_le=unpack ("v", pack ("H4", $guid3));
 my $output=sprintf ("%08x-%04x-%04x-%s-%s", $guid1_le, $guid2_le, $guid3_le, $guid4, $guid5);
 return ($output);
}

# Check if a block device name is given as an argument
my $device = shift @ARGV or die "Usage: $0 <block device> <blocksize>\n";
my $bsize;

# Assign a default value to the second argument: block size of 512 bytes
unless ($bsize=shift @ARGV) {
 $bsize=512;
}

# GPT partitions binary attributes
my @gpt_attributes;
#cf https://superuser.com/questions/1771316/
$gpt_attributes[0]="Platform required partition";
$gpt_attributes[1]="EFO ignore the no block IO protocol";
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
$gpt_attributes[60]="Read-only";
$gpt_attributes[61]="Shadow copy";
$gpt_attributes[62]="Hidden";
$gpt_attributes[63]="No automount";

# in general, nick ef00: bit 0+1, nick 0700: bit 60+62+63
# on windows: nick 0c01: bit 0,   nick 2700: bit 0+62

# Annonce that to avoid mistakes
print "# Geometry of $device with a block size $bsize\n";

# Open the block device for reading in binary mode
open my $fh, "<:raw", $device or die "Can't open $device: $!\n";

# Estimate the size
seek $fh, -1, 2 or die "Can't seek to the end: $!\n";
my $offset_end=tell $fh;
my $device_size_G=$offset_end/(1024**3);
my $lba=$offset_end/$bsize;
my $lba_int=int($lba);
printf "Device is about %.2f G, rounded to $lba_int LBA blocks for $lba\n", $device_size_G;

# Check if goes beyond the end of a few usual LBA-bit MBR space:
# 22 bit (original IDE), 28 bit (ATA-1 from 1994), 48 bit (ATA-6 from 2003)
for my $i (28, 32, 48) {
 if ($offset_end > (2**$i) ) {
  # Warn that MBR entries store LBA offsets and sizes as 32 bit little endians
  print "WARNING: this is more than LBA-$i can handle (most MBR use LBA-32)\n";
 }
} # for

# Seek to the GPT header location at offset 512
seek $fh, $bsize, 0 or die "Can't seek to the MAIN GPT header: $!\n";

## Primary GPT header

# Read 92 bytes of GPT header
my $header;
read $fh, $header, $hardcoded_gpt_header_size or die "Can't read MAIN GPT header: $!\n";

# Parse the GPT header into fields
my ($signature, $revision, $header_size, $header_crc32own, $reserved,
 $current_lba, $other_lba, $first_lba, $final_lba, $guid,
 $gptpart_lba, $num_parts, $part_size, $gpt_crc32) = unpack "a8 L L L L Q Q Q Q a16 Q L L L", $header;

# Check the GPT signature and revision
die "Unsupported GPT revision: $revision\n" unless $revision == 0x00010000;

# Print the GPT header information
print "\n";
print "# MAIN GPT header:\n";

# Check the GPT signature and revision
if ($signature eq "EFI PART") {
 printf "Signature (valid): %s\n", $signature;
} else {
 printf "Signature (WARNING: INVALID): %s\n", $signature;
}
if ($revision == 0x00010000) {
 printf "Revision: %08x\n", $revision;
} else {
 printf "Revision (WARNING: UNKNOWN): %08x\n", $revision;
}
printf "Header size (hardcoded $hardcoded_gpt_header_size): %d\n", $header_size;
# Check if the CRC is correct by reproducing its calculation: field zeroed out
#my $header_nocrc32 = substr ($header, 0, 16) . "\x00\x00\x00\x00" . substr ($header, 20);
# But here, reassembles everything from the variables to facilitate tweaks
my $header_nocrc32 = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $signature, $revision, $header_size, ord("\0"), $reserved,
 $current_lba, $other_lba, $first_lba, $final_lba, $guid,
 $gptpart_lba, $num_parts, $part_size, $gpt_crc32);
my $header_crc32check=crc32($header_nocrc32);
if ($header_crc32check == $header_crc32own) { 
 printf "Header CRC32 (valid): %08x\n", $header_crc32own;
} else {
 printf "Header CRC32 (WARNING: INVALID BECAUSED EXPECTED %08x", $header_crc32check;
 printf "): %08x\n", $header_crc32own;
}
printf "Current (main) LBA: %d\n", $current_lba;
printf "Other (backup) LBA: %d\n", $other_lba;
printf "First LBA: %d\n", $first_lba;
printf "Final LBA: %d\n", $final_lba;
#printf "GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $guid;
# GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
# but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
printf "GUID: %s\n", guid_proper($guid);
printf "GPT current (main) LBA: %d\n", $gptpart_lba;
printf "Number of partitions: %d\n", $num_parts;
printf "Partition record size: %d\n", $part_size;
printf "Partitions CRC32 (validity unknown yet):  %08x\n", $gpt_crc32;

## Primary GPT partitions
print "\n";
print "# Main GPT partitions:\n";

# Go to the start LBA offset
my $offset=$gptpart_lba*$bsize;
seek $fh, $offset, 0 or die "Can't seek to the GPT lba $gptpart_lba: $!\n";

# The GPT hould have several partitions of 128 bytes each, but nothing hardcoded
my $gpt;
my $span=$num_parts*$part_size;
read $fh, $gpt, $span or die "Can't read the GPT at $num_parts*$part_size: $!\n";

# Could crc32 what we just read, but unpacking/repacking facilitate tweaks
#if ($gpt_crc32 == crc32($gpt)) {
# printf "Partition CRC32 (valid): %08x\n", $gpt_crc32;
#} else {
# printf "Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($gpt);
# printf "): %08x\n", $gpt_crc32;
#}

# Read the gpt partitions records
my @partitions_records=unpack "(a$part_size)$num_parts", $gpt;

# Then populate a partition hash by unpacking each partition entry
# need to do the partition CRC, but doing a hash will help after for output
my %partitions;
my $i=0;
my $partition_entry_empty="\x00" x $part_size;
for my $partition_entry (@partitions_records) {
 # Unpack each partition entry into fields of the hash
 my ($type_guid, $part_guid, $first_lba, $final_lba, $attr, $name) = unpack "a16 a16 Q Q Q a*", $partition_entry;
 # Skip empty partitions?
 #next if $type_guid eq "\x00" x 16;
 # Don't skip empties as could have the 1st partition be the nth, n!=1
 # Instead, mark as empty
 if ($partition_entry eq $partition_entry_empty) {
  $partitions{$i}{empty}=1;
 } else {
  if ($partition_hash_debug>0) {
   print "Partition $i:\n";
#   printf "Type GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $type_guid;
   printf "Type GUID: %s\n", guid_proper($type_guid);
#   printf "Partition GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $part_guid;
   printf "Partition GUID: %s\n", guid_proper($part_guid);
   printf "First LBA: %d\n", $first_lba;
   printf "Final LBA: %d\n", $final_lba;
   printf "Size: %d\n", $final_lba - $first_lba + 1;
   printf "Sectors: %d\n", $final_lba - $first_lba + 1;
   printf "Attributes: %016x\n", $attr;
   printf "Name: %s\n", $name;
  }
  # Populate the hash
  $partitions{$i}{type_guid}=$type_guid;
  $partitions{$i}{part_guid}=$part_guid;
  $partitions{$i}{first_lba}=$first_lba;
  $partitions{$i}{final_lba}=$final_lba;
  $partitions{$i}{attr}=$attr;
  $partitions{$i}{name}=$name;
 }
 $i=$i+1;
} # for @partitions_records

# (then if partitions need to be tweaked, can be done here)

# reconcatenate the records to redo the gpt
my $gpt_redone;
# but must sort the hash keys numerically (otherwise 0 1 10 100 101 ..)
for my $r ( sort { $a <=> $b } keys %partitions) {
 if ($partition_hash_debug>0) {
  print "got record $r\n";
 }
 # cast to int
 my $c=$r+0;
 my $partition_entry;
 if (defined($partitions{$c}{empty})) {
  if ($partitions{$c}{empty}==1) {
    $partition_entry=$partition_entry_empty;
    if ($partition_hash_debug>0) {
     print "skipped record $r\n";
    }
  }
 } else {
  if ($partition_hash_debug>0) {
   print "packing record $i\n";
  }
  $partition_entry=pack 'a16 a16 Q Q Q a*', 
   $partitions{$c}{type_guid},
   $partitions{$c}{part_guid},
   $partitions{$c}{first_lba},
   $partitions{$c}{final_lba},
   $partitions{$c}{attr},
   $partitions{$c}{name};
 } # if not empty
 # pad by null bytes to the $part_size
 $partition_entry .= "\x00" x ($part_size - length $partition_entry);
 # then append to redo a gpt
 $gpt_redone .= $partition_entry;
} # for my r

# each is 128 bytes,
if ($partition_hash_debug>0) {
 print "partition hash keys:\n";
 print Dumper(scalar(keys(%partitions)));
 print "first 4 entries:\n";
 print Dumper($partitions{0});
 print Dumper($partitions{1});
 print Dumper($partitions{2});
 print Dumper($partitions{3});
 print "reconstituted " . length($gpt_redone) . " bytes \n";
 print Dumper($gpt_redone);
 print "original " . length($gpt) . " bytes \n";
 print Dumper($gpt);
}

if ($gpt_crc32 == crc32($gpt_redone)) {
 printf "Partition CRC32 (valid): %08x\n", $gpt_crc32;
} else {
 printf "Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($gpt);
 printf "): %08x\n", $gpt_crc32;

# # could compare byte by byte
# for my $i (0 .. length ($gpt) - 1) {
#  my $byte1 = substr ($gpt, $i, 1);
#  my $byte2 = substr ($gpt_redone, $i, 1);
#
#  if ($byte1 ne $byte2) {
#   printf "Diff @ %d: %02x vs %02x\n", $i, ord ($byte1), ord ($byte2);
#  }
# }

} # if match redone

# Find the maximal value for non emtpy partition to stop showing past that
my $partitions_max_nonempty;
for my $r ( sort { $a <=> $b } keys %partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 unless (defined($partitions{$c}{empty})) {
  $partitions_max_nonempty=$c;
 } # unless defined
} # for

# No need to loop through each partition entry: show from the hash
for my $r ( sort { $a <=> $b } keys %partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 if (defined($partitions{$c}{empty})) {
  if ($partitions{$c}{empty}==1) {
   if ($c <$partitions_max_nonempty) {
    print "Partition $c: (empty)\n";
   }
  }
 } else {
  my $type_guid=$partitions{$c}{type_guid};
  my $part_guid=$partitions{$c}{part_guid};
  my $first_lba=$partitions{$c}{first_lba};
  my $final_lba=$partitions{$c}{final_lba};
  my $attr= $partitions{$c}{attr};
  my $name=$partitions{$c}{name};
  # Print the partition number and information
  my $sectors=$final_lba - $first_lba + 1;
  my $size = int (($sectors * $bsize)/(1024*1024));
  # Initial format
  #print "Partition $c:\n";
  ##printf "Type GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $type_guid;
  #printf "Type GUID: %s\n", guid_proper($type_guid);
  ##printf "Partition GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $part_guid;
  #printf "Partition GUID: %s\n", guid_proper($part_guid);
  #printf "First LBA: %d\n", $first_lba;
  #printf "Final LBA: %d\n", $final_lba;
  #printf "Size: %d\n", $final_lba - $first_lba + 1;
  #printf "Sectors: %d\n", $final_lba - $first_lba + 1;
  #printf "Attributes: %016x\n", $attr;
  #printf "Name: %s\n", $name;
  # New simpler format
  my $guid_seps=guid_proper($type_guid);
  print "Partition #$c: Start $first_lba, Stops: $final_lba, Sectors: $sectors, Size: $size M\n";
  print "Name: $name, GUID: $guid_seps\n";
  if ($attr>0) {
   print "Attributes bits set: ";
    # loop through the bits of the attributes
    for my $j (0 .. 63) {
     # check if the bit is set
     if ($attr & (1 << $j)) {
      print "$j";
      # give the meaning too
      if (defined($gpt_attributes[$j])) {
       print " ($gpt_attributes[$j])";
      } # if text
      print ",";
     } # if
    } # for
    print "\n";
  } # if attr
 } # else empty
} # for

## Secondary GPT header
# should have $other_lba by the end of the disk:
# LBA      Z-33: last usable sector
# LBA       Z-2:  GPT partition table (backup)
# LBA       Z-1:  GPT header (backup)
# LBA         Z: end of disk
print "\n";

# Use a negative number to go in the other direction, from the end
seek $fh, -1*$bsize, 2 or die "Can't seek to BACKUP header at LBA-2: $!\n";
# Then get the actual position
my $other_offset = tell $fh;
my $other_lba_offset=int($other_offset/$bsize);

# And check if it matches: then $other_lba is by the end of the disk
if ($other_lba == $other_lba_offset) {
 print "# BACKUP GPT header (valid offset for LBA-1 -> $other_offset): $other_lba\n";
} else {
 print "# BACKUP GPT header (WARNING: INVALID OFFSET SINCE LBA-1 -> $other_lba_offset != $other_offset): $other_lba\n";
}

my $backup_header;
read $fh, $backup_header, $hardcoded_gpt_header_size or die "Can't read backup GPT header: $!\n";

# Parse the backup GPT header into fields
my ($backup_signature, $backup_revision, $backup_header_size, $backup_header_crc32own, $backup_reserved,
 $backup_current_lba, $backup_other_lba, $backup_first_lba, $backup_final_lba, $backup_guid,
 $backup_gptpart_lba, $backup_num_parts, $backup_part_size, $backup_gpt_crc32) = unpack "a8 L L L L Q Q Q Q a16 Q L L L", $backup_header;

# Check the GPT signature and revision
# But don't die if the backup is wrong, as it could simply be missing
#die "Unsupported GPT revision: $backup_revision\n" unless $backup_revision == 0x00010000;
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

# Do a quick check if the CRC is ok: reproduce it with own field zeroed out
my $backup_header_nocrc32 = substr ($backup_header, 0, 16) . "\x00\x00\x00\x00" . substr ($backup_header, 20);
my $backup_header_crc32check=crc32($backup_header_nocrc32);
if ($backup_header_crc32check == $backup_header_crc32own) { 
 printf "BACKUP CRC32 (valid): %08x\n", $backup_header_crc32own;
} else {
 printf "BACKUP CRC32 (WARNING: INVALID BECAUSED EXPECTED %08x", $backup_header_crc32check;
 printf "): %08x\n", $backup_header_crc32own;
}
# Then prepare CRC32 if the backup was canonical or primary wasn't primary:
# - as usual, remove own header crc32
# - swap backup_current_lba and backup_other_lba
# - swap gptpart_lba and backup_gptpart_lba
# This allow divergence checks and shows helpful information (hexedit/tweaks)
my $backup_header_nocrc32_if_canonical= pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $backup_signature, $backup_revision, $backup_header_size, ord("\0"), $backup_reserved,
 $backup_other_lba, $backup_current_lba, $backup_first_lba, $backup_final_lba, $backup_guid,
 $gptpart_lba, $backup_num_parts, $backup_part_size, $backup_gpt_crc32);
my $header_nocrc32_if_noncanonical = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $signature, $revision, $header_size, ord("\0"), $reserved,
 $other_lba, $current_lba, $first_lba, $final_lba, $guid,
 $backup_gptpart_lba, $num_parts, $part_size, $gpt_crc32);

# Only show the differences
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
# gptpart_lba from main must diverge from backup_gptpart_lba
printf "BACKUP GPT current (backup) LBA: %d\n", $backup_gptpart_lba;
if ($num_parts != $backup_num_parts) {
 printf "DIVERGENCE: BACKUP Number of partitions: %d\n", $backup_num_parts;
}
if ($part_size != $backup_part_size) {
 printf "DIVERGENCE: BACKUP Partition size: %d\n", $backup_part_size;
}

## Backup GPT partitions
print "\n";
print "# BACKUP GPT partitions:\n";

# Use a negative number to go in the other direction, from the end
seek $fh, -2*$bsize, 2 or die "Can't seek to backup GPT at LBA-2: $!\n";
# Then get the actual position
my $gptbackup_offset = tell $fh;
my $gptbackup_lba_offset=int($gptbackup_offset/$bsize);

# And check if it matches: then $other_lba is by the end of the disk
if ($backup_gptpart_lba == $gptbackup_lba_offset) {
 print "# BACKUP GPT AT (valid offset for LBA-2 -> $gptbackup_offset): $backup_gptpart_lba\n";
} else {
 print "# BACKUP GPT AT (WARNING: UNEXPECTED AT $gptbackup_offset SINCE LBA-2 -> $gptbackup_lba_offset): $backup_gptpart_lba\n";
}

# Go to the start LBA offset
my $backup_offset=$backup_gptpart_lba*$bsize;
seek $fh, $backup_offset, 0 or die "Can't seek to the BACKUP GPT lba $backup_gptpart_lba: $!\n";

# The GPT hould have several partitions of 128 bytes each, but nothing hardcoded
my $backup_gpt;
my $backup_span=$num_parts*$part_size;
read $fh, $backup_gpt, $span or die "Can't read the BACKUP GPT at $backup_num_parts*$backup_part_size: $!\n";

# Could crc32 what we just read, but unpacking/repacking facilitate tweaks
#if ($backup_gpt_crc32 == crc32($backup_gpt)) {
# printf "BACKUP Partition CRC32 (valid): %08x\n", $gpt_crc32;
#} else {
# printf "BACKUP Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($backup_gpt);
# printf "): %08x\n", $backup_gpt_crc32;
#}

# Read the gpt partitions records
my @backup_partitions_records=unpack "(a$backup_part_size)$backup_num_parts", $backup_gpt;

# Then populate a partition hash by unpacking each partition entry
# need to do the partition CRC, but doing a hash will help after for output
my %backup_partitions;
my $j=0;
for my $partition_entry (@backup_partitions_records) {
 # Unpack each partition entry into fields of the hash
 my ($type_guid, $part_guid, $first_lba, $final_lba, $attr, $name) = unpack "a16 a16 Q Q Q a*", $partition_entry;
 # Skip empty partitions?
 #next if $type_guid eq "\x00" x 16;
 # Don't skip empties as could have the 1st partition be the nth, n!=1
 # Instead, mark as empty
 if ($partition_entry eq $partition_entry_empty) {
  $backup_partitions{$j}{empty}=1;
 } else {
  if ($partition_hash_debug>0) {
   print "BACKUP Partition $j:\n";
#   printf "Type GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $type_guid;
   printf "BACKUP Type GUID: %s\n", guid_proper($type_guid);
#   printf "Partition GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $part_guid;
   printf "BACKUP Partition GUID: %s\n", guid_proper($part_guid);
   printf "BACKUP First LBA: %d\n", $first_lba;
   printf "BACKUP Final LBA: %d\n", $final_lba;
   printf "BACKUP Size: %d\n", $final_lba - $first_lba + 1;
   printf "BACKUP Sectors: %d\n", $final_lba - $first_lba + 1;
   printf "BACKUP Attributes: %016x\n", $attr;
   printf "BACKUP Name: %s\n", $name;
  }
  # Populate the hash
  $backup_partitions{$j}{type_guid}=$type_guid;
  $backup_partitions{$j}{part_guid}=$part_guid;
  $backup_partitions{$j}{first_lba}=$first_lba;
  $backup_partitions{$j}{final_lba}=$final_lba;
  $backup_partitions{$j}{attr}=$attr;
  $backup_partitions{$j}{name}=$name;
 }
 $j=$j+1;
} # for @partitions_records

# (then if partitions need to be tweaked, can be done here)

# reconcatenate the records to redo the gpt
my $backup_gpt_redone;
# but must sort the hash keys numerically (otherwise 0 1 10 100 101 ..)
for my $r ( sort { $a <=> $b } keys %backup_partitions) {
 if ($partition_hash_debug>0) {
  print "got record $r\n";
 }
 # cast to int
 my $c=$r+0;
 my $partition_entry;
 if (defined($backup_partitions{$c}{empty})) {
  if ($backup_partitions{$c}{empty}==1) {
    $partition_entry=$partition_entry_empty;
    if ($partition_hash_debug>0) {
     print "skipped record $r\n";
    }
  }
 } else {
  if ($partition_hash_debug>0) {
   print "packing record $c\n";
  }
  $partition_entry=pack 'a16 a16 Q Q Q a*', 
   $backup_partitions{$c}{type_guid},
   $backup_partitions{$c}{part_guid},
   $backup_partitions{$c}{first_lba},
   $backup_partitions{$c}{final_lba},
   $backup_partitions{$c}{attr},
   $backup_partitions{$c}{name};
 } # if not empty
 # pad by null bytes to the $part_size
 $partition_entry .= "\x00" x ($backup_part_size - length $partition_entry);
 # then append to redo a gpt
 $backup_gpt_redone .= $partition_entry;
} # for my r

# each is 128 bytes,
if ($partition_hash_debug>0) {
 print "BACKUP partition hash keys:\n";
 print Dumper(scalar(keys(%backup_partitions)));
 print "first 4 entries:\n";
 print Dumper($backup_partitions{0});
 print Dumper($backup_partitions{1});
 print Dumper($backup_partitions{2});
 print Dumper($backup_partitions{3});
 print "reconstituted " . length($backup_gpt_redone) . " bytes \n";
 print Dumper($backup_gpt_redone);
 print "original " . length($backup_gpt) . " bytes \n";
 print Dumper($backup_gpt);
}

if ($backup_gpt_crc32 == crc32($backup_gpt_redone)) {
 printf "BACKUP Partition CRC32 (valid): %08x\n", $backup_gpt_crc32;
} else {
 printf "BACKUP Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($backup_gpt);
 printf "): %08x\n", $backup_gpt_crc32;

# # could compare byte by byte
# for my $i (0 .. length ($gpt) - 1) {
#  my $byte1 = substr ($gpt, $i, 1);
#  my $byte2 = substr ($gpt_redone, $i, 1);
#
#  if ($byte1 ne $byte2) {
#   printf "Diff @ %d: %02x vs %02x\n", $i, ord ($byte1), ord ($byte2);
#  }
# }

} # if match redone

# Find the maximal value for non emtpy partition to stop showing past that
my $backup_partitions_max_nonempty;
for my $r ( sort { $a <=> $b } keys %partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 unless (defined($partitions{$c}{empty})) {
  $backup_partitions_max_nonempty=$c;
 } # unless defined
} # for

# No need to loop through each partition entry: show from the hash
for my $r ( sort { $a <=> $b } keys %backup_partitions) {
 # Cast to int
 my $c=$r+0;
 my $partition_entry;
 if (defined($backup_partitions{$c}{empty})) {
  # but what if not in main?
  unless (defined($partitions{$c}{empty})) {
     print "DIVERGENCE: BACKUP Partition $c: (empty) while MAIN is NOT empty\n";
  }
  if ($backup_partitions{$c}{empty}==1) {
   if ($c < $backup_partitions_max_nonempty) {
    # only show if there's a difference somewhere:
    if ($backup_partitions{$c}{empty} != $partitions{$c}{empty}) {
     print "DIVERGENCE: BACKUP Partition $c: (empty)\n";
    }
   }
  }
 } else {
  my $type_guid=$backup_partitions{$c}{type_guid};
  my $part_guid=$backup_partitions{$c}{part_guid};
  my $first_lba=$backup_partitions{$c}{first_lba};
  my $final_lba=$backup_partitions{$c}{final_lba};
  my $attr= $backup_partitions{$c}{attr};
  my $name=$backup_partitions{$c}{name};
  my $divergent=0;
  # Detect differences to only show the different entries
  if ($partitions{$c}{type_guid} ne $type_guid
   or $partitions{$c}{part_guid} ne $part_guid
   or $partitions{$c}{first_lba} ne $first_lba
   or $partitions{$c}{final_lba} ne $final_lba
   or $partitions{$c}{attr} ne $attr
   or $partitions{$c}{name} ne $name) {
    $divergent=1;
  }
  
  # Print the partition number and information
  my $sectors=$backup_final_lba - $backup_first_lba + 1;
  my $size = int (($sectors * $bsize)/(1024*1024));
  # Initial format
  #print "BACKUP Partition $c:\n";
  ##printf "BACKUP Type GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $type_guid;
  #printf "BACKUP Type GUID: %s\n", guid_proper($type_guid);
  ##printf "BACKUP Partition GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $part_guid;
  #printf "BACKUP Partition GUID: %s\n", guid_proper($part_guid);
  #printf "BACKUP First LBA: %d\n", $first_lba;
  #printf "BACKUP Final LBA: %d\n", $final_lba;
  #printf "BACKUP Size: %d\n", $final_lba - $first_lba + 1;
  #printf "BACKUP Sectors: %d\n", $final_lba - $first_lba + 1;
  #printf "BACKUP Attributes: %016x\n", $attr;
  #printf "BACKUP Name: %s\n", $name;
  # New simpler format
  if ($divergent>0) {
   print "DIVERGENCE: BACKUP Partition #$c: Start $first_lba, Stops: $final_lba, Sectors: $sectors, Size: $size M\n";
  }
 }
}

# Close the block device as we're done then
close $fh or die "Can't close $device: $!\n";
