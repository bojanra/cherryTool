#!perl
use 5.010;
use utf8;
use strict;
use warnings;
use Test::More tests => 13;
use YAML::XS;
use open ':std', ':encoding(utf8)';

#say YAML::XS::Dump $report;

use_ok("cherryEpg");
use_ok("cherryEpg::Scheme");

my $cherry = cherryEpg->instance();
isa_ok( $cherry, 'cherryEpg' );

ok( $cherry, "Object created" );

ok( $cherry->databaseReset(), "Intialize Epg database" );

ok( $cherry->ingestDelete(), "Delete ingest directory" );

my $scheme = new_ok('cherryEpg::Scheme');

ok( $scheme->readXLS('t/extra.xls'), 'Read .xls' );

my $s = $scheme->build();

ok( $s->{isValid}, 'Build scheme from .xls' );

my ( $success, $error ) = $cherry->schemeImport($s);

ok( scalar(@$success) && !scalar(@$error), "Scheme import to database" );

# test parser
foreach my $ch ( 55, 56, 57 ) {
    my $channel = ${ $cherry->epg->listChannel($ch) }[0];
    my $grab    = $cherry->channelGrab($channel);
    my $ingest  = $cherry->channelIngest($channel);
    if ( scalar @{ $$ingest[0]->{errorList} } ) {
        say( join( "\n", @{ $$ingest[0]->{errorList} } ) );
    }
    ok( scalar(@$grab) && scalar(@$ingest) && !scalar @{ $$ingest[0]->{errorList} }, "$channel->{parser} parser o.k." );
} ## end foreach my $ch ( 55, 56, 57)
