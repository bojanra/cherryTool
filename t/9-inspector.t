#!/usr/bin/perl

use 5.024;
use utf8;
use File::Path qw(remove_tree);
use Test::More tests => 17;

BEGIN {
  use_ok("cherryEpg");
  use_ok("cherryEpg::Inspector");

  `generateSampleScheduleData`;

  ok( $? == 0, "generate sample schedule data" );
} ## end BEGIN

my $cherry = cherryEpg->instance( verbose => 0 );

my $sut = 'simple';

# initialize the database structure
ok( $cherry->epg->initdb(), "init db structure" );

# delete ingest
ok( defined $cherry->deleteIngest(), "clean ingest dir" );

# read, build load scheme
my $scheme = cherryEpg::Scheme->new( verbose => 0 );
ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

ok( $scheme->build()->{isValid}, "build scheme" );

ok( $cherry->resetDatabase(), "clean/init db" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme" );

# test multigrabber
my $count = scalar( $cherry->epg->listChannel()->@* );
my $grab  = $cherry->parallelGrabIngestChannel();
ok( scalar( $grab->@* ) == $count, "multi-grab with ingest" );

# multi make/build
isa_ok( $cherry->parallelUpdateEit(), 'ARRAY', "make eit" );

my $inspect = new_ok( 'cherryEpg::Inspector' => [ verbose => 1 ], 'cherryEpg::Inspector' );

ok( $inspect->load('/var/lib/cherryepg/carousel/eit_033.cts'), "Loading&parsing" );

my $report = $inspect->report;

ok( $report =~ /Total packets/m, "Valid report" );

ok( $cherry->deleteIngest(),                                                      "clean ingest dir" );
ok( $cherry->deleteStock(),                                                       "clean stock dir" );
ok( remove_tree( $scheme->cherry->config->{core}{carousel}, { keep_root => 1 } ), "clean carousel", );

done_testing;
