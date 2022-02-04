#!/usr/bin/perl

use Mojo::Base -strict;
use Test::More tests => 20;
use Test::Mojo;

BEGIN {
    $ENV{DANCER_CONFDIR}     = 't/lib';
    $ENV{DANCER_ENVIRONMENT} = 'test';
}

{
    my $t = Test::Mojo->with_roles('+PSGI')->new('bin/app.psgi');

    $t->get_ok('/')->status_is(401);

    $t->get_ok( '/' => form => { __auth_extensible_username => 'nonvalid', __auth_extensible_password => 'user' } )
        ->status_is(401);

    $t->post_ok( '/' => form => { __auth_extensible_username => 'cherry', __auth_extensible_password => 'amarena' } )
        ->status_is(302);

    $t->ua->on( start => sub { my ( $ua, $tx ) = @_; $tx->req->headers->header( 'X-Requested-With' => 'XMLHttpRequest' ) } );

    $t->post_ok('/ebudget')->json_has('/timestamp')->json_has('/status')->json_has('/data');

    $t->post_ok('/log')->json_has('/recordsTotal')->json_has('/recordsFiltered');

    $t->post_ok('/status')->json_has('/version');

    $t->get_ok('/logout')->status_is(200);

    $t->get_ok('/report.json')->status_is(200)->json_has('/timestamp');
}
