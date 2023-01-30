#!/usr/bin/perl

use 5.024;
use File::Rsync;
use Test::More tests => 35;

BEGIN {
    use_ok("cherryEpg");
    use_ok("cherryEpg::Scheme");

    `generateSampleScheduleData`;

    ok( $? == 0, "generate sample schedule data" );
} ## end BEGIN

my $cherry = cherryEpg->instance( verbose => 0 );

isa_ok( $cherry, "cherryEpg" );

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );

foreach my $sut (qw( xsid multi large)) {
    note("test $sut scheme");

SKIP: {
        skip "large test in production", 10 if $sut eq 'large' and ( 1 || $ENV{'DANCER_ENVIRONMENT'} eq 'production' );

        ok( defined $cherry->deleteIngest(), "delete ingest dir" );
        ok( $cherry->resetDatabase(),        "clean/init db" );

        # read, build load scheme
        ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

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

        ok( $scheme->delete($backup), "delete scheme from archive" );
    } ## end SKIP:
} ## end foreach my $sut (qw( xsid multi large))


