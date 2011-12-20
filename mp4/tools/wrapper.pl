#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;
use Path::Class;
use List::Util qw( max );

use lib qw( lib );

use BBC::HDS::MP4::IONullWriter;
use BBC::HDS::MP4::IOReader;
use BBC::HDS::MP4::IOWriter;
use BBC::HDS::MP4::Relocator;

my @CONTAINER = qw(
 dinf edts mdia minf moof moov
 mvex stbl traf trak
);

my $src  = shift @ARGV;
my $rdr  = BBC::HDS::MP4::IOReader->new( file( $src )->openr );
my $root = walk( $rdr, atom_smasher( my $data = {} ) );
report( $data );
if ( @ARGV ) {
  my $dst = shift @ARGV;
  my $wtr = BBC::HDS::MP4::IOWriter->new( file( $dst )->openw );
  make_file( $wtr, $root );
}
else {
  layout( $root );
  print Dumper( $root );
}

sub report {
  my $data = shift;
  print hist( "Unhandled boxes", $data->{meta}{unhandled} );
  print hist( "Captured boxes",  $data->{box} );
}

sub hist {
  my ( $title, $hash ) = @_;
  return unless keys %$hash;
  my $size = sub {
    my $x = shift;
    return scalar @$x if 'ARRAY' eq ref $x;
    return $x;
  };
  my %hist = map { $_ => $size->( $hash->{$_} ) } keys %$hash;
  my @keys = sort { $hist{$b} <=> $hist{$a} } keys %hist;
  my $kw = max 1, map { length $_ } keys %hist;
  my $vw = max 1, map { length $_ } values %hist;
  my $fmt = "  %-${kw}s : %${vw}d\n";
  print "$title:\n";
  printf $fmt, $_, $hist{$_} for @keys;
}

sub escape {
  ( my $src = shift ) =~ s/ ( [ \x00-\x20 \x7f-\xff ] ) /
                            '\\x' . sprintf '%02x', ord $1 /exg;
  return $src;
}

### READING ###

sub make_dump {
  my $cb = shift;
  return sub {
    my $rdr = shift;
    print scalar( $rdr->path ), "\n";
    print $rdr->dump;
    $cb->( $rdr, @_ );
  };
}

sub full_box(&) {
  my $cb = shift;
  return sub {
    my ( $rdr, @a )  = @_;
    my ( $ver, $fl ) = parse_full_box( $rdr );
    my $rc = $cb->( $rdr, $ver, $fl, @a );
    return { version => $ver, flags => $fl, type => $rdr->fourCC, %$rc };
  };
}

