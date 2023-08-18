#!/usr/bin/perl

use 5.024;
use YAML::XS;
use File::Path qw(remove_tree);
use Test::More tests => 16;

BEGIN {
  use_ok("cherryEpg::Scheme");
}

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );
my $sut    = 'simple';
my $serialized;

ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

my $s = $scheme->build();

ok( $s->{isValid}, "build scheme" );

ok( $scheme->cherry->resetDatabase(), "clean/init db" );

my ( $success, $error ) = $scheme->pushScheme();
ok( scalar(@$success) == 21 && !scalar(@$error), "load scheme to db" );

ok( remove_tree( $scheme->cherry->config->{core}{carousel} . "COMMON.linger" ), "clean carousel" );

my $backup = $scheme->backup();
ok( $backup, "backup scheme" );

ok( $scheme->restore($backup), "restore scheme" );

ok( !$scheme->restore('unknown'),      "fail on restore non-existing scheme" );
ok( !$scheme->importScheme('unknown'), "fail on import non-existing scheme" );
ok( !$scheme->delete('unknown'),       "fail on delete non-existing scheme" );

ok( ref( $scheme->listScheme() ) eq 'ARRAY', "list archive" );

ok( $scheme->delete($backup), "delete scheme from archive" );

$sut = 'rules';

ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

$s = $scheme->build();

ok( $s->{isValid}, "build scheme with RULE sheet" );

