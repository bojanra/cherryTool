#!/usr/bin/perl

use File::Rsync;

use Test::More tests => 45;

BEGIN {
    use_ok("cherryEpg");
    use_ok("cherryEpg::Scheme");

}

my $cherry = cherryEpg->instance( verbose => 0 );

isa_ok( $cherry, 'cherryEpg' );

subtest "copy sample schedule data" => sub {
    my $stock = $cherry->config->{core}{stock};

    # sync test schedule from testData directory to stock
    my $rsync = File::Rsync->new(
        recursive => 1,
        times     => 1,
        perms     => 1,
        group     => 1,
        owner     => 1,
        verbose   => 2,
        src       => ['t/testData/'],
        dest      => $stock
    );

    ok( $rsync->exec(), "copy sample schedule data" );
    done_testing();
};

my $scheme = new_ok( cherryEpg::Scheme => [ verbose => 0 ], 'cherryEpg::Scheme' );

my $sut = 'parser';
ok( defined $cherry->ingestDelete(), "delete ingest dir" );
ok( $cherry->databaseReset(),        "clean/init db" );

# read, build load scheme
ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

my $s = $scheme->build();
ok( $s->{isValid}, "build scheme" );

my ( $success, $error ) = $scheme->push();
ok( scalar(@$success) && !scalar(@$error), "load scheme" );

foreach my $channel ( $cherry->epg->listChannel($channelId)->@* ) {
    my $grab     = $cherry->channelGrab($channel);
    my $ingest   = $cherry->channelIngest($channel);
    my ($parser) = split( /\?/, $channel->{parser} );
    ok( ref($grab) eq 'ARRAY' && scalar(@$grab) > 0 && scalar(@$ingest) && !scalar( @{ $$ingest[0]->{errorList} } ),
        "$parser test with channel $channel->{channel_id}" );
} ## end foreach my $channel ( $cherry...)