sub atom_smasher {
  my $data  = shift;
  my $depth = 0;

  my $drop = sub { return };

  my $keep = sub {
    my $rdr = shift;
    return { reader => $rdr, type => $rdr->fourCC };
  };

  my $walk = sub {
    my $rdr = shift;
    return { boxes => walk( $rdr, @_ ), type => $rdr->fourCC };
  };

  my %BOX = (
    # bits we want to remember
    ftyp => $keep,
    mvhd => $keep,
    tkhd => $keep,
    mdhd => $keep,
    mdat => $keep,

    hdlr => $keep,
    udta => $keep,
    tref => $keep,

    # minf
    hmhd => $keep,
    nmhd => $keep,
    smhd => $keep,
    vmhd => $keep,

    # non-containers
    tfhd => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      return {
        track_ID => $rdr->read32,
        ( $fl & 0x000001 ) ? ( base_data_offset         => $rdr->read64 ) : (),
        ( $fl & 0x000002 ) ? ( sample_description_index => $rdr->read32 ) : (),
        ( $fl & 0x000008 ) ? ( default_sample_duration  => $rdr->read32 ) : (),
        ( $fl & 0x000010 ) ? ( default_sample_size      => $rdr->read32 ) : (),
        ( $fl & 0x000020 ) ? ( default_sample_flags     => $rdr->read32 ) : (),
      };
    },
    trun => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      my $sample_count = $rdr->read32;
      my $trun         = {
        ( $fl & 0x001 ) ? ( data_offset        => $rdr->read32 ) : (),
        ( $fl & 0x004 ) ? ( first_sample_flags => $rdr->read32 ) : (),
        run => [],
      };
      for ( 1 .. $sample_count ) {
        push @{ $trun->{run} },
         {
          ( $fl & 0x100 ) ? ( duration    => $rdr->read32 ) : (),
          ( $fl & 0x200 ) ? ( size        => $rdr->read32 ) : (),
          ( $fl & 0x400 ) ? ( flags       => $rdr->read32 ) : (),
          ( $fl & 0x800 ) ? ( time_offset => $rdr->read32 ) : (),
         };
      }
      return $trun;
    },
    stco => full_box {
      my $rdr = shift;
      { offsets => [ map { $rdr->read32 } 1 .. $rdr->read32 ] };
    },
    co64 => full_box {
      my $rdr = shift;
      { offsets => [ map { $rdr->read64 } 1 .. $rdr->read32 ] };
    },
    ctts => full_box {
      my $rdr = shift;
      { offsets =>
         [ map { { count => $rdr->read32, offset => $rdr->read32, } } 1 .. $rdr->read32 ]
      };
    },
    url => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      return { flags => $fl, ( $fl & 0x001 ) ? () : ( location => $rdr->readZ ) };
    },
    urn => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      return {
        name => $rdr->readZ,
        ( $fl & 0x001 ) ? () : ( location => $rdr->readZ )
      };
    },
    dref => full_box {
      my ( $rdr, $ver, $fl, $smasher ) = @_;
      { dref => [ map { walk_box( $rdr, $smasher ) } 1 .. $rdr->read32 ] };
    },
    elst => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      my $rw = $ver >= 1 ? sub { $rdr->read64 } : sub { $rdr->read32 };
      return {
        list => [
          map {
            {
              segment_duration    => $rw->(),
              media_time          => $rw->(),
              media_rate_integer  => $rdr->read16,
              media_rate_fraction => $rdr->read16,
            }
           } 1 .. $rdr->read32
        ]
      };
    },
    mehd => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      return { fragment_duration => ( $ver >= 1 ) ? $rdr->read64 : $rdr->read32 };
    },
    trex => full_box {
      my ( $rdr, $ver, $fl ) = @_;
      return {
        track_ID                         => $rdr->read32,
        default_sample_description_index => $rdr->read32,
        default_sample_duration          => $rdr->read32,
        default_sample_size              => $rdr->read32,
        default_sample_flags             => $rdr->read32,
      };
    },

    # ignore
    abst => $keep,
    afra => $keep,
    mfhd => $keep,
    free => $keep,

    # unknown
    stsc => $keep,
    stsd => $keep,
    stss => $keep,
    stsz => $keep,
    stts => $keep,
  );

  $BOX{$_} = $walk for @CONTAINER;

  my $cb = sub {
    my ( $rdr, $smasher ) = @_;
    my $pad  = '  ' x $depth;
    my $type = $rdr->fourCC;
    #    printf "%08x %10d%s%s\n", $rdr->start, $rdr->size, $pad, $type;
    if ( my $hdlr = $BOX{$type} ) {
      my $rc = $hdlr->( $rdr, $smasher );
      push @{ $data->{box}{ $rdr->path } }, $rc;
      push @{ $data->{flat}{$type} }, $rc;
      return $rc;
    }
    $data->{meta}{unhandled}{ escape( scalar $rdr->path ) }++;
    return;
  };

  return sub {
    $depth++;
    my $rc = $cb->( @_ );
    $depth--;
    return $rc;
  };
}

sub parse_full_box {
  my $rdr = shift;
  return ( $rdr->read8, $rdr->read24 );
}

