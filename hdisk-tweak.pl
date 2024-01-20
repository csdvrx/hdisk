#!/usr/bin/perl
# Copyright (C) 2024, csdvrx, MIT licensed
#
## hdisk, a programmatic perl partition manager using just core perl
#
use strict;
use warnings;
use Data::Dumper;  # Dirty debug
use String::CRC32; # CRC32 calculations of the GPT headers and records

## Reads a given path and optional block size given to get:
# - the geometry of the block device disk or the file image
# - MBR headers
# - *BUT* then check for GPT headers, to correct the block size if forgotten
# - MBR partitions (checks for potential ISO signatures)
# - GPT partitions (checks the CRC32, and that backups are correct)
# - GPT backup header and GPT backup partitions (also checks CRC32)
#
## While getting information, displays what was read and if it's valid
#
## Then allows a prescriptive partition layout and if-this-then-that logic to:
# - change any information of the existing MBR or GPT partitions
# - create new partitions using the information available to decide how & what
# - fine control offered: can decide to keep MBR and GPT parts in sync, or not
#
## Finally, applies the changes to the disk:
# - before, checks if the variables allow this change, then if writing needed
# - applies the dependencies (ex: new GPT partition -> new CRC32 -> headers)
# - then tries to apply the change by writing to disk
# - if failing, says what should have been written, to hexedit as needed

########################################################### VARIABLES

## Options
# FIXME: Deny all write operations until the script is ready
my $mbr_write_denial=1;
# The GPT is finer grained
my $gptheader_write_denial=1;
my $gptheader_backup_write_denial=1;
my $gptpartst_write_denial=1;
my $gptpartst_backup_write_denial=1;
# Justify the assignments of the types in the hashes
my $justify=0;
# Only print the partitions, nothing about the MBR or GPT headers
my $noheaders=0;
# And don't talk about the device size
my $nodevinfo=0;
# Or look for ISO signatures (while you really should...)
my $noisodetect=0;
# Can also debug the ISO signatures detection in partitions declared as empty
my $debug_isodetect=0;

## Hardcoded sizes
# Block size default (that'll be guessed from EFI headers if wrong)
my $hardcoded_default_block_size=512;
# ISO sizes
my $hardcoded_isovold_size=64;
# GPT sizes
my $hardcoded_gpt_header_size=92;
my $hardcoded_gpt_partname_size=32;
# MBR sizes
my $hardcoded_mbr_bootcode_size=440;
my $hardcoded_mbr_signature_size=6;
my $hardcoded_mbr_bootsig_size=2;
my $hardcoded_mbr_size=64;

## Global variables tracking states, due to missing/inaccessible or tweaks
# They are answers the question "Do we have to update this?" with this being:
# - the mbr: very simple, just one variable
my $mbr_write_needed=0;
# - the GPT: more complex due to dependencies between the 4 entities:
#  - Main (primary) : 1/4 gptheader 2/4 gptpartst: both with crc32
my $gptheader_write_needed=0;
my $gptpartst_write_needed=0;
#  - Backup : 3/4 gptheader_backup 4/4 gptpartst_backup: crc32 too
my $gptheader_backup_write_needed=0;
my $gptpartst_backup_write_needed=0;
# GPT: has CRC of self+parts inside headers, so rewrite needed when tweaking:
# - lbas of disk geometry (ex: when imaged, doesn't match on disk reality)
# - lbas of backup header (imaged: same issue: listed inside main header too)
# - parts: also need to write new parts table, and new backup for both
# - backup header: because must match main, yet with its own crc32
# Can workaround the CRC32 check with dangerous fixes
my $dangerous_fixes=0;

## Partition images can cause limits to arise:
# What if we only have the beginning of a disk, say as a partition backup?
# What can be done depends on how much we have:
# - if we only have 512b, that's just the MBR
# - if we have 92b more, we may get the GPT main header if bsize=512
# - if we have 4k total but bsize=4k, we won't have even the GPT header
# - if we have 2k total but bsize=512, we have some of the GPT tables:
# partst contains 128 entries of 128b each so 16k so usually up to LBA-33:
#  - if bsize=512: (512+512+128*128)/512=34 : first usable sector @LBA-34
#  - if bsize=4k=2^12: (2^12+2^12+128*128)/2^12=6 : first usable @LBA-6
# WONTFIX: here, assume a minimal size of 512b to create at least a MBR
# therefore, no $mbr_header_inaccessible or $mbr_partst_inaccessible
# But that's just the minimum, we also need the disk image to be:
# In practice, these rarely absent and therefore inacessible:
my $mbr_isosig_inaccessible=0;
my $gpt_header_inaccessible=0;
my $gpt_partst_inaccessible=0;
# In practice, if we have just the beginning, won't have one or both of:
my $gpt_header_backup_inaccessible=0;
my $gpt_partst_backup_inaccessible=0;
# Because the backup GPT header is at LBA-1, needs to be at least:
# (2*bsize)+128^2+bsize: LBA0 for the MBR, LBA1 for the GPT
# can then have 128^2 for the GPT table, then the header backup so:
#  - 3*bsize+128*128 to have a gpt backup header (and no actual data!)
#  - 3*bsize+2*(128*128) to have both gpt backups (yet no actual data!)
# What will be missing depends on the size:
# - The first to be missing will be the gpt table backup:
# Can use a dangerous trick: say in the gpt backup header gptparts lba= main's
# This means removing GPT redundancy + hiding it away by recomputing the crc32
# - If even gpt header is missing, could tweak main with other_lba=current_lba
# Should *NOT* do any of this, but might fix small backups of part table from:
#  dd if=/dev/something of=backup bs=first_usable_lba*bsize count=1

## Make a few hashes for the GPT well known GUID and textual labels:
# - for the description and conversion of the GUID
my %guid_to_nick;
my %nick_to_guid;
# - for a verbose description of the GUID and nick
my %guid_to_text;
my %nick_to_text;
# - abd in case the mbr and gpt description differs
my %nick_to_mbrtext;
## Declare GPT partitions binary attributes in a simpler manner: just an array
my @gpt_attributes;

########################################################### MBR SUBFUNCTIONS

## MBR CHS decoding from the 3 bytes read on disk
sub mbr_hcs_to_chs {
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
 # Byte 1: h bits 7,6,5,4,3,2,1,0
 # h value stored in the upper 6 bits of the first byte?
 #my $h = $c2 >> 2;
 my $h = $x1;
 # Byte 2: c bits 9,8 then s bits 5,4,3,2,1
 # Byte 3: c bits 7,6,5,4,3,2,1,0
 # ie c value stored in the lower 10 bits of the last two bytes
 my $c = (($x2 & 0b11) << 8) | $x3;
 # s value stored in the lower 6 bits of the second byte
 my $s = $x2 & 0b00111111;
 return ($c, $h, $s);
}

## Read a MBR header from a fh and a geometry
sub mbr_read_header {
 my ($fh, $geometry_ref)=@_;
 my %geometry=%{ $geometry_ref };
 # outputs
 my $textinfo="";
 my %mbr_header;
 # make sure the size is > 440 to read the bootcode
 if ($geometry{end} > $hardcoded_mbr_bootcode_size) {
  if ($noheaders <1) {
   print "\n# READING MBR HEADER:\n";
  }
  # Read the bootcode: not just for showing it but to know if bootable
  my $mbrbootcode;
  read $fh, $mbrbootcode, $hardcoded_mbr_bootcode_size, 0;
  if ($mbrbootcode=~ m/^\0*$/) {
   $textinfo=$textinfo . "Note: MBR bootcode empty, must be a GPT system\n";
  } elsif ($mbrbootcode=~ m/^\x7b\0*$/) {
   $textinfo=$textinfo . "Note: MBR bootcode 7b, disk non bootable\n";
  } else {
   my $mbrbootcode_pack=unpack "H$hardcoded_mbr_bootcode_size", $mbrbootcode;
   $textinfo=$textinfo . "Bootcode dump: $mbrbootcode_pack\n";
  }
  $mbr_header{bootmbr}=$mbrbootcode;
 } # if > 440
 # make sure the size is > 446 to read the signatures
 if ($geometry{end} > $hardcoded_mbr_bootcode_size+$hardcoded_mbr_signature_size) {
  # Seek to 440 (near the MBR end at offset 446)
  seek $fh, $hardcoded_mbr_bootcode_size, 0 or die "Can't seek to offset 440 near the end of the MBR: $!\n";
  my $mbrsigs;
  read $fh, $mbrsigs, $hardcoded_mbr_signature_size or die "Can't read the MBR signatures: $!\n";
  # at 440 there are 4 bytes for the disk number (signature)
  # at 444 there should be 2 null bytes that have been historically reserved
  my ($disksig, $nullsig) = unpack 'H8a2', $mbrsigs;
  # Then check that at 510, there's the expected 2 bytes boot signature
  my $mbr_bootsig_offset=$hardcoded_mbr_bootcode_size + $hardcoded_mbr_signature_size + $hardcoded_mbr_size;
  seek $fh, $mbr_bootsig_offset, 0 or die "Can't seek to MBR boot signature: $!\n";
  my $bootsig;
  read $fh, $bootsig, $hardcoded_mbr_bootsig_size or die "Can't read MBR boot signature: $!\n";
  my $bootsig_le=unpack ("H4", $bootsig);
  my $disksig_le=unpack ("V", pack ("H8", $disksig));
  # Show the MBR headers
  $textinfo=$textinfo . sprintf "Disk UUID: %08x\n", $disksig_le;
  # Should be 0x55aa in little endian
  if ($bootsig eq "\x55\xaa") {
  $textinfo=$textinfo . "Signature (valid): $bootsig_le\n";
  } else {
   $textinfo=$textinfo . "Signature (WARNING: INVALID): $bootsig_le\n";
  }
  # Could have other uses, but in practice never not null
  if ($nullsig eq "\x00\x00") {
   $textinfo=$textinfo . "2 null bytes (valid): $nullsig(obviously not visible)\n";
  } else {
   $textinfo=$textinfo . print "2 null bytes (WARNING: NOT NULL): $nullsig\n";
  }
  # Populate the mbr header hash
  $mbr_header{bootsig}=$bootsig_le;
  $mbr_header{disksig}=$disksig_le;
  $mbr_header{nullsig}=$nullsig;
 } # if > 446
 return ($textinfo, \%mbr_header)
} # sub

########################################################### GPT SUBFUNCTIONS

## GPT attributes from bits to a hash of set bits + text
sub gpt_attributes_decode {
 my $attrs=shift;
 my %setb;
 my $text;
 # loop through the bits of the attributes
 for my $b (0 .. 63) {
  # check if the bit is set
  if ($attrs & (1 << $b)) {
   $setb{$b}=1;
   $text = $text . "$b";
   # give the meaning too
   if (defined($gpt_attributes[$b])) {
    $text = $text . " ($gpt_attributes[$b])";
   } # if text
   $text = $text . ", ";
  } # if bit
 } # for
 return ($text, %setb);
} # sub

## GPT attributes from a binary value and a hash to bits
sub gpt_attributes_encode {
 my $value=shift;
 my %attrs=shift;
 my @low;
 my @high;
 foreach my $bit ( sort { $a <=> $b } keys %attrs) {
  if ($attrs{$bit}==0) {
    # create a mask that has a 0 at the given position and 1s elsewhere
    my $mask = ~(1 << $bit);
    # use bitwise and to clear the bit at the given position
    $value &= $mask;
  }
  if ($attrs{$bit}==1) {
    # create a mask that has a 1 at the given position and 0s elsewhere
    my $mask = (1 << $bit);
    # use bitwise or to clear the bit at the given position
    $value |= $mask;
  }
 }
 return ($value);
}

## GPT GUID: recode what was read as an a16:
# - the 1st field is 8 bytes long and is big-endian,
# - the 2nd and 3rd fields are 2 and 4 bytes long and are big-endian,
# - but the 4th and 5th fields are 4 and 12 bytes long and are little-endian
sub gpt_guid_decode {
 my $input=shift;
 my ($guid1, $guid2, $guid3, $guid4, $guid5)=unpack "H8 H4 H4 H4 H12", $input;
 # Reverse the endianness of the first 3 fields
 my $guid1_le=unpack ("V", pack ("H8", $guid1));
 my $guid2_le=unpack ("v", pack ("H4", $guid2));
 my $guid3_le=unpack ("v", pack ("H4", $guid3));
 my $output=sprintf ("%08x-%04x-%04x-%s-%s", $guid1_le, $guid2_le, $guid3_le,
  $guid4, $guid5);
 # Use upper case for the returns
 return (uc($output));
}

## Perform the same operation but in the other way to get lowercase hex ascii
sub gpt_guid_encode {
 my $input=shift;
 my @five_parts=split("-", $input);
 # Reverse the endianness of the first 3 fields
 my $part1_be=unpack ("V", pack ("H8", $five_parts[0]));
 my $part2_be=unpack ("v", pack ("H4", $five_parts[1]));
 my $part3_be=unpack ("v", pack ("H4", $five_parts[2]));
 my $output=sprintf ("%08x%04x%04x%s%s", $part1_be, $part2_be, $part3_be,
  $five_parts[3], $five_parts[4]);
 return (lc($output));
}

