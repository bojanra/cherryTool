#!perl
use 5.010;
use strict;
use warnings;
use Test::More tests => 2;
use File::Rsync;
use utf8;

`generateSampleScheduleData`;

ok( $? == 0, "Generate sample schedule data" );

my $stock = glob("~/stock");

# sync test schedule from testData directory to stock
my $rsync = File::Rsync->new(
    recursive => 1,
    times     => 1,
    perms     => 1,
    group     => 1,
    owner     => 1,
    verbose   => 2,
    src       => ['t/testData/'],
    dest      => $stock
);

ok( $rsync->exec(), "Copy test data files to stock" );
