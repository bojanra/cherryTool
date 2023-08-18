#!/usr/bin/perl

use 5.024;
use utf8;
use File::Temp qw( tempfile tempdir);
use Gzip::Faster;
use Path::Class;
use Test::More tests => 40;
use YAML::XS;

BEGIN {
  use_ok("cherryEpg::Player");
}

my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );
my $serialized;
my $imported;

my $chunk =
    "G@\0\x10\0\0°\x11\0\x01×\0\0\0\0à\x10\0\x01àcS·­Sÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿÿ";
my $meta = {
  title    => "Test chunk delete afterwards",
  dst      => '239.10.10.1:5500',
  interval => 2000,
  source   => "table source as text",
};

my ( $fh, $filename ) = tempfile( TEMPLATE => 'testXXXX', UNLINK => 1, SUFFIX => '.ets.gz' );

# generate temporary ETS file
my $serialized = YAML::XS::Dump( {
    title    => "Handmade sample",
    dst      => '239.10.10.9:5500',
    interval => 2000,
    source   => "table source as text",
    ts       => $chunk
  }
);

gzip_to_file( $serialized, $filename );
my @sampleLoad = $player->load($filename);
ok( $sampleLoad[0] ne "", "load temp file" );

my $dummyDir = tempdir(
  TEMPLATE => 'tempXXXXX',
  DIR      => dir( $player->cherry->config->{core}{carousel} ),
  CLEANUP  => 1,
);

my $dirname = $dummyDir;
$dirname =~ s|^.+/||;

foreach my $testdir ( '/', $dirname ) {

  note("testing $testdir");

  my $carouselPath = dir( $player->cherry->config->{core}{carousel}, $testdir );

  ok( -d -W $carouselPath, "carousel directory writable" );

  ok( defined $player->delete($testdir), "delete carousel" );

  my $copied = $player->save( $testdir, $filename );
  ok( -e file( $carouselPath, $copied . '.ets.gz' ), "copy .ets.gz" );

  my $dummyContent = "--TEST--";
  my $saved        = $player->save( $testdir, $dummyContent );
  my $path         = file( $carouselPath, $saved . '.ets.gz' );
  ok( -e $path, "save content to .ets.gz" );

  my $data = gunzip_file($path);
  is( $data, $dummyContent, "content is correct" );

  my $x       = $player->save( $testdir, $filename );
  my @forTest = $player->load( $testdir, $copied );

  ok( $player->arm( $testdir, @forTest ), "arm temp file" );

  is( $player->play( $testdir, $copied ), file( $carouselPath, $copied . '.cts' ), "play temp file" );
  ok( -e file( $carouselPath, $copied . '.cts' ), "playing temp file" );

  # list carousel
  my @list = $player->list($testdir)->@*;
  ok( scalar @list == 2,     "list carousel" );
  ok( $list[0]->{duplicate}, "detect duplcates" );

  # check if playing
  ok( $player->isPlaying( $testdir,  $copied ), "test playing" );
  ok( !$player->isPlaying( $testdir, 'xxx' ),   "test playing II" );

  ok( $player->stop( $testdir, $copied ),          "stop temp file" );
  ok( !-e file( $carouselPath, $copied . '.cts' ), "stopped temp file" );
} ## end foreach my $testdir ( '/', ...)

ok( defined $player->delete('/'), "delete carousel - cleanup" );

# generate cts.gz from ts ¸
{
  # simple chunk
  my ( $dh, $tsfile ) = tempfile( TEMPLATE => 'chunkXXXX', UNLINK => 1, SUFFIX => '.ts' );
  binmode($dh);
  my $ts = pack( "CnC", 0x47, 55, 13 ) . ( '.' x 184 );
  $ts .= $ts;
  print( $dh $ts );
  close($dh);

  my $generated = $player->compose( {
      title    => "Simple title",
      interval => 2000,
      dst      => "239.10.10.10:5500",
    },
    $tsfile
  );
  ok( -e file( $player->cherry->config->{core}{carousel}, $generated . '.ets.gz' ), "compose .ets.gz" );

  $player->delete('/');

  # detect incorrect meta
  ok(
    !$player->compose( {
        title    => "Simple title",
        interval => 2000,
      },
      $tsfile
    ),
    "detect incorrect meta - missing dst"
  );

  ok(
    !$player->compose( {
        title => "Simple title",
        dst   => "239.10.10.10:5500",
      },
      $tsfile
    ),
    "detect incorrect meta - missing interval"
  );

  ( $dh, $tsfile ) = tempfile( TEMPLATE => 'chunkXXXX', UNLINK => 1, SUFFIX => '.ts' );
  binmode($dh);

  # chunk with 2 different PIDs
  $ts = pack( "CnC", 0x47, 55, 13 ) . ( '.' x 184 );
  $ts .= pack( "CnC", 0x47, 234, 13 ) . ( '.' x 184 );
  print( $dh $ts );
  close($dh);

  ok(
    !$player->compose( {
        title    => "Simple title",
        interval => 2000,
        dst      => "239.10.10.10:5500",
      },
      $tsfile
    ),
    "detect different PID"
  );
};

my $testfile = "DEMO";

# add dummy stuff to meta
$meta->{dummy} = 'x' x 200;
ok( !$player->arm( '/', $testfile, $meta, \$chunk ), "fail arm w/to long meta" );
delete( $meta->{dummy} );

# add chunk with size not multiple of 188 bytes
my $dummy = 'X';
ok( !$player->arm( '/', $testfile, $meta, \$dummy ), "fail arm chunk w/incorrect size" );

my ( $fh, $filename ) = tempfile( TEMPLATE => 'testXXXX', UNLINK => 1, SUFFIX => '.ets.gz' );

# generate temporary ETS file with missing dst field
$serialized = YAML::XS::Dump( {
    title    => "Handmade sample",
    interval => 2000,
    source   => "table source as text",
    ts       => $chunk
  }
);

gzip_to_file( $serialized, $filename );
ok( !$player->load($filename), "fail load incorrect .ets.gz file" );

# generate temporary ETS file without ts
$serialized = YAML::XS::Dump( {
    title    => "Handmade sample",
    dst      => '239.10.10.9:5500',
    interval => 2000,
    source   => "table source as text",
  }
);

gzip_to_file( $serialized, $filename );
ok( !$player->load($filename), "failed load .ets.gz w/missing ts" );

done_testing;