# Names are just as strange: due to UTF16-LE, null bytes between ascii
sub gpt_name_decode {
 my $input=shift;
 my $output = $input;
 # Remove the null bytes
 $output=~tr/\0//d;
 return ($output);
}

# Add back the null bytes and pad with more to the expected record size
sub gpt_name_encode {
 my $input=shift;
 my $output = "";
 for my $char (split //, $input) {
    $output .= $char . "\0";
  }
 $output .= "\x00" x ($hardcoded_gpt_partname_size - length $output);
 return $output;
}


########################################################### OTHER SUBFUNCTIONS

# Read the geometry of a file handler with a specific block size
sub read_geometry {
 # Inputs: filehander and bsize
 my $fh=shift;
 my $bsize=shift;
 # Outputs: geometry hash and textual information
 my %geometry;
 my $textinfo="";
 # Size estimate: seek (,,whence): whence=2 to EOF, 0 to start, 1 to curpos
 seek $fh, -1, 2 or die "Can't seek to the end: $!\n";
 my $offset_end=tell $fh;
 # compensate the -1 by a +1:
 $geometry{end}=$offset_end+1;
 my $device_size_G=($offset_end+1)/(1024**3);
 $geometry{sizeG}=$device_size_G;
 $geometry{block_size}=$bsize;
 my $lba=($offset_end+1)/$bsize;
 $geometry{lba}=$lba;
 my $lba_int=int($lba);
 $textinfo = sprintf "Size %.2f G, $lba rounds to total LBA: $lba_int\n", $device_size_G;

 # Check if goes beyond the end of a few usual LBA-bit MBR space:
 # 22 bit (original IDE): not needed
 # 28 bit (ATA-1 from 1994), 32 bit (MBRs), 48 bit (ATA-6 from 2003): helps
 for my $i (28, 32, 48) {
  if ($offset_end > (2**$i) ) {
   # Warn that MBR entries store LBA offsets and sizes as 32 bit little endians
   $textinfo = $textinfo. "WARNING: this is more than LBA-$i can handle (many MBR use LBA-32)\n";
  } # if
 } # for my i
 return ($textinfo, \%geometry);
} # sub

## Look for El Torito signatures
sub isodetect {
 # Inputs: a fh, a starting point, and a list of offset to ignore
 my ($fh, $start, $already_explored_ref)=@_;

 # Outputs: some information, and a hash of offsets
 my $textinfo="";
 my %isosigs;
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
 my $isosig_nbr=0;
 # Volume descriptors start at LBA X+16, seems it can start again at LBA X+32
 # So should check at different LBAs:
 #  - from the beginning of the drive: X=0, LBA=X+vd_lba_start
 #  - from the beginning of the partition: X=start, LBA=X+vd_lba_start
 for my $begin (0, $start) {
  my @vd_lbas_starts=(0, 16, 32);
  for my $vd_start (@vd_lbas_starts) {
   # So add this vd_lba_start
   my $lba=$begin + $vd_start;
   # But don't explore again the same lba: check the hash
   if ($debug_isodetect>0) {
    if (defined $already_explored_ref->{$lba}) {
     $textinfo = $textinfo . " (already explored $lba)\n";
    }
    $textinfo = $textinfo . " - checking LBA $lba for volume descriptor start $vd_start at start $start\n";
   } # if debug
   unless (defined $already_explored_ref->{$lba}) {
    # Mark it as explored
    $already_explored_ref->{$lba}=1;
    my $type=0;
    until ($type > 254) {
     my $offset=$lba*2048;
     my $vd;
     seek $fh, $offset, 0 or $mbr_isosig_inaccessible=1;
     if ($mbr_isosig_inaccessible==1) {
      $textinfo = $textinfo . "Can't seek to iso signature at LBA $lba: $!\n";
      # Not really true, but it will serve to break the loop: >254
      $vd=pack("C A5", 0xff, "    ");
     }
     read $fh, $vd, $hardcoded_isovold_size or $mbr_isosig_inaccessible=2;
     if ($mbr_isosig_inaccessible==2) {
      if ($debug_isodetect>1) {
       $textinfo = $textinfo . "Can't read 64 bytes of volume descriptor at LBA $lba: $!\n";
      }
      # Not really, but it will serve to break the loop: >254
      $vd=pack("C A5", 255, "    ");
     }
     my $isosig;
     ($type, $isosig)= unpack ("C A5", $vd);
     if ($isosig =~ m/^CD001$/) {
      $textinfo = $textinfo . "\tseen CD001 at lba: $lba, offset: $offset, type: $type\n";
      $isosig_nbr=$isosig_nbr+1;
      # we found something!
      $isosigs{$lba}=$type;
     } else {
      # Not really, but it will serve to break the loop
      $type=256;
     }
     $lba=$lba+1;
    } # until type
   } # unless already_explored_ref
  } # for my vd_start
 } # for my begin
 if ($isosig_nbr>2) {
  $textinfo = $textinfo . "\tthus not type 00=empty but has an ISO9600 filesystem\n";
 }
 # Populate the nbr field of the return hash
 $isosigs{nbr}=$isosig_nbr;
 return ($textinfo, \%isosigs, $already_explored_ref);
}

# Compare byte-by-byte to help debugging such null bytes or endianness issues
sub compare_two_strings {
 my $a=shift;
 my $b=shift;
 my $chunk=shift;
 if (defined($chunk)) {
 # TODO: optional 3rd parameter: to split each into sized chunks and show like
 # my @aa=unpack("(A$chunk)*", $a);
 # my @bb=unpack("(A$chunk)*", $b);
 # my $c=0;
 # foreach my $aaa (@@) {
 #  my $aaa_len=length($aaa);
 #  my $bbb_len=length($bbb);
 #  my $aaa_txt=unpack "H$chunk", $aaa;
 #  my $bbb_txt=unpack "H$chunk", $bbb;
 #  print "old chunk #$c: $aaa_txt\n";
 #  print "new chunk #$c: $bbb_txt\n";
 #  ..
 #  $c=$c+1;
 #  }
 } else {
  for my $p (0 .. length ($a) - 1) {
   my $byte1 = substr ($a, $p, 1);
   my $byte2 = substr ($b, $p, 1);

  if ($byte1 ne $byte2) {
     printf "DIFF @ %d: %02x vs %02x\n", $p, ord ($byte1), ord ($byte2);
#   } else {
#    printf "same @ %d: %02x vs %02x\n", $p, ord ($byte1), ord ($byte2);
   } # if ne
  } # for p
 } # else chuck
} # sub

# Ugly af but allows reusing gdisk declarations of facts with minimal changes
sub add_type {
 my $nick = shift;
 my $guid = shift;
 my $text = shift;
 # Optional:
 my $nick_wins= shift;
 my $mbr_text;
 # This is unconditional: nicks map nicely to mbr text and guid (the first 2 columns)
 if ($justify >0) {
  print "0a. Unconditionally defining $nick to $guid\n";
 }
 $nick_to_guid{$nick}=$guid;
 # Can't assign mbr_text yet: optional, and only available later
 if (defined ($nick_wins)) {
  # If defined:
  #  - specific text for describing mbr nick
  #  (otherwise collapsing to the same guid)
  #  - need to check which one wins as the default
  $mbr_text = shift;
 } else {
  # if not defined:
  #  - text applies both to gpt and mbr
  $mbr_text = $text;
 } # if defined nick wins
 # Optional: if not defined, text=both gpt_text and mbr_text
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
 } else { # nickwins
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
 } # else nickwins
 # mbr_text may now be available
 if (defined($mbr_text)) {
  $nick_to_mbrtext{$nick}=$mbr_text;
  if ($justify >0) {
   print "0b. Unconditionally defining $nick to $guid and $mbr_text since available\n";
  }
 } # if mbr_text
} # sub addtype

########################################################### DECLARE SOME FACTS

# Exhaustive table of facts matching more or less gptdisk format by Rod Smith:
# The nick type is the MBR type *100, which is shorter to type that a GUID
# There are only so many well-known GUID: nicks are easier to show and enter
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

#cf https://superuser.com/questions/1771316/
$gpt_attributes[0]="Platform required partition";
$gpt_attributes[1]="EFI please ignore this, no block IO protocol";
$gpt_attributes[2]="Legacy BIOS bootable";
#3-47 are reserved, the rest are OS dependant
#cf https://en.wikipedia.org/wiki/GUID_Partition_Table
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

########################################################### ASSERTIONS & TESTS

# Simple assertion to be able to detect LBA / non LBA
# LBA is indicated by setting the max values ie 1023, 254, 63:
# stands for the 1024th cylinder, 255th head and 63rd sector
# because cylinder and head counts begin at zero.
# on disk as three bytes: FE FF FF in that order because little endian
# 111111101111111111111111 ie <FE><FF><FF> for (c,h,s)=(1023, 255, 63)
# show that as a hex string and with packing
for my $bin ("\xFE\xFF\xFF", pack("H*", "FEFFFF")) {
 my ($c_lba, $h_lba, $s_lba)=mbr_hcs_to_chs($bin);
 unless ($c_lba==1023 and $h_lba==254 and $s_lba==63) {
  print "LBA detection assertion failed with $bin";
  print "<FE><FF><FF> little endian does not give c,h,s=1023,254,63\n";
  die;
 } # unless
} # for

# Simple assertions to check the hashes are correct, tests both 0700 and ef00:
# ef00: 28732ac11ff8d211ba4b00a0c93ec93b/C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# 0700: a2a0d0ebe5b9334487c068b6b72699c7/EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
# Example:
# - on disk 28732ac11ff8d211ba4b00a0c93ec93b
# - ie like 28732ac1-1ff8-d211-ba4b-00a0c93ec93b
# - must do C12A7328-F81F-11D2-BA4B-00A0C93EC93B:
# - then give it back, through H32 because was read as a16

my $check_endian_encode_ef00=gpt_guid_encode($nick_to_guid{"ef00"});
unless ($check_endian_encode_ef00=~m/28732ac11ff8d211ba4b00a0c93ec93b/) {
 print "Failed assertion: nick ef00 should be encoded on disk from 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' through '28732ac1-1ff8-d211-ba4b-00a0c93ec93b' to ultimately '28732ac11ff8d211ba4b00a0c93ec93b'\n";
 print "Instead, is $check_endian_encode_ef00\n";
 die;
}

# Also use pack to simulates what's read from the disk and visible in hexedit
my $check_endian_decode_ef00=gpt_guid_decode(pack ("H32", $check_endian_encode_ef00));
unless ($check_endian_decode_ef00=~m/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/) {
 print "Failed assertion: nick ef00 should be decoded from '28732ac11ff8d211ba4b00a0c93ec93b' to 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'\n";
 print "Instead, is $check_endian_decode_ef00\n";
 die;
}

