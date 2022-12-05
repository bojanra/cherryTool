#!/usr/bin/perl

use 5.024;
use utf8;
use Test::More tests => 39;
use Path::Class;
use File::Temp qw(tempfile);

BEGIN {
    use_ok("cherryEpg");
    use_ok("cherryEpg::Scheme");
}

my $cherry = cherryEpg->instance( verbose => 0 );
my $target;
my $channel;

isa_ok( $cherry, "cherryEpg" );

# initialize the database structure
ok( $cherry->epg->initdb(), "init db structure" );

# delete ingest
ok( defined $cherry->deleteIngest(), "delete ingest dir" );

my $scheme = new_ok( 'cherryEpg::Scheme' => [ verbose => 0 ], "cherryEpg::Scheme" );

# read, build and load the linger (remote) scheme
ok( $scheme->readXLS("t/scheme/linger.xls"), "read .xls" );

my $s = $scheme->build();

delete $s->{source};

ok( $s->{isValid}, "build scheme" );

ok( $cherry->resetDatabase(),        "clean/init db" );
ok( defined $cherry->deleteIngest(), "delete ingest dir" );

my $mykey = { salomon => 'skiing', goliah => 'fighting', godot => 99 };
$cherry->epg->addKey($mykey);

is_deeply( $cherry->epg->listKey(), $mykey, "dictionary testing" );
is( scalar $cherry->epg->listKey("godot")->%*, 1, "dictionary single key" );

my ( $success, $error ) = $scheme->pushScheme();
ok( !scalar(@$success) && !scalar(@$error), "load scheme to db" );

my $backup = $scheme->backup();
ok( $backup, "backup scheme" );

ok( $cherry->isLinger(), "report linger status" );

my $publicKey = $cherry->getLingerKey();
ok( length($publicKey) > 30, "generate public key" );

my $l = {
    public_key => uc($publicKey),
    info       => {
        disabled => 1,
    },
};

ok( $cherry->epg->addLinger($l), "add linger site" );
ok( $cherry->epg->addLinger($l), "add/update same site twice" );
is( scalar $cherry->epg->listLinger()->@*, 1, "uniq public_key" );

my $linger = {
    public_key => $publicKey,
    info       => {},
};

ok( $linger = $cherry->epg->addLinger($linger), "add new linger site" );
is( scalar $cherry->epg->listLinger()->@*, 2, "count sites" );

cmp_ok( $cherry->updateAuthorizedKeys(), ">=", 2, "grant access" );

open( my $file, "<", $ENV{HOME} . "/.ssh/authorized_keys" ) || diag "Failed opening authorized_keys file";
my @row = <$file>;
close($file);

is( scalar( grep {/command/} @row ), 2, "writing authorized_keys file" );

ok( $cherry->markLinger( $linger->{linger_id} ), "update mark" );

ok( $cherry->updateSyncDirectory(), "create sync directory" );
ok( $cherry->installRrsync(),       "installRrsync" );

# prepare a sample .cts file in the sync sub-directory
my ( $fh, $fullPath ) = tempfile(
    DIR    => dir( $cherry->config->{core}{carousel}, $linger->{linger_id} . '.linger' ),
    SUFFIX => '.ctS',
    UNLINK => 1
);

print( $fh "verify" );
close($fh);

# get the name from the whole path
$fullPath =~ m|/([^/]+)$|;
my $filename = $1;

my $theCopy = file( $cherry->config->{core}{carousel}, $filename );

is( $cherry->syncLinger(), 1, "synchronize file" );

# get the filename
if ( -e $theCopy ) {
    is( unlink($theCopy), 1, "file synchronized, cleanup" );
} else {
    fail("file not synced");
}

ok( $scheme->delete($backup), "delete scheme from archive" );

# read, build scheme
ok( $scheme->readXLS("t/scheme/cloud.xls"), "read .xls" );

ok( $scheme->build()->{isValid}, "valid cloud scheme" );

#p $scheme;

ok( $cherry->resetDatabase(), "clean/init db" );

my ( $success, $error ) = $scheme->pushScheme();

ok( scalar(@$success) && !scalar(@$error), "load scheme to db" );

$backup = $scheme->backup();
ok( $backup, "backup scheme" );

# test multigrabber
my $count = scalar( $cherry->epg->listChannel()->@* );
my $grab  = $cherry->parallelGrabIngestChannel( "all", 1, 1 );
ok( scalar( $grab->@* ) == $count, "multi-grab/ingest" );

# delete carousel
my $player = new_ok( 'cherryEpg::Player' => [ verbose => 0 ], "cherryEpg::Player" );
ok( defined $player->delete(), "delete carousel" );

# multi make/build
isa_ok( $cherry->parallelUpdateEit(), "ARRAY", "make eit" );

#say `find /var/lib/cherryepg/carousel/ | sort`;
say `ls -lR /var/lib/cherryepg/carousel/`;

ok( $scheme->delete($backup), "delete scheme from archive" );

done_testing;
