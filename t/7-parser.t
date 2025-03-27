#!/usr/bin/perl

use 5.024;
use utf8;
use File::Path qw(remove_tree);
use File::Rsync;
use Test::More tests => 71;

BEGIN {
  use_ok("cherryEpg");
  use_ok("cherryEpg::Scheme");
}

my $cherry = cherryEpg->instance( verbose => 0 );

isa_ok( $cherry, "cherryEpg" );

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
}; ## end "copy sample schedule data" => sub

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );

my $sut = 'parser';
ok( defined $cherry->deleteIngest(), "clean ingest dir" );
ok( $cherry->resetDatabase(),        "clean/init db" );

# read, build load scheme
ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

ok( $scheme->build()->{isValid}, "build scheme" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) && !scalar(@$error), "load scheme" );

my $backup = $scheme->backup();

foreach my $channel ( $cherry->epg->listChannel()->@* ) {
  my $grab     = $cherry->grabChannel($channel);
  my $ingest   = $cherry->ingestChannel($channel);
  my ($parser) = split( /\?/, $channel->{parser} );
  ok( ref($grab) eq 'ARRAY' && scalar(@$grab) > 0 && scalar(@$ingest) && !scalar( @{ $$ingest[0]->{errorList} } ),
    "$parser test with channel $channel->{channel_id}" );
} ## end foreach my $channel ( $cherry...)

ok( $scheme->delete($backup),                                                     "delete scheme from archive" );
ok( $cherry->deleteIngest(),                                                      "clean ingest dir" );
ok( $cherry->deleteStock(),                                                       "clean stock dir" );
ok( remove_tree( $scheme->cherry->config->{core}{carousel}, { keep_root => 1 } ), "clean carousel", );
