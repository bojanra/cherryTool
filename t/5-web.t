#!/usr/bin/perl

use Mojo::Base -strict;
use Test::More tests => 26;
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
    my $id = $t->tx->res->json('/data/0/id');

    $t->post_ok('/log')->json_has('/recordsTotal')->json_has('/recordsFiltered');

    $t->post_ok('/status')->json_has('/version');

    $t->post_ok( '/service/info' => form => { id => $id } )->status_is(200)->json_is( '/channel_id', $id );

    my $sample = <<END
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tv source-data-url="https://tvprofil.net/api/xmltv/" source-info-name="TvProfil API v2.0 - XMLTV" source-info-url="https://tvprofil.com">
  <channel id="bbc1">
    <display-name>BBC1</display-name>
    <url>http://www.bbc.co.uk/bbcone/</url>
    <icon src="https://cdn-0.tvprofil.com/cdn/400x200/4/img/kanali-logo/bbc-one-logo.png"/>
  </channel>
  <programme channel="bbc1" start="20210220012000 +0000" stop="20210220012500 +0000">
    <title lang="hr">Weather for the Week Ahead</title>
    <category>news</category>
  </programme>
  <programme channel="bbc1" start="20210220012500 +0000" stop="20210220013000 +0000">
    <title lang="hr">BBC News</title>
    <category>news</category>
  </programme>
</tv>
END
        ;
    my $upload = { file => { content => $sample, filename => 'sample.xml' }, id => $id };
    $t->post_ok( '/service/ingest' => form => $upload )->status_is(200)->json_is( '/success', 1 );

    $t->get_ok('/logout')->status_is(200);

    $t->get_ok('/report.json')->status_is(200)->json_has('/timestamp');
}
