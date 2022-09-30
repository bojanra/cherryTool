#!/usr/bin/perl

use 5.024;
use Mojo::Base -strict;
use Test::Mojo;
use Test::More tests => 53;
use Try::Tiny;

BEGIN {
    $ENV{DANCER_CONFDIR}     = 't/lib';
    $ENV{DANCER_ENVIRONMENT} = 'test';

    use_ok("cherryEpg");
    use_ok("cherryEpg::Scheme");

    `generateSampleScheduleData`;

    ok( $? == 0, "generate sample schedule data" );
} ## end BEGIN

# prepare the environment for testing
my $cherry = cherryEpg->instance( verbose => 0 );
my $sut    = 'simple';

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], 'cherryEpg::Scheme' );

ok( $scheme->readXLS("t/scheme/$sut.xls"), "read .xls" );

my $s = $scheme->build();

ok( $cherry->databaseReset(), "clean/init db" );

my ( $success, $error ) = $scheme->push();
ok( scalar(@$success) && !scalar(@$error), "prepare scheme in db" );

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
    my $post = $t->tx->res->json('/post');

    my $content = do {
        local $/;
        open( my $fh, '<', 't/testData/TVXML.xml' ) || return;
        <$fh>;
    };
    my $upload = { file => { content => $content, filename => 'sample.xml' } };
    $t->post_ok( "/ingest/$post/$id" => form => $upload )->status_is(200)->json_is( '/success', 1 );

    $id = 90;
    $t->post_ok( '/service/info' => form => { id => $id } );
    $post = $t->tx->res->json('/post');

    $content = do {
        local $/;
        open( my $fh, '<', 't/testData/SimpleSchedule.xls' ) || return;
        <$fh>;
    };
    $upload = { file => { content => $content, filename => 'Simple.xls' }, id => 90 };
    $t->post_ok( "/ingest/$post/$id" => form => $upload )->status_is(200)->json_is( '/success', 1 );

    # clean pid=17
    $t->post_ok('/carousel/browse')->status_is(200);
    my @list = grep { $_->{pid} == 17 } $t->tx->res->json->@*;

    subtest 'Delete chunks' => sub {
        foreach my $chunk (@list) {
            $t->post_ok( '/carousel/delete' => form => { target => $chunk->{target} } )->status_is(200);
        }
        pass("Done");
        done_testing();
    };

    $content = do {
        local $/;
        open( my $fh, '<', 't/testData/SDT.ets.gz' ) || return;
        <$fh>;
    };

    # add first
    $upload = { file => { content => $content, filename => 'SDT.ets.gz' } };
    $t->post_ok( '/carousel/upnsave' => form => $upload )->status_is(200)->json_is( '/0/success', 1 );

    # add second
    $upload = { file => { content => $content, filename => 'SDT.ets.gz' } };
    $t->post_ok( '/carousel/upnsave' => form => $upload )->status_is(200)->json_is( '/0/success', 1 );
    my $target = $t->tx->res->json('/0/target');

    # start playing
    $t->post_ok( '/carousel/play' => form => { target => $target } )->status_is(200);

    # check if marked
    $t->post_ok('/carousel/browse')->status_is(200);
    ok( ref( $t->tx->res->json ) eq 'ARRAY' );
    @list = grep { $_->{pid} == 17 && $_->{duplicate} == 1 } $t->tx->res->json->@*;
    ok( scalar(@list) == 2, "Detect duplicate" );

    subtest 'Delete chunks' => sub {
        foreach my $chunk (@list) {
            $t->post_ok( '/carousel/delete' => form => { target => $chunk->{target} } )->status_is(200);
        }
        pass("Done");
        done_testing();
    };

    $t->get_ok('/logout')->status_is(200);
    $t->get_ok('/report.json')->status_is(200)->json_has('/timestamp');
}
