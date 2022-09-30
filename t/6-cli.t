#!/usr/bin/perl

use 5.024;
use Cwd 'abs_path';
use File::Basename;
use Test::Cmd;
use Test::More tests => 32;

BEGIN {
    `generateSampleScheduleData`;

    ok( $? == 0, "generate sample schedule data" );
}

my $test = Test::Cmd->new( prog => 'bin/cherryTool', workdir => '' );

# scheme under test without extension
my $sut        = 'basic';
my $schemeFile = dirname( abs_path(__FILE__) ) . "/scheme/$sut.xls";

$test->run();
is( $?, 0, 'without switches' );

$test->run( args => '-V' );
like( $test->stdout, qr/appname/, 'show config' );

$test->run( args => '-h' );
like( $test->stdout, qr/Usage/, 'help' );

$test->run( args => '-Q' );
is( my $count = () = $test->stdout =~ m/MyISAM/g, 7, 'db statistics' );

$test->run( args => '-c ' . $schemeFile, chdir => '.' );
like( $test->stdout, qr/$sut.xls/, 'compile scheme' );

$test->run( args => "-L $sut.yaml", stdin => "yes\n", chdir => '.' );
ok( $test->stdout =~ m/clean/i && $test->stdout =~ m/import \[$sut.xls\]/ && $test->stdout =~ /backup/, 'clean and load scheme' );

$test->run( args => '-n' );
like( $test->stdout, qr/$sut/, 'last scheme' );

$test->run( args => '-Q' );
ok( ( my $count = () = $test->stdout =~ m/MyISAM/g ) >= 4, 'list scheme archive' );

$test->run( args => '-P', stdin => "yes\n" );
is( $?, 0, 'delete rules' );

$test->run( args => "-l $sut.yaml", stdin => "yes\n", chdir => '.' );
ok( $test->stdout =~ m/import \[$sut.xls\]/ && $test->stdout =~ /backup/, 'load scheme' );

$test->run( args => '-R' );
is( $?, 0, 'Report' );

$test->run( args => '-N' );
is( $?, 0, 'Report&Notification' );

$test->run( args => '-Z test' );
is( $?, 0, 'generate test log entry' );

$test->run( args => '-F' );
is( $?, 0, 'list scheme in archive' );

$test->run( args => '-n' );
is( $?, 0, 'list last scheme loaded' );

my $exportFile = 'export.yaml';
$test->run( args => "-e $exportFile", chdir => '.' );
is( $?, 0, 'export' );
ok( -e $test->workdir . '/' . $exportFile, 'export done' );

$test->run( args => '-G all' );
is( $?, 0, 'grab' );

$test->run( args => '-Y', stdin => "yes\n" );
is( $?, 0, 'delete carousel' );

$test->run( args => '-B' );
is( $?, 0, 'build EIT' );

$test->run( args => '-fB' );
is( $?, 0, 'force build EIT' );

$test->run( args => '-C' );
is( $?,                           0, 'list carousel' );
is( ( $test->stdout =~ tr/\*// ), 4, 'list carousel correct' );

$test->run( args => '-f' );
is( $?, 0, 'delete sections' );

$test->run( args => '-D', stdin => "yes\n" );
is( $?, 0, 'delete ingest' );

$test->run( args => '-O', stdin => "yes\n" );
is( $?, 0, 'cleanup database - delete old entries' );

$test->run( args => '-T', stdin => "yes\n" );
is( $?, 0, 'reset db to empty state' );

SKIP: {
    skip 'maintenance compiling and applying', 4 if $ENV{'DANCER_ENVIRONMENT'} eq 'production';

    my $m = 'bin/maintenanceTest';
    unlink( $m . '.bin' );
    $test->run( args => "-J $m" );
    ok( $test->stdout =~ /bytes written/m, 'compile maintenance package' );
    ok( -e "$m.bin",                       'maintenance file exist' );

    $test->run( args => "-j $m.bin", stdin => "yes\n" );
    ok( $? == 0,                            'maintenance package apply' );
    ok( $test->stdout =~ /debian_version/m, 'maintenanceTest success' );
    unlink( $m . '.bin' );
} ## end SKIP:

# TODO
# -v         use verbose output mode
#
# -I chunk   inspect chunk and generate mosaic.png
#
# -H host    set host as target when converting xls to scheme (used to select sheet)
#
# -u file    add/upload .gz file to carousel
# -p chunk   play TS chunk
# -s chunk   stop TS chunk
# -y chunk   delete TS chunk from carousel
#
# Do operations on service using {channel_id} as id:
# -g id      grab service schedule data
# -d id      delete all files for service (not directory itself)
# -i id      ingest (parse) files for service from ingest directory
# -a id      parse files for service from ingest directory and just return result DON'T INGEST
# -r id      reset by deleting *.md5.parsed files
# -w id      wipe/remove service definition and data
# -x id      export events for service in XMLTV format to file {service_id.xml}
#
# -W         run the web server
