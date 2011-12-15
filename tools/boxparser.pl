#!/usr/bin/env perl

package main;

use strict;
use warnings;

use lib qw( lib );

use Data::Dumper;
use Data::Hexdumper;
use Path::Class;
use BBC::HDS::Bootstrap::ByteReader;

my $src = shift @ARGV;
my $bs  = file( $src )->slurp;

my $boxes = get_boxes( BBC::HDS::Bootstrap::ByteReader->new( $bs ) );
print Dumper( $boxes );

sub get_box_info {
  my $rdr = shift;

  my $pos  = $rdr->pos;
  my $size = $rdr->read32;
  my $type = $rdr->read4CC;
  $size = $rdr->read64 if $size == 1;

  return {
    size => $size - ( $rdr->pos - $pos ),
    type => $type
  };
}

sub get_full_box {
  my ( $rdr, $bi ) = @_;

  my $ver   = $rdr->read8;
  my $flags = $rdr->read24;

  return {
    %$bi,
    ver   => $ver,
    flags => $flags,
  };
}

sub get_boxes {
  my $rdr   = shift;
  my @boxes = ();
  while ( $rdr->avail ) {
    my $bi = get_box_info( $rdr );

    if ( $bi->{type} eq 'abst' ) {
      push @boxes, get_bootstrap_box( $rdr, $bi );
    }
    elsif ( $bi->{type} eq 'afra' ) {
      push @boxes, get_frag_ra_box( $rdr, $bi );
    }
    elsif ( $bi->{type} eq 'mdat' ) {
      push @boxes, get_media_data_box( $rdr, $bi );
    }
    else {
      die "unhandled atom: $bi->{type}\n";
      $rdr->read( $bi->{size} - 8 );
    }
  }
  return \@boxes;
}

sub expect_box {
  my ( $rdr, $type ) = @_;
  my $bi = get_box_info( $rdr );
  die "Expected '$type', got '$bi->{type}'" unless $bi->{type} eq $type;
  return get_full_box( $rdr, $bi );
}

sub get_segment_runs {
  my $rdr = shift;
  expect_box( $rdr, 'asrt' );
  return {
    quality => $rdr->readZs,
    runs    => $rdr->read32ar(
      sub {
        my $rdr = shift;
        {
          first => $rdr->read32,
          frags => $rdr->read32
        };
      }
    ),
  };
}

sub get_frag_duration_pair {
  my $rdr = shift;
  my $rec = {
    first     => $rdr->read32,
    timestamp => $rdr->read64,
    duration  => $rdr->read32,
  };
  $rec->{discontinuity} = $rdr->read8 if $rec->{duration} == 0;
  return $rec;
}

sub get_fragment_runs {
  my $rdr = shift;
  expect_box( $rdr, 'afrt' );
  return {
    timescale => $rdr->read32,
    quality   => $rdr->readZs,
    runs      => $rdr->read32ar( \&get_frag_duration_pair ),
  };
}

sub get_bootstrap_box {
  my ( $rdr, $bi ) = @_;

  my %bs = (
    bi                    => get_full_box( $rdr, $bi ),
    version               => $rdr->read32,
    flags                 => $rdr->read8,
    time_scale            => $rdr->read32,
    current_media_time    => $rdr->read64,
    smpte_timecode_offset => $rdr->read64,
    movie_identifier      => $rdr->readZ,
    servers               => $rdr->readZs,
    quality               => $rdr->readZs,
    drm_data              => $rdr->readZ,
    metadata              => $rdr->readZ,
    segment_run_tables    => $rdr->read8ar( \&get_segment_runs ),
    fragment_run_tables   => $rdr->read8ar( \&get_fragment_runs ),
  );

  $bs{profile} = $bs{flags} >> 6;
  $bs{live}    = ( $bs{flags} & 0x20 ) ? 1 : 0;
  $bs{update}  = ( $bs{flags} & 0x01 ) ? 1 : 0;

  return \%bs;
}

sub get_frag_ra_box {
  my ( $rdr, $bi ) = @_;
  my $fbi = get_full_box( $rdr, $bi );

  my $sizes = $rdr->read8;

  my $rd_id
   = ( $sizes & 0x80 ) ? sub { $rdr->read32 } : sub { $rdr->read16 };
  my $rd_ofs
   = ( $sizes & 0x40 ) ? sub { $rdr->read64 } : sub { $rdr->read32 };

  my %ra = (
    bi         => $fbi,
    sizes      => $sizes,
    time_scale => $rdr->read32,
    local      => $rdr->read32ar(
      sub {
        my $rdr = shift;
        return {
          time   => $rdr->read64,
          offset => $rd_ofs->()
        };
      }
    ),
  );

  if ( $sizes & 0x20 ) {
    $ra{gloabls} = $rdr->read32ar(
      sub {
        my $rdr = shift;
        return {
          time             => $rdr->read64(),
          segment          => $rd_id->(),
          fragment         => $rd_id->(),
          afra_offset      => $rd_ofs->(),
          offset_from_afra => $rd_ofs->(),
        };
      }
    );
  }

  return \%ra;
}

sub get_media_data_box {
  my ( $rdr, $bi ) = @_;
  return {
    bi   => $bi,
    data => $rdr->read( $bi->{size} )
  };
}

# vim:ts=2:sw=2:sts=2:et:ft=perl