# And don't assume the gpt_guid_encode() results are correct: check by packing
$check_endian_decode_ef00=gpt_guid_decode(pack ("H32", "28732ac11ff8d211ba4b00a0c93ec93b"));
unless ($check_endian_decode_ef00=~m/C12A7328-F81F-11D2-BA4B-00A0C93EC93B/) {
 print "Failed assertion: nick ef00 should be decoded from '28732ac11ff8d211ba4b00a0c93ec93b' to 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'\n";
 print "Instead, is $check_endian_decode_ef00\n";
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

# Then 0700
my $check_endian_encode_0700=gpt_guid_encode("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
unless ($check_endian_encode_0700=~m/a2a0d0ebe5b9334487c068b6b72699c7/) {
 print "Failed assertion: nick 0700 should be encoded on disk from 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7' like 'a2a0d0eb-e5b9-3344-87c0-68b6b72699c7' into 'a2a0d0ebe5b9334487c068b6b72699c7'\n";
 print "Instead, is $check_endian_encode_0700\n";
 die;
}

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

# Tests on "0700" could show problems withs nicks being interpreted as numbers
my $check_0700_guid= $nick_to_guid{"0700"};
unless ($check_0700_guid=~m/EBD0A0A2-B9E5-4433-87C0-68B6B72699C7/) {
 print "Failed assertion: nick 0700 should be 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'\n";
 print "Instead, is $check_0700_guid\n";
 die;
}

# Test on 0700 which will be read as 700
my $check_700_guid = $nick_to_guid{0700};
if (defined($check_700_guid)) {
 print "Failed assertion: nick 700 should be unassigned\n";
 print "Instead, is $check_700_guid\n";
}

########################################################### ACTUAL BEGINNING

## Need at minimum a path to a device (but can also work with files)
my $path = shift @ARGV or die "Usage: $0 <block device> [<blocksize>]\n";
my $bsize;
unless ($bsize=shift @ARGV) {
 # Assign a default value to the second argument
 $bsize=$hardcoded_default_block_size;
}

########################################################### READ GEOMETRY

if ($nodevinfo <1) {
 print "# DEVICE:\n";
}

if ($nodevinfo <1) {
 print "Checking $path with a LBA block size $bsize\n";
 print "WARNING: block size important for GPT at LBA1, irrelevant for MBR at LBA0\n";
}

# Open the block device for reading in binary mode
open my $fh, "<:raw", $path or die "Can't open $path: $!\n";

## Device or image information like size and LBA blocks
my ($infos_geom, $geometry_ref)= read_geometry($fh, $bsize);
my %geometry = %{ $geometry_ref };

if ($nodevinfo <1) {
 print $infos_geom;
}

# Only two properties + bootable, but might as well use a hash everywhere
my ($infos_mbrh, $mbr_header_ref) = mbr_read_header($fh, \%geometry);
my %mbr_header = %{ $mbr_header_ref };

if ($noheaders <1) {
 print $infos_mbrh;
}

########################################################### READ GPT HEADER

## Then GPT header before MBR partitions: might correct bsize for isodetect
# https://wiki.osdev.org/El-Torito#Hybrid_Setup_for_BIOS_and_EFI_from_CD.2FDVD_and_USB_stick:
# Several distributions offer a layout that does not comply to either of the UEFI alternatives.
# The MBR marks the whole ISO by a partition of type 0x00.
# Another MBR partition of type 0xef marks a data file inside the ISO
# with the image of the EFI System Partition FAT filesystem.
# Nevertheless there is a GPT which also marks the EFI System Partition image file.
# This GPT is to be ignored by any UEFI compliant firmware.
# The nesting is made acceptable by giving the outer MBR partition the type 0x00
# UEFI specifies to ignore MBR partitions 0x00"

# Keep in a hash for easy tweaks
my %gptheader_main;
# Will only be populated if there's something to read:
# - if we have 92b more, we may get the GPT main header if bsize=512
# - if we have 4k total but bsize=4k, we won't have even the GPT header
# - if we have 2k total but bsize=512, we'll have part of the GPT tables:
unless ($geometry{end} > $geometry{block_size}+$hardcoded_gpt_header_size) {
 if ($noheaders <1) {
  print "\n# WARNING: too small to have a GPT primary header or partitions\n";
 }
 $gpt_header_inaccessible=1;
 $gpt_partst_inaccessible=1;
} else {
  # Reads the gptheader in a string called gptheader to remember _backup exists
  my $gptheader;
  if ($noheaders <1) {
   print "\n# READING GPT HEADER:\n";
  }
  # Seek to the GPT header location at LBA1 ie 1*(block size)
  seek $fh, $geometry{block_size}, 0 or die "Can't seek to the MAIN GPT header: $!\n";
  # Read 92 bytes of GPT header
  read $fh, $gptheader, $hardcoded_gpt_header_size or die "Can't read MAIN GPT header: $!\n";

 # Parse the GPT header into fields
 my ($signature, $revision, $header_size, $header_crc32own, $reserved,
  $current_lba, $other_lba, $first_lba, $final_lba, $disk_guid,
  $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own) = unpack "a8 L L L L Q Q Q Q a16 Q L L L",
  $gptheader;

 # Check the GPT signature and revision
 if ($signature eq "EFI PART") {
  if ($noheaders <1) {
   printf "Signature (valid): %s\n", $signature;
  }
 } else {
  if ($noheaders <1) {
   printf "Signature (WARNING: INVALID): %s\n", $signature;
   printf "WARNING: MAIN GPT flushed\n";
  }
  ($signature, $revision, $header_size, $header_crc32own, $reserved,
   $current_lba, $other_lba, $first_lba, $final_lba, $disk_guid,
   $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own)
   = (0, 0, 0, 0, 0,
      0, 0, 0, 0 ,0,
      0, 0, 0, 0);
  $gpt_header_inaccessible=1;
  # This should NOT happen, so try again after changing bsize
  if ($noheaders <1) {
   print "WARNING: Trying again after setting bsize=";
  }
  for my $try_bsize (512, 2048, 4096) {
   if ($noheaders <1) {
    print "$try_bsize,";
   }
   seek $fh, $try_bsize, 0 or die "Can't seek to the MAIN GPT header: $!\n";
   # Read 92 bytes of GPT header
   read $fh, $gptheader, $hardcoded_gpt_header_size or die "Can't read MAIN GPT header: $!\n";
   # Reparse the GPT header into fields
   ($signature, $revision, $header_size, $header_crc32own, $reserved,
    $current_lba, $other_lba, $first_lba, $final_lba, $disk_guid,
    $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own) = unpack "a8 L L L L Q Q Q Q a16 Q L L L",
   $gptheader;
   if ($signature eq "EFI PART") {
    if ($noheaders <1) {
     printf " and this worked.\n";
    }
    $gpt_header_inaccessible=0;
    # noheaders or not, if the wrong information was given, say something
    printf "WARNING: Was given wrong paramer, now using bsize=$try_bsize\n";
    printf "Signature (valid): %s\n", $signature;
    # Update the LBA and block size in the device hash
    ($infos_geom, %geometry)= read_geometry($fh, $try_bsize);
    if ($nodevinfo <1) {
     print $infos_geom;
    }

   } # if signature 2nd attempt
  } # for try_bsize
 } # else signature

 unless ($signature eq "EFI PART") {
  ($signature, $revision, $header_size, $header_crc32own, $reserved,
   $current_lba, $other_lba, $first_lba, $final_lba, $disk_guid,
   $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own)
   = (0, 0, 0, 0, 0,
     0, 0, 0, 0 ,0,
     0, 0, 0, 0);
   $gpt_header_inaccessible=1;
   print "WARNING: GPT header absent, may need one, using zeroes for now\n";
   $gptheader_write_needed=1;
 }

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
  $current_lba, $other_lba, $first_lba, $final_lba, $disk_guid,
  $gptparts_lba, $num_parts, $part_size, $gptparts_crc32own);
 my $header_crc32check=crc32($header_nocrc32);
 if ($noheaders <1) {
  if ($header_crc32check == $header_crc32own) {
   printf "Header CRC32 (valid): %08x\n", $header_crc32own;
  } else {
   printf "Header CRC32 (WARNING: INVALID BECAUSED EXPECTED %08x", $header_crc32check;
   printf "): %08x\n", $header_crc32own;
   print "\tUPDATE NEEDED: GPT header and backup\n";
   $gptheader_write_needed=1;
   $gptheader_backup_write_needed=1;
  }
  printf "Current header (main) LBA: %d\n", $current_lba;
  printf "Other header (backup) LBA: %d\n", $other_lba;
  printf "First LBA: %d\n", $first_lba;
  printf "Final LBA: %d\n", $final_lba;
  #printf "GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $disk_guid;
  # GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
  # but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
  printf "Disk GUID: %s\n", gpt_guid_decode($disk_guid);
  printf "GPT current (main) LBA: %d\n", $gptparts_lba;
  printf "Number of partitions: %d\n", $num_parts;
  printf "Partition record size: %d\n", $part_size;
  printf "Partitions CRC32 (validity unknown yet): %08x\n", $gptparts_crc32own;
 }
 # Populate the gpt main header hash
 $gptheader_main{signature}=$signature;
 $gptheader_main{revision}=$revision;
 $gptheader_main{header_size}=$header_size;
 $gptheader_main{header_crc32own}=$header_crc32own;
 $gptheader_main{reserved}=$reserved;
 $gptheader_main{current_lba}=$current_lba;
 $gptheader_main{other_lba}=$other_lba;
 $gptheader_main{first_lba}=$first_lba;
 $gptheader_main{final_lba}=$final_lba;
 # Store the guids in the ascii form they're expected
 $gptheader_main{disk_guid}=gpt_guid_decode($disk_guid);
 $gptheader_main{gptparts_lba}=$gptparts_lba;
 $gptheader_main{num_parts}=$num_parts;
 $gptheader_main{part_size}=$part_size;
 $gptheader_main{gptparts_crc32own}=$gptparts_crc32own;
 if ($header_crc32check == $header_crc32own) {
  $gptheader_main{header_crc32}{valid}=1;
 } else {
  print "WARNING: GPT header has invalid crc32\n";
  print "\tUPDATE NEEDED: GPT header\n";
  $gptheader_main{header_crc32}{valid}=0;
  $gptheader_write_needed=1;
 }
} # if $geometry{end} > 512+92

########################################################### READ MBR PARTITIONS

## Primary MBR partitions & iso signatures exploration
# Read in a string
my $mbr;
# Kept in a hash for tweaks
my %mbr_partitions;
# Also kept in an array for easy verifications since no crc32
my @mbr_partitions_raw;
if ($geometry{end} > $geometry{block_size} + $hardcoded_mbr_bootcode_size + $hardcoded_mbr_signature_size + $hardcoded_mbr_size) {

 if ($noheaders <1) {
  print "\n# READING MBR PARTITIONS:\n";
 }
 # Keep track separately of what LBAs have been explored for CD001 signatures
 # (in case of partitions overlap)
 my %isosigs_explored;

 # Seek back to the MBR location at offset 446
 seek $fh, $hardcoded_mbr_bootcode_size+$hardcoded_mbr_signature_size, 0 or die "Can't seek to MBR: $!\n";

 # Read 64 bytes of MBR partition table
 read $fh, $mbr, $hardcoded_mbr_size or die "Can't read MBR: $!\n";

 # Parse the MBR partition table into four 16-byte entries
 @mbr_partitions_raw = unpack "(a16)4", $mbr;

 # Loop through each MBR partition entry
 for my $i (0 .. 3) {
  # Extract the partition status, CHS first, type, CHS final, LBA start, and LBA sectors
  my ($status, $hcs_a, $hcs_b, $hcs_c, $type, $hcs_x, $hcs_y, $hcs_z, $start, $sectors) = unpack "C C3 C C3 V V", $mbr_partitions_raw[$i];
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
  my $size = ($sectors * $geometry{block_size})/(1024*1024);
  # Suffix the type to project to the nick
  my $nick = lc(sprintf("%02x",$type)) . "00";

  # Print the partition number, status, type, start sector, end sector, size, and number of sectors
  printf "MBR partition #%d: Start: %d, Stops: %d, Sectors: %d, Size: %d M\n", $i + 1, $start, $end, $sectors, $size;

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
    my ($c_first, $h_first, $s_first) = mbr_hcs_to_chs($hcs_first);
    my ($c_final, $h_final, $s_final) = mbr_hcs_to_chs($hcs_final);
    # bin to hex, should have used sprintf
    my $first = unpack ("H*", $hcs_first);
    my $final = unpack ("H*", $hcs_final);
    print " HCS decoded to (c,h,s): span ($c_first, $h_final, $s_final) =$first to ($c_final, $h_final, $s_final)
 = $final\n";
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
  my $text=$nick_to_mbrtext{"$nick"};
  print " Nick: $nick, Text: $text, MBR type: $mbrtype, Status: $stat\n";
  # Only explore once if multiple partitions are defined to start at the same address
  if ($type == 0 and $noisodetect<1) {
   my ($info_isos, $isosigs_found_ref) = isodetect($fh, $start, \%isosigs_explored);
   print $info_isos;
   # Save just the values to the mbr_partitions hash
   $mbr_partitions{$i}{isosig}=$isosigs_found_ref->{nbr};
  } # if type 0
 } # for my i
} # if $geometry{end} > 510

########################################################### READ GPT BACKUP

## Secondary GPT header
# Kept in a hash for easy tweaks
my %gptheader_backup;

if ($noheaders <1) {
 print "\n# CHECKING BACKUP GPT HEADER:\n";
}

# Should have $other_lba by the end of the disk:
# LBA      Z-33: last usable sector assuming <=128 partitions
# (... GPT partition table backup ...)
# LBA       Z-2: GPT partition table ends (backup)
# LBA       Z-1: GPT header (backup)
# LBA         Z: end of disk
#
# But if using a disk image, it needs to be at least:
#  - 1*bsize+92 for the gpt header
#  - 1*bsize+92+128*128 for the gpt tables
#  - 3*bsize+128*128 to have a gpt backup header (and no actual data!)
#  - 3*bsize+2*(128*128) to have both gpt backups (yet no actual data!)

unless ($geometry{end} > 3*($geometry{block_size})+128*128) {
  $gpt_header_backup_inaccessible=1;
  # with an image of say 1k, mbr + gpt header + some gpt partitions, nothing else
  print "WARNING: disk image shorter than $geometry{block_size} +92\n";
  print " so no room for no GPT backup header at LBA-1\n";
  print " so no room either for backup partitions before that\n";
  print " but nothing much we can do here!\n";
} else {
 # Read in a string
 my $backup_header;

 # Use a negative number to go in the other direction, from the end
 # WARNING: dying here will fail on small image, so now using a variable
 # $gpt_anyof_backup_inaccessible
 seek $fh, -1*$geometry{block_size}, 2 or $gpt_header_backup_inaccessible=2;

 if ($gpt_header_backup_inaccessible >0) {
  #die "Can't seek to BACKUP header at -1: $!\n";
  print "WARNING: disk image shorter than $geometry{block_size}, no GPT backup header at LBA-1, no backup partitions before either\n";
  if ($dangerous_fixes>0) {
   print " DANGER: using workaround: hardcoding the other GPT header lba to be the same as main\n";
   $gptheader_main{other_lba}=$gptheader_main{current_lba};
   # using the workaround requires tweaking the main header to pretend it's both
   print "\tUPDATE NEEDED: GPT header\n";
   $gptheader_write_needed=1;
   # Will then have to see if there's enough room to fit a backup header, or just lie like:
   #$current_lba=$gptheader_main{current_lba};
   #$other_lba=$gptheader_main{current_lba};
  } # if dangerous_fixes
 }

 # Then get the actual position
 my $other_offset = tell $fh;
 my $other_lba_offset=int($other_offset/$geometry{block_size});

 # And check if it matches: then $other_lba is by the end of the disk
 if ($noheaders <1) {
  if ($gptheader_main{other_lba} == $other_lba_offset) {
   print "BACKUP GPT header (valid offset for LBA-1 -> LBA=$other_offset): $gptheader_main{other_lba}\n";
  } else {
   print "BACKUP GPT header (WARNING: INVALID OFFSET SINCE LBA-1 -> LBA=$other_lba_offset != $other_offset): $gptheader_main{other_lba}\n";
   # If not, store that possible discrepency in the hash
   $gptheader_main{other_lba_unexpected}=$other_lba_offset;
   # Then triggers a rewrite of everything, to get and store the correct other_lba
   print "\tUPDATE NEEDED: GPT header and backup\n";
   $gptheader_write_needed=1;
   $gptheader_backup_write_needed=1;
  }
 }

 # Then read what was found, hopefully the backup GPT header
 read $fh, $backup_header, $hardcoded_gpt_header_size or die "Can't read backup GPT header: $!\n";

 # Parse the backup GPT header into fields
 my ($backup_signature, $backup_revision, $backup_header_size, $backup_header_crc32own, $backup_reserved,
  $backup_current_lba, $backup_other_lba, $backup_first_lba, $backup_final_lba, $backup_disk_guid,
  $backup_gptparts_lba, $backup_num_parts, $backup_part_size, $backup_gptparts_crc32own) = unpack "a8 L L L L Q Q Q Q a16 Q L L L", $backup_header;
 # Do a quick check if the CRC is ok: reproduce it with own field zeroed out
 my $backup_header_nocrc32 = substr ($backup_header, 0, 16) . "\x00\x00\x00\x00" . substr ($backup_header, 20);
 my $backup_header_crc32check=crc32($backup_header_nocrc32);

 # Check the GPT signature and revision: if implausible, flush the backup
 if ($gptheader_main{signature} ne $backup_signature or $gptheader_main{revision} ne $backup_revision) {
  unless ($backup_signature eq "EFI PART" and $backup_revision == 0x00010000) {
   # WONTFIX: no better alternative: would show wrong information
   ($backup_signature, $backup_revision, $backup_header_size, $backup_header_crc32own, $backup_reserved,
   $backup_current_lba, $backup_other_lba, $backup_first_lba, $backup_final_lba, $backup_disk_guid,
   $backup_gptparts_lba, $backup_num_parts, $backup_part_size, $backup_gptparts_crc32own)
   = (0, 0, 0, 0, 0,
      0, 0, 0, 0 ,0,
      0, 0, 0, 0);
   if ($noheaders <1) {
    printf "WARNING: signature incorrect so BACKUP flushed\n";
   }
  } else { # unless signature and revision good
   if ($backup_header_crc32check == $backup_header_crc32own) {
    if ($noheaders <1) {
     printf "BACKUP HEADER CRC32 (valid): %08x\n", $backup_header_crc32own;
    }
   } else {
    if ($noheaders <1) {
     printf "BACKUP HEADER CRC32 (WARNING: INVALID BECAUSED EXPECTED %08x", $backup_header_crc32check;
     printf "): %08x\n", $backup_header_crc32own;
     print "\tUPDATE NEEDED: GPT header backup\n";
    }
    $gptheader_backup_write_needed=1;
   } # if crc ==
  } # unless both signature and revision good
 } # if signature or revision differ

 # Now populate the gpt backup header hash
 $gptheader_backup{signature}=$backup_signature;
 $gptheader_backup{revision}=$backup_revision;
 $gptheader_backup{header_size}=$backup_header_size;
 $gptheader_backup{header_crc32own}=$backup_header_crc32own;
 $gptheader_backup{reserved}=$backup_reserved;
 $gptheader_backup{current_lba}=$backup_current_lba;
 $gptheader_backup{other_lba}=$backup_other_lba;
 $gptheader_backup{first_lba}=$backup_first_lba;
 $gptheader_backup{final_lba}=$backup_final_lba;
 $gptheader_backup{disk_guid}=$backup_disk_guid;
 $gptheader_backup{gptparts_lba}=$backup_gptparts_lba;
 $gptheader_backup{num_parts}=$backup_num_parts;
 $gptheader_backup{part_size}=$backup_part_size;
 $gptheader_backup{gptparts_crc32own}=$backup_gptparts_crc32own;
 if ($backup_header_crc32check == $backup_header_crc32own) {
  $gptheader_backup{header_crc32}{valid}=1;
 } else {
  $gptheader_backup{header_crc32}{valid}=0;
 }

 # Show divergences between main and backup if there's something to show 
 # and if backup gptparts_lba is plausible, could be:
 #  >0 (=0 when attempting to read from a short/trimmed image)
 #  > $gptheader_backup{first_lba}: 0 if trimmed, but what if misread
 #  >6 seem safe: min LBA for a bsize=4k
 my $other_lba_plausible;
 if (defined($gptheader_backup{first_lba}) and $gptheader_backup{first_lba}>5) {
  $other_lba_plausible=$gptheader_backup{first_lba};
 } else {
  $other_lba_plausible=6;
 }
 unless ($other_lba_offset > $other_lba_plausible and defined($gptheader_backup{signature}) and $gptheader_backup{signature} ne "0") {
  print "WARNING: divergences from main not show as backup unlikely to be good\n";
 } else {
  # Also, if headers are accepted
  if ($noheaders <1) {
   if ($noheaders <1) {
    printf "DIVERGENCE: BACKUP Signature (WARNING: INVALID): %s\n", $backup_signature;
    printf "DIVERGENCE: BACKUP Revision (WARNING: UNKNOWN): %08x\n", $backup_revision;
   }
   if ($gptheader_main{header_size} != $backup_header_size) {
    print "DIVERGENCE: BACKUP Header size (hardcoded $hardcoded_gpt_header_size): $backup_header_size\n";
   }
   if ($backup_current_lba != $gptheader_main{other_lba}) {
    printf "DIVERGENCE: BACKUP Current (backup) LBA: %d\n", $backup_current_lba;
   }
   if ($gptheader_main{current_lba} != $backup_other_lba) {
    printf "DIVERGENCE: BACKUP Other (main) LBA: %d\n", $backup_other_lba;
   }
   if ($gptheader_main{first_lba} != $backup_first_lba) {
    printf "DIVERGENCE: BACKUP First LBA: %d\n", $backup_first_lba;
   }
   if ($gptheader_main{final_lba} != $backup_final_lba) {
    printf "DIVERGENCE: BACKUP Final LBA: %d\n", $backup_final_lba;
   }
   #printf "GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $backup_guid;
   # GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
   # but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
   if ($gptheader_main{disk_guid} ne $backup_disk_guid) {
    printf "DIVERGENCE: BACKUP Disk_GUID: %s\n", gpt_guid_decode($backup_disk_guid);
   }
   # gptparts_lba from main must diverge from backup_gptparts_lba
   printf "BACKUP GPT current (backup) LBA: %d\n", $backup_gptparts_lba;
   if ($gptheader_main{num_parts} != $backup_num_parts) {
    printf "DIVERGENCE: BACKUP Number of partitions: %d\n", $backup_num_parts;
   }
   if ($gptheader_main{part_size} != $backup_part_size) {
    printf "DIVERGENCE: BACKUP Partition size: %d\n", $backup_part_size;
   }
  } # if headers
 } # if lba plausible
} # if geometry{end} > bsize+92

########################################################### COMPARE BOTH GPT

unless ($gpt_header_inaccessible==0 and $gpt_header_backup_inaccessible==0) {
print "\n# WARNING: UNABLE TO COMPARE MAIN GPT HEADER TO BACKUP: NEED BOTH\n";
} else {
print "\n# COMPARING MAIN GPT HEADER TO BACKUP:\n";
# Prepare CRC32 if the backup was canonical or primary wasn't primary:
# - as usual, remove own header crc32
# - swap backup_current_lba and backup_other_lba
# - swap gptparts_lba and backup_gptparts_lba
# This allow divergence checks and shows helpful information (hexedit/tweaks)
my $backup_header_nocrc32_if_canonical= pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $gptheader_backup{signature}, $gptheader_backup{revision}, $gptheader_backup{header_size}, ord("\0"), $gptheader_backup{reserved},
 $gptheader_backup{other_lba}, $gptheader_backup{current_lba}, $gptheader_backup{first_lba}, $gptheader_backup{final_lba}, $gptheader_backup{disk_guid},
 $gptheader_main{gptparts_lba}, $gptheader_backup{num_parts}, $gptheader_backup{part_size}, $gptheader_backup{gptparts_crc32own});
my $header_nocrc32_if_noncanonical = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $gptheader_main{signature}, $gptheader_main{revision}, $gptheader_main{header_size}, ord("\0"), $gptheader_main{reserved},
 $gptheader_main{other_lba}, $gptheader_main{current_lba}, $gptheader_main{first_lba}, $gptheader_main{final_lba}, $gptheader_main{disk_guid},
 $gptheader_backup{gptparts_lba}, $gptheader_main{num_parts}, $gptheader_main{part_size}, $gptheader_main{gptparts_crc32own});

