#!/usr/bin/perl

use 5.024;
use utf8;
use File::Path qw(remove_tree);
use Test::More tests => 20;

BEGIN {
  use_ok("cherryEpg");
  use_ok("cherryEpg::Scheme");
}

my $cherry = cherryEpg->instance( verbose => 0 );

isa_ok( $cherry, "cherryEpg" );

my $stock = $cherry->config->{core}{stock};

`generateStaticSchedule -t "Sport" -s 1 > $stock/sport.xml`;
ok( $? == 0, "generate static sport" );

`generateStaticSchedule -t "News" -s 1 > $stock/news.xml`;
ok( $? == 0, "generate static news" );

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );

ok( defined $cherry->deleteIngest(), "clean ingest dir" );
ok( $cherry->resetDatabase(),        "clean/init db" );

# read, build load scheme
ok( $scheme->readXLS("t/scheme/multinet.xls"), "read .xls" );

my $s = $scheme->build();
ok( $s->{isValid}, "build scheme" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme" );

my $backup = $scheme->backup();

# test multigrabber
my $count = scalar( $cherry->epg->listChannel()->@* );

my $grab = $cherry->parallelGrabIngestChannel( 'all', 1, 1 );
ok( scalar( $grab->@* ) == $count, "multi-grab with ingest" );

# delete carousel
my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );

ok( defined $player->delete('/'), "delete carousel" );

# multi make/build
isa_ok( $cherry->parallelUpdateEit(), 'ARRAY', "make eit" );

my ($v) = $cherry->epg->dbh->selectrow_array("SELECT count(DISTINCT service_id) FROM version");

is( $v, 2, "multinet service mapping" );

ok( $scheme->delete($backup), "delete scheme from archive" );

ok( $cherry->deleteIngest(),                                                      "clean ingest dir" );
ok( $cherry->deleteStock(),                                                       "clean stock dir" );
ok( remove_tree( $scheme->cherry->config->{core}{carousel}, { keep_root => 1 } ), "clean carousel", );
