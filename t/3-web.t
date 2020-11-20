use 5.010;
use strict;
use warnings;
use Test::More tests => 5;
use WWW::Mechanize;
use Data::Dumper;
use YAML::XS;

my $mech = WWW::Mechanize->new( autocheck => 0 );
$mech->max_redirect(0);

my $url = "http://localhost:5000/";
$mech->get($url);
is( $mech->response()->code, 401, "Unauthorized" );

$mech->form_number(1);
$mech->field( '__auth_extensible_username', "nonvalid" );
$mech->field( '__auth_extensible_password', "user" );
$mech->field( 'return_url',                 '/' );
$mech->submit($url);
is( $mech->response()->code, 401, "Authentication test" );

#like( $mech->response()->decoded_content, qr/Login/, "Failed login with incorrect user" );

$mech->form_number(1);
$mech->field( '__auth_extensible_username', "cherry" );
$mech->field( '__auth_extensible_password', "amarena" );
$mech->field( 'return_url',                 '/' );
$mech->submit($url);
is( $mech->response()->code, 302, "Redirect after succesfull login as [cherry] user" );

$mech->get( $url . "logout" );
is( $mech->response()->code, 200, "Logout" );

my $response = $mech->get( $url . "report.json" );
my $decoded  = YAML::XS::Load( $response->decoded_content );

ok( exists $decoded->{timestamp} && $decoded->{timestamp}, "Reporting to web" );