if (crc32($backup_header_nocrc32_if_canonical) ne $gptheader_main{header_crc32own}) {
 printf "DIVERGENCE: BACKUP CRC32 if BACKUP Canonical: %08x (if backup became main at main LBA)\n", crc32($backup_header_nocrc32_if_canonical);
}
if (crc32($header_nocrc32_if_noncanonical) ne $gptheader_backup{header_crc32own}) {
 printf "DIVERGENCE: MAIN CRC2 if MAIN Non-Canonical: %08x (if main became backup at backup LBA)\n", crc32($header_nocrc32_if_noncanonical);
}

# Having both gpt headers, could decide to replace one by the other in tweaks
# However, this requires knowing if it would work given the crc32 + swaps
if (crc32($backup_header_nocrc32_if_canonical) ne $gptheader_main{header_crc32own}) {
 $gptheader_backup{header_crc32}{valid_as_main}=0;
} else {
 $gptheader_backup{header_crc32}{valid_as_main}=1;
}
if (crc32($header_nocrc32_if_noncanonical) ne $gptheader_backup{header_crc32own}) {
 $gptheader_main{header_crc32}{valid_as_backup}=0;
} else {
 $gptheader_main{header_crc32}{valid_as_backup}=1;
}
} # if have both
# The same will be done with the partitions after reading them

########################################################### READ GPT PARTST

## Main GPT partitions
# Kept in a hash for tweaks
my %gpt_partitions;

print "\n# READING MAIN GPT PARTITIONS:\n";

# The GPT hould have several partitions of 128 bytes each, but nothing hardcoded
# only provide fallback values if couldn't read from the main:
#  - by default 128 partitions, 128 bytes each
#  - but should use the numbers just read if possible
my $gptpartst_size_guess;
if (defined($gptheader_main{num_parts}) and defined($gptheader_main{part_size})) {
 $gptpartst_size_guess=$gptheader_main{num_parts}*$gptheader_main{part_size};
} else {
 # guess for real
 print "WARNING: GPT partition table size guesstimated to 128^2\n";
 $gptpartst_size_guess=128**2;
}

# If using a disk image, it needs to be at least:
#  - 1*bsize+92 for the gpt header:
#   - if we have 92b more, we may get the GPT main header if bsize=512
#   - if we have 4k total but bsize=4k, we won't have even the GPT header
#  - 1*bsize+92+128*128 for the gpt tables
#   - if we have 2k total but bsize=512, we'll have part of the GPT tables
#  - 3*bsize+128*128 to have a gpt backup header (and no actual data!)
#  - 3*bsize+2*(128*128) to have both gpt backups (yet no actual data!)

unless ($geometry{end} > $geometry{block_size}+$hardcoded_gpt_header_size+$gptpartst_size_guess) {
 print "WARNING: looks too small to have a full GPT partition table\n";
 $gpt_partst_inaccessible=1;
}

 # Go to the start LBA offset and read, but iff it's plausible
unless ($gpt_header_inaccessible==1) {
 if ($gptheader_main{gptparts_lba}==0) {
  print "WARNING: GPT PARTITIONS start at LBA0 implausible\n";
  $gpt_partst_inaccessible=2;
 }
}

