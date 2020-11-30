#!perl
use 5.010;
use utf8;
use strict;
use warnings;
use Test::More tests => 15;
use YAML::XS;
use open ':std', ':encoding(utf8)';

use_ok("cherryEpg");
use_ok("cherryEpg::Scheme");

my $cherry = cherryEpg->instance();
isa_ok( $cherry, 'cherryEpg' );

ok( $cherry, "Object created" );

ok( $cherry->databaseReset(), "Intialize Epg database" );

$cherry->ingestDelete();

my $scheme = new_ok('cherryEpg::Scheme');

ok( $scheme->readXLS('t/large.xls'), 'Read .xls' );

my $s = $scheme->build();

ok( $s->{isValid}, 'Build scheme from .xls' );

ok( scalar( @{ $s->{rule} } ) == 600, 'Build rule' );

ok( scalar @{ $scheme->error } == 0, 'Build success' );

my ( $success, $error ) = $cherry->schemeImport($s);

ok( scalar(@$success) && !scalar(@$error), "Scheme import to database" );

my $grab = $cherry->channelGrabIngestMulti('all');

ok( scalar(@$grab) == 200, "Multi-grab with ingest" );

foreach my $eit ( @{ $cherry->epg->listEit() } ) {
    my $return = $cherry->eitBuild($eit);
    ok( $return && -e $return, "Building EIT $eit->{output}" );
}
