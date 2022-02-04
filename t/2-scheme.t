#!/usr/bin/perl

use YAML::XS;

use Test::More tests => 16;

BEGIN {
    use_ok("cherryEpg::Scheme");
}

my $scheme = new_ok( cherryEpg::Scheme => [ verbose => 0 ], 'cherryEpg::Scheme' );
my $sut    = 'simple';
my $serialized;

ok( $scheme->readXLS("t/scheme/$sut.xls"), 'read .xls' );

my $s = $scheme->build();

ok( $s->{isValid}, 'build scheme' );

ok( $scheme->cherry->databaseReset(), "clean/init db" );

my ( $success, $error ) = $scheme->push();
ok( scalar(@$success) == 21 && !scalar(@$error), "load scheme to db" );

# is exported equal to loaded
$serialized = $scheme->export();
my $origin = YAML::XS::Load($serialized);

# remove the {source} and {target} key from original as this is not in db
delete $origin->{source};
delete $origin->{target};

ok( $scheme->pull(), "read scheme from db" );
$serialized = $scheme->export();
my $export = YAML::XS::Load($serialized);

is_deeply( $origin, $export, "exported === origin scheme" );

my $backup = $scheme->backup();
ok( $backup, "backup scheme" );

ok( $scheme->restore($backup), "restore scheme" );

$serialized = $scheme->export();
my $restored = YAML::XS::Load($serialized);

is_deeply( $origin, $restored, "restored === origin scheme" );

ok( !$scheme->restore('unknown'), "fail on restore non-existing scheme" );
ok( !$scheme->Import('unknown'),  "fail on import non-existing scheme" );
ok( !$scheme->delete('unknown'),  "fail on delete non-existing scheme" );

ok( ref( $scheme->list() ) eq 'ARRAY', "list archive" );

ok( $scheme->delete($backup), "delete scheme from archive" );