# To help in recoveries:
# not using $gpt_partst_inaccessible>0 but $gpt_header_inaccessible>0
# Therefore, if there's any chance to read anything, will read it
# (so if we have 2k total but bsize=512, we'll have part of the GPT tables)
unless ($gpt_header_inaccessible>0) {
 # Read in a string
 my $gptparts;
 my $gptparts_offset=$gptheader_main{gptparts_lba}*$geometry{block_size};
 seek $fh, $gptparts_offset, 0 or $gpt_partst_inaccessible=3;
 #die "Can't seek to the GPT lba $gptparts_lba: $!\n";
 read $fh, $gptparts, $gptpartst_size_guess or $gpt_partst_inaccessible=4;
 #die "Can't read the GPT at $num_parts*$part_size: $!\n";
 if ($gpt_partst_inaccessible>1 ) {
  # Replace what should have been read by null bytes regardless why not available
  print "WARNING: GPT PARTITIONS implausible ($gpt_partst_inaccessible), assuming empty";
  $gptparts="\0"x $gptpartst_size_guess;
 }
 # crc32 what we just read to inform the gpt main header hash of the validity
 if ($gptheader_main{gptparts_crc32own} == crc32($gptparts)) {
  printf "Partition CRC32 (valid): %08x\n", $gptheader_main{gptparts_crc32own};
  $gptheader_main{gptparts_crc32}{valid}=1;
 } else {
  printf "Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($gptparts);
  printf "): %08x\n", $gptheader_main{gptparts_crc32own};
  $gptheader_main{gptparts_crc32}{valid}=0;
  # A rewrite will be needed, at least to get a different crc32
  print "\tUPDATE NEEDED: GPT header and partition table\n";
  $gptpartst_write_needed=1;
  # The consequence on the header should be detected, but can make sure with:
  $gptheader_write_needed=1;
 }

 # Use a temporary array to build the hash
 my @partitions_raw_gpt_primary;

 # In case of partial read (ex: 3k instead of 16k), truncate to 128, and fix
 if (length($gptparts)< $gptpartst_size_guess) {
  print "WARNING: only read " . length($gptparts) . "b instead of guessed $gptpartst_size_guess\n";
 }

 # Split gpt partitions records into an array for reading
 @partitions_raw_gpt_primary=unpack "(a$gptheader_main{part_size})$gptheader_main{num_parts}", $gptparts;

 # Then populate a partition hash by unpacking each partition entry
 my $i=0;
 my $i_decoded=0;
 my $partition_entry_empty="\x00" x $gptheader_main{part_size};
 for my $partition_entry (@partitions_raw_gpt_primary) {
  # WARNING: especially when $gpt_partst_inaccessible>0, check carefully:
  if (length($partition_entry) == $gptheader_main{part_size}) {
   my ($type_guid_weird, $part_guid_weird, $first_lba, $final_lba, $attr, $name) = unpack "a16 a16 Q Q Q a$hardcoded_gpt_partname_size", $partition_entry;
   # To help debug, can eyeball the entries with:
   #print unpack("H128", $partition_entry) . "\n";
   # Skip empty partitions?
   #next if $type_guid eq "\x00" x 16;
   # Don't skip empties as could have the 1st partition be the nth, n!=1
   # Instead, mark as empty
   # Populate the gpt main partitions hash
   if ($partition_entry eq $partition_entry_empty) {
    $gpt_partitions{$i}{empty}=1;
   } else {
    #$gpt_partitions{$i}{type_guid}=$type_guid;
    #$gpt_partitions{$i}{part_guid}=$part_guid;
    # Store the guids in the format they are expected
    # and complement the type guid by a shorter nick
    my $type=gpt_guid_decode($type_guid_weird);
    my $nick=$guid_to_nick{$type};
    $gpt_partitions{$i}{nick}=$nick;
    $gpt_partitions{$i}{part_guid}=gpt_guid_decode($part_guid_weird);
    $gpt_partitions{$i}{type_guid}=$type;
    $gpt_partitions{$i}{first_lba}=$first_lba;
    $gpt_partitions{$i}{final_lba}=$final_lba;
    $gpt_partitions{$i}{attr}=$attr;
    $gpt_partitions{$i}{name}=gpt_name_decode($name);
   }
   $i_decoded=$i_decoded+1;
  #} else { # length equals expected
  # print "$i==" . length($partition_entry) . ",";
  } # length equals expected
  $i=$i+1;
 } # for @partitions_raw_gpt_primary

 if ($i > $i_decoded) {
   print "WARNING: only decoded $i_decoded out of the $i partitions expected\n";
 }

 # Find the maximal value for non empty partition to stop showing past that
 my $partitions_max_nonempty;
 for my $r ( sort { $a <=> $b } keys %gpt_partitions) {
  # Cast to int
  my $c=$r+0;
  my $partition_entry;
  unless (defined($gpt_partitions{$c}{empty})) {
   $partitions_max_nonempty=$c;
  } # unless defined
 } # for

 # No need to loop through each partition entry: show from the hash
 for my $r ( sort { $a <=> $b } keys %gpt_partitions) {
  # Cast to int
  my $c=$r+0;
  my $partition_entry;
  if (defined($gpt_partitions{$c}{empty})) {
   if ($gpt_partitions{$c}{empty}==1) {
    if ($c <$partitions_max_nonempty) {
     print "Partition $c: (empty)\n";
    }
   }
  } else {
   my $type_guid=$gpt_partitions{$c}{type_guid};
   my $part_guid=$gpt_partitions{$c}{part_guid};
   my $first_lba=$gpt_partitions{$c}{first_lba};
   my $final_lba=$gpt_partitions{$c}{final_lba};
   my $attr= $gpt_partitions{$c}{attr};
   my $name=$gpt_partitions{$c}{name};
   my $nick=$gpt_partitions{$c}{nick};
   # Print the partition number and information
   my $sectors=$final_lba - $first_lba + 1;
   my $size = int (($sectors * $geometry{block_size})/(1024*1024));
   print "GPT partition #$c: Start $first_lba, Stops: $final_lba, Sectors: $sectors, Size: $size M\n";
   # Get the short nick from the guid, and likewise for the textual description
   print " Nick: $nick, Text: $guid_to_text{$type_guid}, Name: $name, GUID: $part_guid\n";
   if ($attr>0) {
    print " Attributes bits set: ";
    print "\n";
   } # if attr
  } # else empty
 } # for
} # unless geometry

########################################################### READ GPT PARTST BACKUP

print "\n# READING BACKUP GPT PARTITIONS:\n";
# Keep it in a hash for tweaks
my %gpt_backup_partitions;

unless ($gpt_header_backup_inaccessible==0) {
 print "WARNING: GPT header was inaccessible\n";
}

# The backup GPT partition table ends near the EOF (or end-of-disk) at LBA-2
# Must take into account the partition size to get to where it start:
# - by default 128 partitions, 128 bytes each: so 16k before LBA-2
# - but should use the numbers just read from the backup table if possible
my $gptpartst_backup_size_guess;
if (defined($gptheader_backup{num_parts}) and defined($gptheader_backup{part_size})) {
 # actual numbers
 $gptpartst_backup_size_guess=$gptheader_backup{num_parts}*$gptheader_backup{part_size};
} elsif (defined($gptheader_main{num_parts}) and defined($gptheader_main{part_size})) {
 print "WARNING: GPT backup partition table size estimated from main\n";
 # estimate from main
 $gptpartst_backup_size_guess=$gptheader_main{num_parts}*$gptheader_main{part_size};
} else {
 # guess for real
 print "WARNING: GPT backup partition table size guesstimated to 128^2\n";
 $gptpartst_backup_size_guess=128**2;
}

# Here, we may have problems reading the backup gpt table when:
#  - the image is truncated -> unfixable, if conflicts with existing parts
#  - after imaging, if backup lba incorrect: new backup needed at some lba
#  - in either case, may also need a new gptparts_backup if can fit it
# No need to keep the cause of the problem, just of what if affects:
#  - change of disk geometry, backup header lba: require rewriting main too
#  - need to have flow logic based on write needed + crc32 to imply more

# With a negative number to read backwards (from the end), size requirements:
# when using a disk image, it needs to be at least:
#  - 3*bsize+128*128 to have a gpt backup header (and no actual data!)
#  - 3*bsize+2*(128*128) to have both gpt backups (yet no actual data!)

