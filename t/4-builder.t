#!/usr/bin/perl

use 5.024;
use utf8;
use Test::More tests => 43;

BEGIN {
    use_ok("cherryEpg");
    use_ok("cherryEpg::Scheme");
    use_ok("cherryEpg::Player");

    `generateSampleScheduleData`;

    ok( $? == 0, "generate sample schedule data" );
} ## end BEGIN

my $cherry = cherryEpg->instance( verbose => 0 );
my $sut    = "simple";
my $target;
my $channel;

isa_ok( $cherry, "cherryEpg" );

# initialize the database structure
ok( $cherry->epg->initdb(), "init db structure" );

# delete ingest
ok( defined $cherry->deleteIngest(), "delete ingest dir" );

# version
like( $cherry->epg->version(), qr/\d+\./, "version" );

# db stats
is( scalar( @{ $cherry->epg->healthCheck() } ), 9, "db stats" );

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );

# read, build load scheme
ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

my $s = $scheme->build();

ok( $s->{isValid}, "build scheme" );

ok( $cherry->resetDatabase(), "clean/init db" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme to db" );

ok( $target = $scheme->backupScheme(), "backup scheme to archive" );

ok( $scheme->delete($target), "delete scheme from archive" );

# just to have a sample
ok( $target = $scheme->backupScheme(), "backup scheme to archive" );

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

# delete carousel
my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );

ok( defined $player->delete(), "delete carousel" );

# test building
my $eit = $cherry->epg->listEit()->@[0];
ok( $cherry->buildEit($eit), "build single eit" );

# reset version
ok( $cherry->deleteSection(), "reset section and version table" );

# multi make/build
isa_ok( $cherry->parallelUpdateEit(), "ARRAY", "make eit" );

# read, build load scheme for testing SDT, PAT and PMT building
$sut = "psi";
ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

my $s = $scheme->build();

ok( $s->{isValid}, "build scheme" );

ok( $cherry->resetDatabase(), "clean/init db" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme to db" );

# test multigrabber
my $count = scalar( $cherry->epg->listChannel()->@* );
my $grab  = $cherry->parallelGrabIngestChannel( "all", 1, 1 );
ok( scalar( $grab->@* ) == $count, "multi-grab/ingest" );

# delete carousel
my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );

ok( defined $player->delete(), "delete carousel" );

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

cmp_ok( ref $cherry->report(), 'eq', 'HASH', "overall report" );

cmp_ok( $cherry->uptime(), '>', 1, "uptime" );

like( $cherry->format(), qr/cherryTaster/, "Text report" );

