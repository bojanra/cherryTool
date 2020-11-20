#!perl
use 5.010;
use strict;
use warnings;
use Test::More tests => 4;
use utf8;
use Data::Dumper;
use open ':std', ':encoding(utf8)';

BEGIN {
    use_ok("cherryEpg::Epg") || print "Bail out!\n";
}

my $epg = cherryEpg::Epg->new(
    config => {
        datasource => "dbi:mysql:dbname=cherry_db;host=localhost",
        user       => "cherryepg",
        pass       => "visnja"
    }
);

isa_ok( $epg, 'cherryEpg::Epg' );

isa_ok( $epg->dbh, 'DBI::db' );

ok( $epg->initdb(), "Intialize Epg database structure" );