# If the backup header is missing, don't even bother trying
if ($gpt_header_backup_inaccessible > 0) {
 # Can at least try to explain the geometry requirements:
 # LBA0=MBR, LBA1=GPT header, LBA-1= GPT header backup
 my $minsize=($geometry{block_size}*3)+$gptpartst_backup_size_guess+$gptpartst_size_guess;
 my $minsizek=$minsize/1024;
 my $sizek=$geometry{end}/1024;
 print "WARNING: no room for a GPT partition table backup: total size >= $minsize B:\n";
 print " even with no actual disk data at all, 3x $geometry{block_size} +$gptpartst_backup_size_guess+$gptpartst_size_guess is the minimum size\n";
 print " but here, $path is $geometry{end} B <= $minsize B: $sizek K < $minsizek K\n";
 # Just indicate that sitation to avoid reading at a random location
 $gpt_partst_backup_inaccessible=1;
} else {
 # We have a GPT backup header, but is the gptparts_lba it points to "valid"
 # ie defined, not null, and currently accessible?
 my $possible_backup_gptparts_lba=0;
 if (defined($gptheader_backup{gptparts_lba})) {
  if ($gptheader_backup{gptparts_lba} != 0) {
   if ($gptheader_backup{gptparts_lba} < $geometry{lba}) {
    # "valid" or at least it's possible
    $possible_backup_gptparts_lba=1;
   }
  }
 }
 # Could make it be possible for a truncated image, but way too dirty
 #if ($possible_backup_gptparts_lba==0) {
 # $gpt_partst_backup_inaccessible=2;
 # print "WARNING: implausible GPT partition backup LBA: $gptheader_backup{gptparts_lba}\n";
 # # Dirty tricks are possible
 # if ($dangerous_fixes>0) {
 #  print " DANGER: Using workaround: making the backup GPT header to use main gptparts_lba\n";
 #  # It feels wrong
 #  $gptheader_backup{gptparts_lba}=$gptheader_main{gptparts_lba};
 #  # Worse: rewriting the header means it'll get hidden by the crc32
 #  print "\tUPDATE NEEDED: GPT header\n";
 #  $gptheader_write_needed=1;
 #  # At least, this discrepency will be stored in the hash: 0 since too short
 #  $gptheader_backup{expected_current_lba}=0;
 # } # if dangerous_fixes
 #}

 # See if can reach this position using a negative number with WHENCE 2 (EOF)
 seek $fh, -1*($gptpartst_backup_size_guess)-(1*$geometry{block_size}), 2 or $gpt_partst_backup_inaccessible=3;

 # If there's a chance the read may work, try it to check the offset we land at
 if ($gpt_partst_backup_inaccessible>0) {
  print "WARNING: failed reaching GPT backup partition table: $gpt_partst_backup_inaccessible\n";
  # FIXME: how could it happen with ==3, like with a wrong guess?
  # FIXME: could then fill $gptheader_backup{expected_current_lba}
 } else {
  # Get the current position of wherever we are
  my $gptbackup_offset = tell $fh;
  my $gptbackup_lba_offset=int($gptbackup_offset/$geometry{block_size});
  # Check if the position matches our expectations
  if ($gptheader_backup{gptparts_lba} == $gptbackup_lba_offset) {
   print "BACKUP GPT AT (valid offset for LBA -2 -tblsize) -> LBA=$gptbackup_offset): $gptheader_backup{gptparts_lba}\n";
  } else {
   print "BACKUP GPT AT (WARNING: UNEXPECTED AT $gptbackup_offset SINCE LBA-2 -> LBA=$gptbackup_lba_offset): $gptheader_backup{gptparts_lba}\n";
   # No need for a rewrite: could be a sign of having had >128 parts in the past
   #$gptheader_backup_write_needed=1
   # Just store that possible discrepency in the hash
   $gptheader_backup{expected_current_lba}=$gptbackup_lba_offset;
  } # if match expectation
 } # if $gpt_partst_backup_inaccessible>0

 # Now try to go to the LBA offset indicated in the backup header:
 # failing to seek it is another case of inaccessibility
 seek $fh, $gptheader_backup{gptparts_lba}*$geometry{block_size}, 0 or $gpt_partst_backup_inaccessible=4;

 # Read the partst backup to a string
 my $backup_gptparts;

 # But only if there's no error
 if ($gpt_partst_backup_inaccessible==0) {
  read $fh, $backup_gptparts, $gptpartst_backup_size_guess or $gpt_partst_backup_inaccessible=5;
 } else {
  print "WARNING: failed reaching GPT backup partition table: $gpt_partst_backup_inaccessible\n";
  # Replace what should have been read by null bytes regardless why not available
  $backup_gptparts="\0" x 128**2;
  # gptparts_lba is indicated in both, only in a reversed order, so both need rewriting
  print "\tUPDATE NEEDED: GPT header and backup (that was inaccessible)\n";
  $gptheader_backup_write_needed=1;
  # We also need the pointing address, so request a main header fix too
  $gptheader_write_needed=1;
  # Both write are needed, but if the size is too small, a backup may not fit
 }

 # We're now done with the filehandle for reading
 close $fh or die "Can't close $path : $!\n";

 # crc32 what we just read, to update the backup header crc32 validity
 if ($gptheader_backup{gptparts_crc32own} == crc32($backup_gptparts)) {
  if (defined($gptheader_backup{gptparts_crc32own})) {
   printf "BACKUP Partition CRC32 (valid): %08x\n", $gptheader_main{gptparts_crc32own};
   $gptheader_backup{gptparts_crc32}{valid}=1;
  }
 } else {
  printf "BACKUP Partition CRC32: (WARNING: INVALID, EXPECTED %08x", crc32($backup_gptparts);
  printf "): %08x\n", $gptheader_backup{gptparts_crc32own};
  $gptheader_backup{gptparts_crc32}{valid}=0;
  # Need a write
  print "\tUPDATE NEEDED: GPT partition table backup (crc32 invalid)\n";
  $gptpartst_backup_write_needed=1;
 }

 # Read the gpt backup raw partitions records
 my @partitions_raw_gpt_backup=unpack "(a$gptheader_backup{part_size})$gptheader_backup{num_parts}", $backup_gptparts;

 # Then populate a partition hash by unpacking each partition entry
 my $j=0;
 my $partition_entry_empty="\x00" x $gptheader_main{part_size};
 for my $partition_entry (@partitions_raw_gpt_backup) {
  # Unpack each partition entry into fields of the hash
  my ($type_guid_weird, $part_guid_weird, $first_lba, $final_lba, $attr, $name) = unpack "a16 a16 Q Q Q a$hardcoded_gpt_partname_size", $partition_entry;
  # Skip empty partitions?
  #next if $type_guid eq "\x00" x 16;
  # Don't skip empties as could have the 1st partition be the nth, n!=1
  # Instead, mark as empty
  # Populate the hash
  if ($partition_entry eq $partition_entry_empty) {
   $gpt_backup_partitions{$j}{empty}=1;
  } else {
   #$gpt_backup_partitions{$i}{type_guid}=$type_guid;
   #$gpt_backup_partitions{$i}{part_guid}=$part_guid;
   # Store the guids in the format they are expected
   # and complement the type guid by a shorter nick
   my $type=gpt_guid_decode($type_guid_weird);
   my $nick=$guid_to_nick{$type};
   $gpt_backup_partitions{$j}{nick}=$nick;
   $gpt_backup_partitions{$j}{part_guid}=gpt_guid_decode($part_guid_weird);
   $gpt_backup_partitions{$j}{type_guid}=$type;
   $gpt_backup_partitions{$j}{first_lba}=$first_lba;
   $gpt_backup_partitions{$j}{final_lba}=$final_lba;
   $gpt_backup_partitions{$j}{attr}=$attr;
   $gpt_backup_partitions{$j}{name}=gpt_name_decode($name);
  }
  $j=$j+1;
 } # for @partitions_raw_gpt_backup

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
   # But what if not in main?
   unless (defined($gpt_partitions{$c}{empty})) {
      print "DIVERGENCE: BACKUP Partition $c: (empty) while MAIN is NOT empty\n";
   }
   if ($gpt_backup_partitions{$c}{empty}==1) {
    if ($c < $backup_partitions_max_nonempty) {
     # Only show if there's a difference somewhere:
     if ($gpt_backup_partitions{$c}{empty} != $gpt_partitions{$c}{empty}) {
      print "DIVERGENCE: BACKUP Partition $c: (empty)\n";
     }
    }
   }
  } else {
   my $type_guid=$gpt_backup_partitions{$c}{type_guid};
   my $nick=$gpt_backup_partitions{$c}{nick};
   my $part_guid=$gpt_backup_partitions{$c}{part_guid};
   my $first_lba=$gpt_backup_partitions{$c}{first_lba};
   my $final_lba=$gpt_backup_partitions{$c}{final_lba};
   my $attr=$gpt_backup_partitions{$c}{attr};
   my $name=$gpt_backup_partitions{$c}{name};
   my $divergent=0;

   # Detect differences to only show the different entries
   if ($gpt_partitions{$c}{type_guid} ne $type_guid
    or $gpt_partitions{$c}{part_guid} ne $part_guid
    or $gpt_partitions{$c}{first_lba} ne $first_lba
    or $gpt_partitions{$c}{final_lba} ne $final_lba
    or $gpt_partitions{$c}{attr} ne $attr
    or $gpt_partitions{$c}{name} ne $name) {
     $divergent=1;
     $diverged_even_once=1;
   }
   # But at least we checked!
   $divergences_checked=$divergences_checked+1;

   # Prepare the partition number and information for print
   my $sectors= $gptheader_backup{final_lba} - $gptheader_backup{first_lba} + 1;
   my $size = int (($sectors * $geometry{block_size})/(1024*1024));
   # But print only if therere's a divergence
   if ($divergent>0) {
    print "DIVERGENCE: BACKUP GPT partition #$c: Start $first_lba, Stops: $final_lba, Sectors: $sectors, Size: $size M\n";
    # Will need a rewrite
    print "\tUPDATE NEEDED: GPT header backup (divergence)\n";
    $gptheader_backup_write_needed=1;
    # Show the details
    print " Nick: $nick, Text: $guid_to_text{$type_guid}, Name: $name, GUID: $gptheader_main{disk_guid}\n";
    if ($attr>0) {
     print " Attributes bits set: ";
     my ($attrs_text, $attrs_hash) = gpt_attr_decode($attr);
     print $attrs_text;
    } # if attr
   } # if divergent
  } # else emptpy
 } # for my r

 if ($diverged_even_once==0 and not ( $gpt_header_backup_inaccessible>0 or $gptheader_backup_write_needed>0)) {
  print "BACKUP GPT PARTITIONS: Strictly identical, checked for divergence $divergences_checked times (once for each known GPT partition)\n"
 }
 if ( $gpt_header_backup_inaccessible>0 or $gptheader_backup_write_needed>0) {
  print "BACKUP GPT PARTITIONS: Problem, will need to write a new one\n";
  $gptpartst_backup_write_needed=1;
 }
} # if $gpt_partst_backup_inaccessible>0

########################################################### PROGRAMMATIC TWEAKS

print "\n# TWEAKS\n";

# FIXME: try to use nicks everywhere to explain better

if (1) {
 # Part 1 starting at 64, even if type 0 could be an issue?
 # if type 0 and contains iso records
 # - make it 0700 for GPT
 # - make it start at 0
 # TODO: what if the mbr isn't defined?
 # need a separate function looking for El Torito from a lba
 if (defined($mbr_partitions{0}{isosigs})) {
  if ($mbr_partitions{0}{isosigs}>2) {
   if ($mbr_partitions{0}{nick}=="0000") {
    # Check the GPT part start match, then sync both to start at 0
    if ($gpt_partitions{0}{first_lba} == $mbr_partitions{0}{start} and $mbr_partitions{0}{start} != 0) {
     $mbr_partitions{0}{start}=0;
     # should be bad, but if created by xorriso, should work: nested
     $gpt_partitions{0}{start}=0;
     $gpt_partitions{0}{nick}="0700";
     print "Changed partition 1 to: MBR=0000, GPT-0000\n";
    }
   }
  }
 }

 # Mark partition 2 active if EFISP, make sure it's ef00
 if ($mbr_partitions{1}{type}==0xef) {
  $mbr_partitions{1}{status}=0x80;
  if ($gpt_partitions{1}{first_lba} == $mbr_partitions{1}{start} and $gpt_partitions{1}{nick} ne "ef00") {
   $gpt_partitions{1}{nick}="ef00";
   print "Changed partition 1 MBR=ef00 to: active, GPT-ef00\n";
   # FIXME: also toggle its bit to active, using {attr} : complete with {properties} : HoH
  }
 }

 # Type partition 3 as NTFS if linux, for both gpt and mbr
 if ($mbr_partitions{2}{type}==0x83) {
  $mbr_partitions{2}{type}=0x07;
  if ($gpt_partitions{2}{first_lba} == $mbr_partitions{2}{start} and $gpt_partitions{2}{nick} ne "0700") {
   $gpt_partitions{2}{nick}="0700";
  }
 }

 # More complicated last example:
 # - a) create a partition 4 if there's no 4 but a 3 of type not 0x07: align and grow
 if ($mbr_partitions{2}{type}!=0x07 and $mbr_partitions{2}{type}!=0x83 and $mbr_partitions{2}{final_lba}>0 and $mbr_partitions{3}{type}==0 and $mbr_partitions{3}{status}!=0x80) {
  my $newpart_first_lba=$mbr_partitions{2}{final_lba}+1;
  # 4a1: align
  # FIXME: make the alignment fancier than modulo 8 which only does 4kn align
  # would help explain how to use $geometry{block_size}
  while ($newpart_first_lba%8 != 0) {
   $newpart_first_lba=$newpart_first_lba+1;
  } # while
  # 4a2: grow
  my $newpart_final_lba;
  if (defined($gptheader_main{final_lba})) {
   # here, not using the gpt backup since it should be a copy of the main
   # also, it could be missing
   if (defined($gptheader_main{num_parts}) and  defined($gptheader_main{parts_size})) {
   my $backup_table_guesstimate=$gptheader_main{num_parts} * $gptheader_main{parts_size};
   unless (defined($backup_table_guesstimate)) {
    # safe bet
    $backup_table_guesstimate=128*128;
   }
   my $backup_table_lba=int($backup_table_guesstimate/$geometry{block_size});
   $newpart_final_lba=$geometry{lba}- $backup_table_lba;
   my $gpt_final_lba_incorrect;
   if ($newpart_final_lba > $gptheader_main{final_lba}) {
    $gpt_final_lba_incorrect=1;
    print "WARNING: fixing GPT final_lba from $gptheader_main{final_lba} to $newpart_final_lba\n";
   }

    my $newpart_lba=$newpart_final_lba -$newpart_first_lba;
    my $newpart_size=$newpart_lba*$geometry{block_size};
    my $newpart_sizeG=sprintf "%.2f", $newpart_size/(1024***3);
    print "Creating a 4th partition of $newpart_lba LBA (~ $newpart_sizeG G) from $newpart_first_lba to $newpart_final_lba\n";
    $mbr_partitions{3}{first_lba}=$newpart_first_lba;
    $mbr_partitions{3}{final_lba}=$newpart_final_lba;
    $mbr_partitions{3}{nick}="0700";
    $gpt_partitions{3}{first_lba}=$newpart_first_lba;
    $gpt_partitions{3}{final_lba}=$newpart_first_lba;
    $gpt_partitions{3}{nick}="0700";
   }
  } else { # if defined final_lba
    die ("FIXME: add support for when no GPT is defined yet");
  } # if defined final_lba
 } # if creating part 4, condition a

 # - b) but if partition 3 is type 0x07 or 0x83, then grow it if there's room
 # FIXME: incomplete example: should use the geometry as above
 # because if there's evidence of imaging then gpt final lba is way too early
 # like ($gptheader_main{final_lba} < 0.9*$geometry{lba}) => recalculate
 if (($mbr_partitions{3}{type}==0x07 or $mbr_partitions{3}{type}==0x83) and $geometry{lba} > $mbr_partitions{3}{final_lba} and $mbr_partitions{3}{first_lba}==$gpt_partitions{3}{first_lba} and $mbr_partitions{3}{final_lba}=$gpt_partitions{3}{final_lba}) {
  # TODO: same as above, tail is incomplete and may entail gpt final lba growth
  # (pun intended)
    die ("FIXME: add support for when no GPT is defined yet");
 } # if creating part 4, condition b
} # if 0

# Will then redo the MBR and both GPTs, as the goal is to make hybrids
# So the 4 hex nicks will override both the MBR type and the GPT guid

########################################################### COMPUTE TWEAKS

# TODO: should compare the hash to the strings to tell just what's being updated
# implies adding functions to parse the partition records and maybe headers too

print "\n# UPDATES \n";

# FIXME: remove the use of $fh: now closed asap so they stand out
# goal: calculate offsets beforehad, during the tweaks