sub parse_box {
  my $rdr = shift;

  my ( $size, $type ) = ( $rdr->read32, $rdr->read4CC );
  $type =~ s/\s+$//;
  $size = $rdr->read64 if $size == 1;
  $size = $rdr->size   if $size == 0;

  return ( $size, $type );
}

sub walk_box {
  my ( $rdr, $smasher ) = @_;
  my $box = $rdr->tell;
  my ( $size, $type ) = parse_box( $rdr );
  my $pos = $rdr->tell;
  my $rc  = $smasher->(
    BBC::HDS::MP4::IOReader->new( [ $rdr, $type ], $pos, $size - ( $pos - $box ) ),
    $smasher
  );
  $rdr->seek( $box + $size, 0 );
  return $rc;
}

sub walk {
  my ( $rdr, $smasher ) = @_;
  my @rc = ();
  while ( $rdr->avail ) {
    push @rc, walk_box( $rdr, $smasher );
  }
  return \@rc;
}

### WRITING ###

sub push_box {
  my ( $wtr, $pusher, $box, $long, $cb ) = @_;

  my $pos = $wtr->tell;

  $wtr->write32( 1 );
  $wtr->write4CC( $box->{type} );

  $wtr->write64( 1 ) if $long;

  $box->{_}{start} = $wtr->tell;
  $cb->( $wtr, $pusher, $box );
  $box->{_}{end} = my $end = $wtr->tell;

  if ( $long ) {
    $wtr->seek( $pos + 8, 0 );
    $wtr->write64( $end - $pos );
  }
  else {
    $wtr->seek( $pos, 0 );
    $wtr->write32( $end - $pos );
  }

  $wtr->seek( $end, 0 );
  return;
}

sub push_full(&) {
  my $cb = shift;
  return sub {
    my ( $wtr, $pusher, $box, @a ) = @_;
    $wtr->write8( $box->{version} );
    $wtr->write24( $box->{flags} );
    return $cb->( $wtr, $pusher, $box, @a );
  };
}

sub write_boxes {
  my ( $wtr, $pusher, $boxes ) = @_;
  for my $box ( @$boxes ) {
    next unless defined $box;
    $pusher->( $wtr, $pusher, $box );
  }
}

sub layout {
  my ( $root ) = @_;
  write_boxes( BBC::HDS::MP4::IONullWriter->new,
    box_pusher( BBC::HDS::MP4::Relocator->new ), $root );
}

sub reloc_index {
  my $boxes = shift;
  my @idx   = @_;

  for my $box ( @$boxes ) {
    next unless $box;
    if ( my $cont = $box->{boxes} ) {
      push @idx, reloc_index( $box->{boxes} );
    }
    elsif ( my $rdr = $box->{reader} ) {
      my ( $sst, $sen ) = $rdr->range;
      my ( $dst, $den ) = ( $box->{_}{start}, $box->{_}{end} );
      my $ssz = $sen - $sst;
      my $dsz = $den - $dst;
      die "Source / destination size mismatch: $ssz / $dsz" unless $ssz == $dsz;
      push @idx, [ $sst, $sen, $dst - $sst ];
    }
  }

  return @idx;
}

sub make_file {
  my ( $wtr, $boxes ) = @_;
  layout( $boxes );
  write_boxes( $wtr, box_pusher( BBC::HDS::MP4::Relocator->new( reloc_index( $boxes ) ) ),
    $boxes );
}

