#!/usr/bin/perl

use 5.024;
use utf8;
use File::Temp qw( tempfile);
use Gzip::Faster;
use Path::Class;
use Test::More tests => 21;
use YAML::XS;

BEGIN {
    use_ok("cherryEpg::Player");
}

my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], 'cherryEpg::Player' );
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

my $carouselPath = $player->cherry->config->{core}{carousel};
my $testfile     = 'testing';

ok( -d -W $carouselPath, 'carousel directory writable' );

ok( defined $player->delete(), "delete carousel" );

ok( $player->arm( $testfile, $meta, \$chunk ), "arm chunk" );
ok( -e $carouselPath . $testfile . '.tmp',     "armmed chunk" );

like( $player->play($testfile), qr/$testfile\.cts/, "play chunk" );
ok( -e $carouselPath . $testfile . '.cts', "playing chunk" );

ok( $player->stop($testfile),               "stop chunk" );
ok( !-e $carouselPath . $testfile . '.cts', "delete o.k." );

# add dummy stuff to meta
$meta->{dummy} = 'x' x 200;
ok( !$player->arm( $testfile, $meta, \$chunk ), "fail arm w/to long meta" );
delete( $meta->{dummy} );

# add chunk with size not multiple of 188 bytes
my $dummy = 'X';
ok( !$player->arm( $testfile, $meta, \$dummy ), "fail arm chunk w/incorrect size" );

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
my @field = $player->load($filename);
ok( $field[0] ne "",      "load temp file" );
ok( $player->arm(@field), "arm temp file" );
is( $player->play( $field[0] ), $carouselPath . $field[0] . '.cts', "play temp file" );

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
$imported = $player->copy($filename);
ok( $imported,                 "import .ets.gz" );
ok( !$player->load($imported), "failed load imported .ets.gz w/missing ts" );

# list carousel
ok( ref( $player->list() ) eq 'ARRAY', "list carousel" );

is( $player->stop(),   1, "stop carousel" );
is( $player->delete(), 1, "delete carousel" );