## Redo the MBR
my $mbr_tweaked;
for my $m (0 .. 3) {
 # It's easy to get a MBR type from the nick: strip the final 2 chars
 #$mbr_type=~s/..$//;
 # The nick overrides the type
 my $mbr_type=$mbr_partitions{$m}{nick};
 printf "Matching partition $m nick $mbr_partitions{$m}{nick} by going from MBR type %02x to $mbr_type because of nick $mbr_partitions{$m}{nick}\n", $mbr_partitions{$m}{type};
 # Get the hcs
 my ($hcs_c, $hcs_b, $hcs_a) = unpack ("CCC", $mbr_partitions{$m}{hcs_first_raw});
 my ($hcs_z, $hcs_y, $hcs_x) = unpack ("CCC", $mbr_partitions{$m}{hcs_final_raw});
 my $partition_entry_problem=0;
 my $partition_entry= pack "C CCC C CCC V V",
  $mbr_partitions{$m}{status},
  $hcs_a, $hcs_b, $hcs_c,
  $mbr_partitions{$m}{type},
  $hcs_x, $hcs_y, $hcs_z,
  $mbr_partitions{$m}{start},
  $mbr_partitions{$m}{sectors} or $partition_entry_problem=1;
 if ($partition_entry_problem >0) {
  # $mbr_write_needed=1;
  # FIXME: wouldn't it be the opposite?
  # If there's a packing problem, a write may be reckless
  # => should flush the entry
  $partition_entry="\0";
 }
 my $mbr_i=unpack "H16", $partition_entry;
 my $mbr_o=unpack "H16", $mbr_partitions_raw[$m];
 unless ($mbr_i eq $mbr_o) {
  print "Changing MBR partition $m from:\n$mbr_o\nto:\n$mbr_i\n";
  compare_two_strings($mbr_o, $mbr_i);
  # So we will need to write it
  $mbr_write_needed=1;
 }
 $mbr_tweaked .= $partition_entry;
}

# Pad the new mbr with zeros as needed to make it 64 bytes:
$mbr_tweaked .= "\x00" x (64 - length $mbr_tweaked);

# Unlike the gpt, no crc32 stored anywhere: must manually compare them
my $mbr_p=unpack "H64", $mbr;
my $mbr_tweaked_p=unpack "H64", $mbr_tweaked;
if (crc32($mbr_tweaked) eq crc32($mbr)) {
 print "MBR (no update needed)\n";
} else {
 print "MBR (update needed)\n";
 $mbr_write_needed=1;
 compare_two_strings($mbr, $mbr_tweaked);
 # TODO: stop doing this, use the hash
} # if crc32

## Redo the primary and backups GPT header + partitions 2*2=4 set
# 1/4 starting with primary partitions (usually 2/4 but their crc goes in 1/4)
my $gptparts_redone;
# but must sort the hash keys numerically (otherwise 0 1 10 100 101 ..)
for my $r ( sort { $a <=> $b } keys %gpt_partitions) {
 # cast to int
 my $c=$r+0;
 my $partition_entry;
 my $partition_entry_empty="\x00" x $gptheader_main{part_size};
 if (defined($gpt_partitions{$c}{empty})) {
  if ($gpt_partitions{$c}{empty}==1) {
    $partition_entry=$partition_entry_empty;
  }
 } else {
  my $nick=$gpt_partitions{$c}{nick};
  # WARNING: forgetting "0700" may cause plain 0700 to be recoded to 7
  my $type_guid=$nick_to_guid{"$nick"};
  # print "Matching partition $c GPT type to $type_guid (stored on disk as: '" . gpt_guid_encode($type_guid) . "') because of nick $gpt_partitions{$c}{nick}\n";
  printf "Matching partition $c GPT type nick $gpt_partitions{$c}{nick} by going from $type_guid to UUID $type_guid\n";
  # WARNING: use H32 if given a string from gpt_guid_encode(), used a16 before
  $partition_entry=pack "H32 H32 Q Q Q a$hardcoded_gpt_partname_size",
   gpt_guid_encode($type_guid),
   gpt_guid_encode($gpt_partitions{$c}{part_guid}),
   $gpt_partitions{$c}{first_lba},
   $gpt_partitions{$c}{final_lba},
   $gpt_partitions{$c}{attr},
   gpt_name_encode($gpt_partitions{$c}{name});
 # To help debug, can eyeball it with:
 #print unpack("H128", $partition_entry) . "\n";
 # Or use the strings comparison:
 # TODO: could create a comparison using the hashes instead
 #compare_two_strings($partition_entry, $partitions_raw_gpt_primary[$c]);
 } # if not empty
 # pad by null bytes to the $part_size
 $partition_entry .= "\x00" x ($gptheader_main{part_size} - length $partition_entry);
 # then append to redo a gpt
 $gptparts_redone .= $partition_entry;
} # for my r

# Compute the new CRC32
my $gptparts_redone_crc32 = crc32($gptparts_redone);
# WARNING: $gptparts_crc32own is already crc32($gptparts) but not sprintf'ed
if ($gptheader_main{gptparts_crc32own} eq $gptparts_redone_crc32) {
 printf "GPT partst CRC32 (no update needed): %08x\n", $gptparts_redone_crc32;
} else {
 # this implies changing their crc32, therefore snowballs to the header
 printf "GPT partst CRC32 change: implies writing GPT main and backup header too\n";
 print "\tUPDATE NEEDED: GPT header and partition table main and backup (crc32 change)\n";
 $gptpartst_write_needed=1;
 $gptheader_write_needed=1;
 # Can't be certain the backup needs change too, but good rule of thumb
 $gptpartst_backup_write_needed=1;
 $gptheader_backup_write_needed=1;
 printf "GPT partst CRC32: (update from %08x to:) %08x\n", $gptheader_main{gptparts_crc32own}, $gptparts_redone_crc32;
 # byte-by-byte comparisons can help eyeball the differences
 #compare_two_strings($gpt_partitions{raw}, $gptparts_redone);
 # TODO: could create a comparison using the hashes instead, or store $gpt_partitions{raw}
 # propagate the change to the header
 $gptheader_main{gptparts_crc32own}=$gptparts_redone_crc32;
} # if match redone

## 2/4 then the main header (usually 1/4)
# and if we don't have the right address for the backup, fix that right now
# like if couldn't access it, or if at different address than expected
if ($gpt_header_backup_inaccessible>0 or defined($gptheader_main{other_lba_unexpected})) {
 printf "GPT header backup problem: implies writing GPT main and backup header too\n";
 print "\tUPDATE NEEDED: GPT header and backup (that was inaccessible)\n";
 $gptheader_write_needed=1;
 $gptheader_backup_write_needed=1;
 # Use a negative number to go in the other direction, from the end
 seek $fh, $gptpartst_backup_size_guess-1*$geometry{block_size}, 2 or $gpt_header_backup_inaccessible=2;
 # If can't access it, use $gptheader_main{current_lba} everywehre
 if ($gpt_header_backup_inaccessible>1) {
  $gptheader_backup{current_lba}=$gptheader_main{current_lba};
  $gptheader_main{other_lba}=$gptheader_main{current_lba};
 }
 # FIXME: separate the address computation
 # Get the offset
 my $gptbackup_offset = tell $fh;
 # Get the lba
 my $gptbackup_lba_offset=int($gptbackup_offset/$geometry{block_size});
 # Then stuff that lba into the header
 $gptheader_main{other_lba}=$gptbackup_lba_offset;
 printf "GPT header backup address: $gptbackup_lba_offset from now on\n";
 # FIXME: should also compute then update the final usable LBA
 #$gptheader_special_write_needed{final_lba}=1
} # if gptbackup_problem or other_lba_unexpected

## Then can redo the primary GPT header with all that (parts and offset)
# First without the crc32, just with the refreshed
#  - $gptheader_main{other_lba}
#  - $gptheader_main{gptparts_crc32own}
# WARNING: use H32 for gpt_guid_encode(), a16 without
my $gptheader_redone_forcrc32 = pack ("a8 L L L L Q Q Q Q H32 Q L L L", $gptheader_main{signature},
 $gptheader_main{revision}, $gptheader_main{header_size}, ord("\0"), $gptheader_main{reserved},
 $gptheader_main{current_lba}, $gptheader_main{other_lba}, $gptheader_main{first_lba}, $gptheader_main{final_lba}, gpt_guid_encode($gptheader_main{disk_guid}),
 $gptheader_main{gptparts_lba}, $gptheader_main{num_parts}, $gptheader_main{part_size}, $gptheader_main{gptparts_crc32own});

# Then compute and save the redone header new crc32
my $gptheader_redone_crc32=crc32($gptheader_redone_forcrc32);

# And put this $gptheader_redone_crc32 inside instead of the null bytes
# WARNING: use H32 for gpt_guid_encode(), a16 without
my $gptheader_redone_withcrc32= pack ("a8 L L L L Q Q Q Q H32 Q L L L", $gptheader_main{signature},
 $gptheader_main{revision}, $gptheader_main{header_size}, $gptheader_redone_crc32, $gptheader_main{reserved},
 $gptheader_main{current_lba}, $gptheader_main{other_lba}, $gptheader_main{first_lba}, $gptheader_main{final_lba}, gpt_guid_encode($gptheader_main{disk_guid}),
 $gptheader_main{gptparts_lba}, $gptheader_main{num_parts}, $gptheader_main{part_size}, $gptparts_redone_crc32);

# Do we have to update? (gpt clause 2: header crc change)
if ($gptheader_main{header_crc32own} eq $gptheader_redone_crc32) {
 printf "GPT Header CRC32 (no update needed): %08x\n", $gptheader_redone_crc32;
} else {
 # The partitions could be identical, but the header changed say by changing the final lba
 printf "GPT Header CRC32: (update from %08x to:) %08x\n", $gptheader_main{header_crc32own}, $gptheader_redone_crc32;
 printf "GPT Header CRC32 change: implies writing GPT main and backup header too\n";
 print "\tUPDATE NEEDED: GPT header and backup (crc32 change)\n";
 $gptheader_write_needed=1;
 $gptheader_backup_write_needed=1;
 # Can now update the crc32
 $gptheader_main{header_crc32own}=$gptheader_redone_crc32;
 # byte-by-byte comparisons can help eyeball the differences
 # offsets 16-19 is the crc32, 56-71 the disk guid
 # TODO: could create a comparison using the hashes instead, or store $gptheader_main{raw}
 #compare_two_strings($gptheader_main{raw}, $gptheader_redone);
} # if match redone

## also redo the backups using data from the primaries (3/4 and 4/4)
# separate as may have to update just these if were trimmed or the disk imaged
if ($gptheader_write_needed>0) {
 print "\tUPDATE NEEDED: GPT header: implies a new backup header\n";
 # but they may also be required for other changes
 $gptheader_backup_write_needed=1;
}

## 3/4 backup_gptparts
# simply reuse $gptparts_redone
my $backup_gptparts_redone=$gptparts_redone;
##my $backup_gptparts_redone;
### but must sort the hash keys numerically (otherwise 0 1 10 100 101 ..)
##for my $r ( sort { $a <=> $b } keys %gpt_main_partitions) {
## # cast to int
## my $c=$r+0;
## my $partition_entry;
## if (defined($gpt_partitions{$c}{empty})) {
##  if ($gpt_partitions{$c}{empty}==1) {
##   $partition_entry=$partition_entry_empty;
##  }
## } else {
##  my $nick=$gpt_partitions{$c}{nick};
##  # WARNING: forgetting "0700" may cause plain 0700 to be recoded to 7
##  my $type_guid=$nick_to_guid{"$nick"};
##  #print "Changing partition $c GPT type to $type_guid (stored on disk as: '" . gpt_guid_encode($type_guid) . "') because of nick $gpt_partitions{$c}{nick}\n";
##  print "Matching partition $c GPT type nick $gpt_partitions{$c}{nick} by going from $type_guid to UUID $type_guid\n";
##  # WARNING: use H32 if given a string from gpt_guid_encode(), used a16 before
##  $partition_entry=pack "H32 H32 Q Q Q a$hardcoded_gpt_partname_size",
##   gpt_guid_encode($type_guid),
##   gpt_guid_encode($gpt_partitions{$c}{part_guid}),
##   $gpt_partitions{$c}{first_lba},
##   $gpt_partitions{$c}{final_lba},
##   $gpt_partitions{$c}{attr},
##   gpt_name_encode($gpt_partitions{$c}{name});
## } # if not empty
## # pad by null bytes to the $part_size
## $partition_entry .= "\x00" x ($part_size - length $partition_entry);
## # then append to redo a gpt
## $backup_gptparts_redone .= $partition_entry;
##} # for my r

# Compute the new CRC32
my $backup_gptparts_redone_crc32 = crc32($backup_gptparts_redone);
# WARNING: $backup_gptparts_crc32own is already crc32($backup_gptparts) but not sprintf'ed

#print Dumper ($gptheader_backup{header_crc32own});
#print $backup_gptparts_redone_crc32;
#print $backup_gptparts_redone_crc32;
#print Dumper ($gptheader_main{gptparts_crc32own});

# Do we have to update?
# FIXME
# if $gpt_header_backup_inaccessible==1, has no comparison

