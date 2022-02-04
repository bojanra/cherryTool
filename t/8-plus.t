#!/usr/bin/perl

use File::Rsync;

use Test::More tests => 32;

BEGIN {
    use_ok("cherryEpg");
    use_ok("cherryEpg::Scheme");

    `generateSampleScheduleData`;

    ok( $? == 0, "generate sample schedule data" );
} ## end BEGIN

my $cherry = cherryEpg->instance( verbose => 0 );

isa_ok( $cherry, 'cherryEpg' );

my $scheme = new_ok( cherryEpg::Scheme => [ verbose => 0 ], 'cherryEpg::Scheme' );

foreach my $sut (qw( xsid multi large)) {
    note("test $sut scheme");

SKIP: {
        skip 'large test in production', 9 if $sut eq 'large' and $ENV{'DANCER_ENVIRONMENT'} eq 'production';

        ok( defined $cherry->ingestDelete(), "delete ingest dir" );
        ok( $cherry->databaseReset(),        "clean/init db" );

        # read, build load scheme
        ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

        my $s = $scheme->build();
        ok( $s->{isValid}, "build scheme" );

        my ( $success, $error ) = $scheme->push();
        ok( scalar(@$success) && !scalar(@$error), "load scheme" );

        # test multigrabber
        my $count = scalar( $cherry->epg->listChannel($channelId)->@* );

        my $grab = $cherry->channelMulti( 'all', 1, 1 );
        ok( scalar( $grab->@* ) == $count, "multi-grab with ingest" );

        # delete carousel
        my $player = new_ok( cherryEpg::Player => [ verbose => 0 ], 'cherryEpg::Player' );

        ok( defined $player->delete(), "delete carousel" );

        # multi make/build
        isa_ok( $cherry->eitMulti(), 'ARRAY', 'make eit' );
    } ## end SKIP:
} ## end foreach my $sut (qw( xsid multi large))


