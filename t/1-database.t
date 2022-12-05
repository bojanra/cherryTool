#!/usr/bin/perl

use 5.024;
use Test::More tests => 4;

BEGIN {
    use_ok("cherryEpg");
}

my $cherry = cherryEpg->instance();

isa_ok( $cherry->epg->dbh, 'DBI::db', "dbh" );

# this is the low level function
ok( $cherry->epg->initdb(), "init db structure" );

# here we call it with logging
ok( $cherry->resetDatabase(), "clean/init db" );