# To decide, should also compare crc to main header: could have gone out of sync
if ($gptheader_backup{header_crc32own} eq $backup_gptparts_redone_crc32 and $backup_gptparts_redone_crc32 eq $gptheader_main{gptparts_crc32own}) {
 printf "BACKUP Partition CRC32 (no update needed): %08x\n", $gptheader_backup{gptparts_crc32own};
} else {
 printf "BACKUP Partition CRC32: (update from %08x to:) %08x\n", $gptheader_backup{gptparts_crc32own}, $backup_gptparts_redone_crc32;
 # the main may be fine, but the backup gpt needs to be redone
 print "\tUPDATE NEEDED: GPT table backup (crc32 change): implies a new backup header\n";
 $gptpartst_backup_write_needed=1;
 $gptheader_backup_write_needed=1;
 # byte-by-byte comparisons can help eyeball the differences
 # TODO: make a comparison function using the hash
 # compare_two_strings($backup_gptparts_redone,$backup_gptparts);
} # if match redone

## 4/4 Then finally the backup gpt header, which needs a few swaps like lbas
# - swap backup_current_lba and backup_other_lba
# - swap gptparts_lba and backup_gptparts_lba

# first prepare CRC32, like did for the primary if wasn't canonical
# - as usual, remove own header crc32
# - plus this time do the same swap as mentionned above
#
# but for the swaps, do we know:
# - if backup_gptparts_lba and the others are good?
# - or is some recomputing needed?
#
# We still have $gptpartst_backup_size_guess, but need to find the end:
# Should *end* at LBA -2, meaning must take into account the partition size
# by default 128 partitions, 128 bytes each: so 16k before LBA-2
# could do as before, but the result should still be available:
##if ($gptheader_backup_problem>0 or defined($gptheader_main{other_lba_unexpected})) {
## printf "GPT backup address problem: implies writing GPT main and backup header too\n";
## $gptheader_write_needed=1;
## $gptheader_backup_write_needed=1
## # Use a negative number to go in the other direction, from the end
## seek $fh, $gptpartst_backup_size_guess-1*$geometry{block_size}, 2 or $gptheader_backup_problem=2;
## # This time, the same error as before is fatal.
## if ($gptheader_backup_problem >1) {
##  die "ERROR: Can't seek to backup GPT ending at LBA-2: $!\n";
## }
## # Get the offset
## my $gptbackup_offset = tell $fh;
## # Get the lba
## my $gptbackup_lba_offset=int($gptbackup_offset/$geometry{block_size});
## # Then stuff that lba into the header
## $gptheader_main{other_lba}=$gptbackup_lba_offset;
## printf "GPT backup address: $gptbackup_lba_offset from now on\n";
## # FIXME: should also compute then update the final usable LBA
##} # if gptbackup_problem or other_lba_unexpected

# already declared before
#my $gptheader_backup_problem;


## Use a negative number to go in the other direction, from the end
##seek $fh, $gptpartst_backup_size_guess-1*$geometry{block_size}, 2 or $gpt_header_backup_inaccessible=2;
# use the address that main now wants
# FIXME: $gptheader_main{other_lba}*$geometry{block_size};
seek $fh, $gptpartst_backup_size_guess-1*$geometry{block_size}, 2 or $gpt_header_backup_inaccessible=3;
if ($gpt_header_backup_inaccessible>2) {
 die "ERROR: Can't seek to backup GPT normally ending at LBA-2 now at LBA $gptheader_main{other_lba}: $!\n";
}

# this time, the same error as before is fatal.
# FIXME: the right approach would be to give up having a header backup
# but giving up earlier to store something in the GPT that'd say there's none
# then could be interpreted here as "no need to write a gpt header backup"
if ($gpt_header_backup_inaccessible>2) {
 die "ERROR: Can't seek to backup GPT ending at LBA-2: $!\n";
}
# Otherwise, get the actual offset
my $gptbackup_offset = tell $fh;
# Then stuff that lba into the header
my $gptbackup_lba_offset=int($gptbackup_offset/$geometry{block_size});

# We're now really done with the reading
close $fh or die "Can't close $path : $!\n";

# Can use this $gptbackup_lba_offset instead of $other_lba to prep for crc
# FIXME: then why not?
# along with $backup_gptparts_redone_crc32 instead of $gptparts_crc32own
my $gptbackup_header_redone_forcrc32 = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $gptheader_main{signature}, $gptheader_main{revision}, $gptheader_main{header_size}, ord("\0"), $gptheader_main{reserved},
 $gptheader_main{other_lba}, $gptheader_main{current_lba}, $gptheader_main{first_lba}, $gptheader_main{final_lba}, $gptheader_main{disk_guid},
 $gptheader_backup{gptparts_lba}, $gptheader_main{num_parts}, $gptheader_main{part_size}, $backup_gptparts_redone_crc32);

my $gptbackup_header_redone_crc32 = crc32($gptbackup_header_redone_forcrc32);

# Replace the null bytes by this $gptbackup_header_redone_crc32 instead
my $gptbackup_header_redone_withcrc32 = pack ("a8 L L L L Q Q Q Q a16 Q L L L",
 $gptheader_main{signature}, $gptheader_main{revision}, $gptheader_main{header_size}, $gptbackup_header_redone_crc32, $gptheader_main{reserved},
 $gptheader_main{other_lba}, $gptheader_main{current_lba}, $gptheader_main{first_lba}, $gptheader_main{final_lba}, $gptheader_main{disk_guid},
 $gptheader_backup{gptparts_lba}, $gptheader_main{num_parts}, $gptheader_main{part_size}, $backup_gptparts_redone_crc32);

## Also assign to the hash FIXME ?
#$gptheader_backup{gptparts_lba}=$backup_gptparts_lba;
#$gptheader_backup{gptparts_crc32own}=$backup_gptparts_crc32own;
#
# NO NEED to show the differences
#if ($noheaders <1) {
# if (crc32($backup_header_nocrc32_if_canonical) ne $header_crc32own) {
#  printf "DIVERGENCE: BACKUP CRC32 if BACKUP Canonical: %08x (if backup became main at main LBA)\n", crc32($backup_header_nocrc32_if_canonical);
# }
# if (crc32($header_nocrc32_if_noncanonical) ne $backup_header_crc32own) {
#  printf "DIVERGENCE: MAIN CRC2 if MAIN Non-Canonical: %08x (if main became backup at backup LBA)\n", crc32($header_nocrc32_if_noncanonical);
# }
# if ($backup_current_lba != $other_lba) {
#  printf "DIVERGENCE: BACKUP Current (backup) LBA: %d\n", $backup_current_lba;
# }
# if ($current_lba != $backup_other_lba) {
#  printf "DIVERGENCE: BACKUP Other (main) LBA: %d\n", $backup_other_lba;
# }
# if ($first_lba != $backup_first_lba) {
#  printf "DIVERGENCE: BACKUP First LBA: %d\n", $backup_first_lba;
# }
# if ($final_lba != $backup_final_lba) {
#  printf "DIVERGENCE: BACKUP Final LBA: %d\n", $backup_final_lba;
# }
#  #printf "GUID ko: %s\n", join "-", unpack "H8 H4 H4 H4 H12", $backup_guid;
#  # GUID: The first field is 8 bytes long and is big-endian, the second and third fields are 2 and 4 bytes long and are big-endian,
#  # but the fourth and fifth fields are 4 and 12 bytes long and are little-endian
# if ($disk_guid ne $backup_disk_guid) {
#  printf "DIVERGENCE: BACKUP Disk_GUID: %s\n", gpt_guid_decode($backup_disk_guid);
# }
# # gptparts_lba from main must diverge from backup_gptparts_lba
# printf "BACKUP GPT current (backup) LBA: %d\n", $backup_gptparts_lba;
# if ($num_parts != $backup_num_parts) {
#  printf "DIVERGENCE: BACKUP Number of partitions: %d\n", $backup_num_parts;
# }
# if ($part_size != $backup_part_size) {
#  printf "DIVERGENCE: BACKUP Partition size: %d\n", $backup_part_size;
# }
#}

########################################################### WRITE TWEAKS
# reopen the path to the block device or disk image file
open my $fhw, "+<:raw", $path or die "Can't open for read/write $path : $!\n";

## Write the new MBR
if ($mbr_write_needed>0)  {
 unless ($mbr_write_denial>0) {
  print "# WRITING NEW MBR:\n";
  # Return to the MBR offset
  seek $fhw, 446, 0 or die "Can't seek back to the MBR: $!\n";
  # Then can just write the boot code back to the MBR
  print $fhw $mbr_tweaked or die "Can't write tweaked MBR: $!";
 } else {
  print "PROBLEM: WAS REFUSED, BUT SHOULD WRITE MBR:\n";
  my $mbr_tweaked_text=unpack "H64", $mbr_tweaked;
  print "$mbr_tweaked_text;\n";
 }
} else {
  print "# NO NEED TO WRITE THE MBR\n";
}

## Write the new GPT as needed
# 1/4 start with backup header
if ($gptheader_backup_write_needed>0) {
 # FIXME: change the refuse variable name to match
 unless ($gptheader_backup_write_denial>0) {
  unless (length($gptbackup_header_redone_withcrc32) != $hardcoded_gpt_header_size) {
   # could use $gptheader_backup{current_lba} or $gptheader_main{other_lba}
   seek $fhw, $gptheader_backup{current_lba}, 0 or die "Can't seek back to the GPT BACKUP HEADER: $!\n";
   print $fhw $gptbackup_header_redone_withcrc32 or die "Can't write tweaked GPT BACKUP HEADER: $!";
  } else { # unless length
  print "PROBLEM: SIZE CHANGE FROM " . $hardcoded_gpt_header_size . " TO " . length($gptbackup_header_redone_withcrc32) . "\n";
  } # unless length
 } else { # unless needed 
  my $gptbackup_header_redone_withcrc32_text=unpack "H$hardcoded_gpt_header_size", $gptbackup_header_redone_withcrc32;
  print "PROBLEM: WAS REFUSED, BUT SHOULD WRITE GPT BACKUP HEADER:\n";
  print "$gptbackup_header_redone_withcrc32_text\n";
 } # unless refuse
} else { # else needed
 print "# NO NEED TO WRITE THE GPT BACKUP\n";
} # needed

# 2/4 then the main header
if ($gptheader_write_needed>0) {
 unless ($gptheader_write_denial>0) {
  unless (length($gptheader_redone_withcrc32) != $hardcoded_gpt_header_size) {
   seek $fhw, $gptheader_main{current_lba}, 0 or die "Can't seek back to the GPT HEADER at $gptheader_main{current_lba}: $!\n";
   print $fhw $gptheader_redone_withcrc32 or die "Can't write tweaked GPT HEADER: $!";
 } else { # unless length
  print "PROBLEM: SIZE CHANGE FROM " . $hardcoded_gpt_header_size . " TO " . length($gptheader_redone_withcrc32) . "\n";
 } # unless length
} else { # unless needed
  my $gpt_header_redone_withcrc32_text=unpack "H$hardcoded_gpt_header_size", $gptheader_redone_withcrc32;
  print "PROBLEM: WAS REFUSED, BUT SHOULD WRITE GPT HEADER:\n";
  print "$gpt_header_redone_withcrc32_text\n";
 } # unless refuse
} else { # else needed
  print "# NO NEED TO WRITE THE GPT MAIN\n";
} # needed

# 3/3 the gpt partst 
if ($gptpartst_write_needed>0) {
 unless ($gptpartst_write_denial>0) {
  unless (length($gptparts_redone) != $gptpartst_size_guess ) {
   seek $fhw, $gptheader_main{gptparts_lba}, 0 or die "Can't seek back to the GPT partitions at $gptheader_main{gptparts_lba}: $!\n";
   print $fhw $gptparts_redone or die "Can't write tweaked GPT partitions: $!";
  } else { # unless length
   print "PROBLEM: SIZE CHANGE FROM $gptpartst_size_guess TO " . length($gptparts_redone) . "\n";
  } # unless length
 } else { # unless refuse
  print "PROBLEM: WAS REFUSED, BUT SHOULD WRITE GPT PARTST\n";
  # TODO: show partition-by-partition, for the defined ones, otherwise too long
 } # unless refuse
} else { # else needed
  print "# NO NEED TO WRITE THE GPT PARTST\n";
} # if $gptpartst_write_needed

# 4/4 the gpt partst backup
if ($gptpartst_backup_write_needed>0) {
 unless ($gptheader_backup_write_denial>0) {
  unless (length($backup_gptparts_redone) != $gptpartst_backup_size_guess ) {
   seek $fhw, $gptheader_backup{gptparts_lba}, 0 or die "Can't seek back to the GPT partitions backup at $gptheader_backup{gptparts_lba}: $!\n";
   print $fhw $backup_gptparts_redone or die "Can't write tweaked GPT partst backup: $!";
  } else { # unless length
   print "PROBLEM: SIZE CHANGE FROM $gptpartst_size_guess TO " . length($gptparts_redone) . "\n";
  } # unless length
 } else { # unless refuse
  print "PROBLEM: WAS REFUSED, BUT SHOULD WRITE GPT PARTST BACKUP\n";
  # TODO: show partition-by-partition, for the defined ones, otherwise too long
 } # unless refuse
} else { # else needed
  print "# NO NEED TO WRITE THE GPT PARTST BACKUP\n";
} # if $gptpartst_backup_write_needed

# Close the path to the block device as we're done then
close $fhw or die "Can't close $path : $!\n";
