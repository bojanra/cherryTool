#!/usr/bin/perl

use 5.024;
use utf8;
use File::Path qw(remove_tree);
use Test::More tests => 47;

BEGIN {
  use_ok("cherryEpg");
  use_ok("cherryEpg::Scheme");
  use_ok("cherryEpg::Player");

  `generateSampleScheduleData`;

  ok( $? == 0, "generate sample schedule data" );
} ## end BEGIN

my $cherry = cherryEpg->instance( verbose => 0 );
my $target;
my $channel;

isa_ok( $cherry, "cherryEpg" );

# initialize the database structure
ok( $cherry->epg->initdb(), "init db structure" );

# clean ingest
ok( defined $cherry->deleteIngest(), "clean ingest dir" );

# version
like( $cherry->epg->version(), qr/\d+\./, "version" );

# db stats
is( scalar( @{ $cherry->epg->healthCheck() } ), 9, "db stats" );

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );

# read, build load scheme for testing SDT, PAT and PMT building
ok( $scheme->readXLS("t/scheme/psi.xls"), "read .xls" );

my $s = $scheme->build();

ok( $s->{isValid}, "build scheme" );

ok( $cherry->resetDatabase(), "clean/init db" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme to db" );

my $backup = $scheme->backup();

# test multigrabber
my $count = scalar( $cherry->epg->listChannel()->@* );
my $grab  = $cherry->parallelGrabIngestChannel( "all", 1, 1 );
ok( scalar( $grab->@* ) == $count, "multi-grab/ingest" );

# clean carousel
my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );

ok( defined $player->delete(), "clean carousel" );

# multi make/build
isa_ok( $cherry->parallelUpdateEit(), "ARRAY", "make eit" );

# statistics&monitoring
is( scalar $cherry->eventBudget()->@*, 8, "eventbudget statistics" );

cmp_ok( ref $cherry->ringelspiel(), 'eq', 'HASH', "ringelspiel pooling" );

cmp_ok( ref $cherry->versionReport(), 'eq', 'HASH', "software version report" );

cmp_ok( ref $cherry->databaseReport(), 'eq', 'HASH', "database report" );

cmp_ok( ref $cherry->ringelspielReport(), 'eq', 'HASH', "ringelspiel report" );

cmp_ok( ref $cherry->eventBudgetReport(), 'eq', 'HASH', "eventBudget report" );

cmp_ok( ref $cherry->ntpReport(), 'eq', 'HASH', "ntp report" );

cmp_ok( ref $cherry->lingerReport(), 'eq', 'HASH', "linger report" );

cmp_ok( ref $cherry->report(), 'eq', 'HASH', "overall report" );

cmp_ok( $cherry->uptime(), '>', 1, "uptime" );

like( $cherry->format(), qr/cherryTaster/, "Text report" );

ok( $scheme->delete($backup), "clean archive" );

# read, build load scheme
ok( $scheme->readXLS("t/scheme/simple.xls"), "read .xls" );

my $s = $scheme->build();

ok( $s->{isValid}, "build scheme" );

ok( $cherry->resetDatabase(), "clean/init db" );

# clean ingest
ok( defined $cherry->deleteIngest(), "clean ingest dir" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme to db" );

# keep as sample
ok( $target = $scheme->backup(), "backup scheme to archive" );

# test multigrabber
my $count = scalar( $cherry->epg->listChannel()->@* );
my $grab  = $cherry->parallelGrabIngestChannel( "all", 1, 1 );
ok( scalar( $grab->@* ) == $count, "multi-grab/ingest" );

# export schedule to XML
$channel = $cherry->epg->listChannel()->@[0];
my $content = $cherry->epg->exportScheduleData( [$channel], "localhost", "eng" );
ok( $content && length($content) > 30000, "export channel in XMLTV format" );

# reset/remove md5 file
$channel = ${ $cherry->epg->listChannel() }[0];
my $result = $cherry->resetChannel($channel);
ok( $result, "Reset done for $channel->{name}" );

# clean  carousel
my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );

ok( defined $player->delete('/'), "clean carousel" );

# test building
my $eit = $cherry->epg->listEit()->@[0];
ok( $cherry->buildEit($eit), "build single eit" );

# reset version
ok( $cherry->deleteSection(), "reset section and version table" );

# multi make/build
isa_ok( $cherry->parallelUpdateEit(), "ARRAY", "make eit" );

# clean afterwards
ok( $cherry->deleteStock(),  "clean stock dir" );
ok( $cherry->deleteIngest(), "clean ingest dir" );

# the carousel is left for demo purposes
ok( remove_tree( $scheme->cherry->config->{core}{carousel} . "COMMON.linger" ), "remove linger carousel" );