sub box_pusher {
  my $reloc = shift;

  my $copy = sub {
    my ( $wtr, $pusher, $box ) = @_;

    my $rdr = $box->{reader};
    if ( $wtr->is_null ) {
      $wtr->seek( $rdr->size, 1 );
      return;
    }
    $rdr->seek( 0, 0 );
    while ( 1 ) {
      my $data = $rdr->read( 65536 );
      last unless length $data;
      $wtr->write( $data );
    }
  };

  my $container = sub {
    my ( $wtr, $pusher, $box ) = @_;
    write_boxes( $wtr, $pusher, $box->{boxes} );
  };

  my %IS_LONG = map { $_ => 1 } qw( mdat );

  my %BOX = (
    # non-containers
    tfhd => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my $fl = $box->{flags};

      $wtr->write32( $box->{track_ID} );
      $wtr->write64( $box->{base_data_offset}         || 0 ) if $fl & 0x000001;
      $wtr->write32( $box->{sample_description_index} || 0 ) if $fl & 0x000002;
      $wtr->write32( $box->{default_sample_duration}  || 0 ) if $fl & 0x000008;
      $wtr->write32( $box->{default_sample_size}      || 0 ) if $fl & 0x000010;
      $wtr->write32( $box->{default_sample_flags}     || 0 ) if $fl & 0x000020;
    },
    trun => push_full {
      my ( $wtr, $pusher, $box ) = @_;

      my $fl = $box->{flags};
      my @r  = $box->{run};

      $wtr->write32( scalar @r );

      $wtr->write32( $box->{data_offset}        || 0 ) if $fl & 0x001;
      $wtr->write32( $box->{first_sample_flags} || 0 ) if $fl & 0x004;

      for my $r ( @r ) {
        $wtr->write32( $box->{duration}    || 0 ) if $fl & 0x100;
        $wtr->write32( $box->{size}        || 0 ) if $fl & 0x200;
        $wtr->write32( $box->{flags}       || 0 ) if $fl & 0x400;
        $wtr->write32( $box->{time_offset} || 0 ) if $fl & 0x800;
      }
    },
    stco => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my @ofs = $reloc->reloc( @{ $box->{offsets} } );
      $wtr->write32( scalar( @ofs ), @ofs );
    },
    co64 => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my @ofs = $reloc->reloc( @{ $box->{offsets} } );
      $wtr->write32( scalar @ofs );
      $wtr->write64( @ofs );
    },
    ctts => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my @ofs = @{ $box->{offsets} };
      $wtr->write32( scalar @ofs );
      $wtr->write32( $_->{count}, $_->{offset} ) for @ofs;
    },
    url => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my $fl = $box->{flags};
      $wtr->writeZ( $box->{location} ) if !( $fl & 0x001 );
    },
    urn => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my $fl = $box->{flags};
      $wtr->writeZ( $box->{name} );
      $wtr->writeZ( $box->{location} ) if !( $fl & 0x001 );
    },
    dref => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      $wtr->write32( scalar @{ $box->{dref} } );
      write_boxes( $wtr, $pusher, $box->{dref} );
    },
    elst => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my $ver  = $box->{version};
      my @list = @{ $box->{list} };
      $wtr->write32( scalar @list );
      for my $l ( @list ) {
        $wtr->write64( $l->{segment_duration}, $l->{media_time} ) if $ver > 1;
        $wtr->write32( $l->{segment_duration}, $l->{media_time} ) if $ver <= 1;
        $wtr->write16( $l->{media_rate_integer}, $l->{media_rate_fraction} );
      }
    },
    mehd => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      my $ver = $box->{version};
      if ( $ver > 1 ) {
        $wtr->write64( $box->{fragment_duration} || 0 );
      }
      else {
        $wtr->write32( $box->{fragment_duration} || 0 );
      }
    },
    trex => push_full {
      my ( $wtr, $pusher, $box ) = @_;
      $wtr->write32(
        @{$box}{
          'track_ID',                'default_sample_description_index',
          'default_sample_duration', 'default_sample_size',
          'default_sample_flags',
         }
      );
    },
  );

  $BOX{$_} = $container for @CONTAINER;

  return sub {
    my ( $wtr, $pusher, $box ) = @_;

    my $type = $box->{type};

    # HACK
    my $long = 0;    #$IS_LONG{$type} || 0;
    $BOX{$type} = $copy if $box->{reader};

    if ( my $hdlr = $BOX{$type} ) {
      push_box( $wtr, $pusher, $box, $long, $hdlr );
    }
  };
}

# vim:ts=2:sw=2:sts=2:et:ft=perl

