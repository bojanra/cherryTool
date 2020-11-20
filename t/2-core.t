#!perl
use 5.010;
use utf8;
use strict;
use warnings;
use Test::More tests => 23;
use YAML::XS;
use open ':std', ':encoding(utf8)';

#say YAML::XS::Dump $report;

use_ok("cherryEpg");
use_ok("cherryEpg::Scheme");

my $cherry = cherryEpg->instance();
isa_ok( $cherry, 'cherryEpg' );

ok( $cherry, "Object created" );

ok( $cherry->databaseReset(), "Intialize Epg database" );

$cherry->ingestDelete() && say "Delete ingest directory";

my $scheme = new_ok('cherryEpg::Scheme');

ok( $scheme->readXLS('t/sample.xls'), 'Read .xls' );

my $s = $scheme->build();

ok( $s->{isValid}, 'Build scheme from .xls' );

my ( $success, $error ) = $cherry->schemeImport($s);
ok( scalar(@$success) && !scalar(@$error), "Scheme import to database" );

my $yaml   = $scheme->writeYAML();
my $origin = YAML::XS::Load($yaml);

# remove the {source} and {target} key from original as this is not exported
delete $origin->{source};
delete $origin->{target};

$yaml = $cherry->schemeExport();
my $export = YAML::XS::Load($yaml);

is_deeply( $origin, $export, "Exported identical to imported YAML configuration" );

# test parser
foreach my $ch (qw( 45 70 )) {
    my $channel = ${ $cherry->epg->listChannel($ch) }[0];
    my $grab    = $cherry->channelGrab($channel);
    my $ingest  = $cherry->channelIngest($channel);
    if ( scalar @{ $$ingest[0]->{errorList} } ) {
        say( join( "\n", @{ $$ingest[0]->{errorList} } ) );
    }
    ok( scalar(@$grab) && scalar(@$ingest) && !scalar @{ $$ingest[0]->{errorList} }, "$channel->{parser} parser o.k." );
} ## end foreach my $ch (qw( 45 70 ))

# version check
my $version = $cherry->epg->version();
ok( $version =~ m/\d+\./, "Version reporting" );

# get database stats
my $report = $cherry->epg->healthCheck();
ok( scalar(@$report) == 7, "Database stats reporting" );

# check of multigrabber in cherryEpg
my $grab = $cherry->channelGrabIngestMulti('all');
ok( scalar(@$grab) == 25, "Doing multi-grab with ingest" );

my $ch      = 4;
my $channel = ${ $cherry->epg->listChannel($ch) }[0];

# reset/remove md5 file
$channel = ${ $cherry->epg->listChannel($ch) }[0];
my $result = $cherry->channelReset($channel);
ok( $result, "Reset done for $channel->{name}" );

# remove all eit
ok( defined $cherry->carouselClean('EIT'), "Clear EIT from carousel" );

# test builder
my $eit = @{ $cherry->epg->listEit(1) }[0];
ok( $eit, "Prepare building for eit with target $eit->{output}" );

my $forced = 1;
my $return = $cherry->eitBuild( $eit, $forced );

ok( $return && -e $return, "Building of EIT output o.k." );

# export channel schedule to XML
$channel = ${ $cherry->epg->listChannel($ch) }[0];
my $content = $cherry->epg->channelListExport( [$channel], 'localhost', 'eng' );
ok( $content && length($content) > 30000, "Export XMLTV" );

my $i = 0;
my $data;

while ( $i < 10 ) {
    $data = $cherry->epg->getLogEntry($i);
    last if ref $data eq 'HASH';
    $i += 1;
}

ok( ref $data eq 'HASH', "Log record with extended data" );

my ( $total, $filtered, $listRef ) = $cherry->epg->getLogList( [ 0, 1, 2, 3, 4 ], 0, undef, 10 );
ok( $total > 10, "Log query" );

ok( scalar @$listRef == 10, "Log listing" );
