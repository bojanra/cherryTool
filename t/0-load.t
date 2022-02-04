#!/usr/bin/perl

use 5.24.1;

use Test::More tests => 1;

BEGIN {
    use_ok("cherryEpg") || say "Bail out!";
}

diag("Testing cherryEpg $cherryEpg::VERSION, Perl $], $^X");
