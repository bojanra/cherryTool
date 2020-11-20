package cherryEpg;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Path::Class;
use Carp;
use YAML::XS;
use Log::Log4perl;
use Log::Log4perl::Level;
use File::Find qw(find);
use File::Path qw(remove_tree);
use Time::Piece;
use Gzip::Faster;
use cherryEpg::Epg;
use cherryEpg::Grabber;
use cherryEpg::Ingester;
use cherryEpg::Scheme;
use Parallel::ForkManager;
use IPC::ConcurrencyLimit;
use Fcntl qw/:flock O_WRONLY O_CREAT O_EXCL/;
use open ':std', ':encoding(utf8)';

our $VERSION = '1.62';

with('MooX::Singleton');

has 'configFile' => (
    is      => 'ro',
    default => sub {
        if ( $ENV{'HOME'} ) {
            return file( $ENV{'HOME'}, "config.yml" );
        } else {
            return '~/config.yml';
        }
    },
);

has 'verbose' => (
    is       => 'ro',
    default  => 0,
    required => 1
);

has 'config' => ( is => 'lazy', );
has 'epg'    => ( is => 'lazy', );

sub _build_config {
    my ($self) = @_;

    my $configFile = $self->configFile;

    $configFile = glob($configFile);

    my $configuration;

    # check if file exists
    if ( $configFile and -e $configFile ) {

        $configuration = YAML::XS::LoadFile($configFile);

        # return only the subtree
        if ( ref $configuration eq 'HASH' ) {

            # add the path of the configuration file to the configuration itself
            $configuration->{configfile} = $configFile;
            return $configuration;
        } else {
            croak("No configuration data found in: $configFile (incorrect format!)");
        }
    } else {
        croak("Missing configuration file: $configFile");
    }
} ## end sub _build_config

sub _build_epg {
    my ($self) = @_;

    return $self->epgInstance;
}

sub BUILD {
    my ($self) = @_;

    my $configuration = $self->config->{log4perl};

    # replace database credentials
    foreach (qw( datasource user pass)) {
        my $variable = $self->config->{cherryepg}{$_};
        $configuration =~ s/\$$_/$variable/;
    }

    # set environment variable used inside $configuration
    if ( $self->verbose ) {
        $ENV{LOGLEVEL} = 'TRACE';
    } else {
        $ENV{LOGLEVEL} = 'INFO';
    }

    # Initialize Logger
    try {
        Log::Log4perl::init( \$configuration );
    } catch {
        carp("initialization of logging system failed$!");
    };

} ## end sub BUILD

=head3 epgInstance( )

Get a new epg object with own database connection.

=cut

sub epgInstance {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");
    my $config = $self->config->{cherryepg};

    my $epg = cherryEpg::Epg->new( config => $config );

    if ( $epg->dbh ) {
        return $epg;
    } else {
        $logger->fatal("connect EIT database [$config->{datasource}]: $!");
        exit(1);
    }
} ## end sub epgInstance

=head3 cleanup()

Clean database to prevent filling the disk and performance improve.
Delete service events before yesterday.
Delete log records before start of previous month.

=cut

sub cleanup {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $last_midnight = int( time() / ( 24 * 60 * 60 ) ) * 24 * 60 * 60;

    my $beforeDays = $last_midnight - 24 * 60 * 60;

    my $count = $self->epg->deleteEvent( undef, undef, undef, undef, undef, $beforeDays );

    $logger->info("cleanup old events [$count]");

    $count = $self->epg->dbh->do(
        'DELETE FROM log WHERE timestamp < DATE_ADD(LAST_DAY(DATE_SUB(NOW(), INTERVAL 2 MONTH)), INTERVAL 1 DAY)');

    $count = 0 if $count eq "0E0";

    $logger->info("cleanup old log records [$count]");

    return $count;
} ## end sub cleanup

=head3 ingestDelete( )

Delete ingest directory.

=cut

sub ingestDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $dir = $self->config->{cherryepg}{ingest};

    $logger->info("clear ingest directory");
    return remove_tree( $dir, { keep_root => 1 } );
} ## end sub ingestDelete

=head3 ruleDelete( )

Delete all rules in database.

=cut

sub ruleDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $count = $self->epg->deleteRule();

    $logger->info("remove rules from database {$count}");
    return $count;
} ## end sub ruleDelete

=head3 sectionDelete( )

Delete all entries from section and version table.

=cut

sub sectionDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $count = $self->epg->reset;

    $logger->info("clear section and version table");
    return $count;
} ## end sub sectionDelete

=head3 channelDelete( $channel_id)

Delete/wipe channel with $channel_id from database.

=cut

sub channelDelete {
    my ( $self, $channel_id ) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $dir = dir( $self->config->{cherryepg}{ingest}, $channel_id );

    remove_tree( $dir, { keep_root => 0 } );

    my $result = $self->epg->deleteChannel($channel_id);

    $logger->info( "wipe service from database and disk", $channel_id );
    return $result;
} ## end sub channelDelete

=head3 databaseReset( )

Clear all data and intialize database.

=cut

sub databaseReset {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    $logger->info("clear database - empty tables");

    return $self->epg->initdb();
} ## end sub databaseReset

=head3 channelPurge( $channel)

Reset ingest by files for channel $channel.
If no channel defined, go for all.
Return ref. to list of removed files.

=cut

sub channelPurge {
    my ( $self, $channel ) = @_;

    my $logger = Log::Log4perl->get_logger("ingester");

    my $dir;
    if ($channel) {
        $dir = dir( $self->config->{cherryepg}{ingest}, $channel->{channel_id} );
    } else {
        $dir = dir( $self->config->{cherryepg}{ingest} );
    }

    return unless -d $dir;

    my @files;
    find( {
            wanted => sub {

                # skip directories
                return if -d $_;

                # skip "hidden" files starting with a dot
                return if /\/\./;

                my $file = $_;
                unlink($file);
                push( @files, $file );
            },
            no_chdir => 1
        },
        $dir
    );

    $logger->info( "purge service by removing files [" . ( scalar @files ) . "]", $channel->{channel_id}, '', \@files );

    return \@files;
} ## end sub channelPurge

=head3 channelReset( $channel)

Reset ingest by removing *.md5.parsed files for channel $channel.
If no channel defined, go for all.
Return number of removed files.

=cut

sub channelReset {
    my ( $self, $channel ) = @_;

    my $logger = Log::Log4perl->get_logger("ingester");

    my $dir;
    if ($channel) {
        $dir = dir( $self->config->{cherryepg}{ingest}, $channel->{channel_id} );
    } else {
        $dir = dir( $self->config->{cherryepg}{ingest} );
    }

    return unless -d $dir;

    my @files;
    find( {
            wanted => sub {

                # skip directories
                return if -d $_;

                # show just md5.parsed files
                return if !/\.md5\.parsed/;

                # skip "hidden" files starting with a dot
                return if /\/\./;

                my $md5File = $_;
                unlink($md5File);
                push( @files, $md5File );
            },
            no_chdir => 1
        },
        $dir
    );

    $logger->info( "reset service remov .md5 files [" . ( scalar @files ) . "]", $channel->{channel_id}, undef, \@files );

    return \@files;
} ## end sub channelReset

=head3 channelIngest( $channel, $dryrun)

Run the ingester for channel $channel (channel hash).
If $dryrun only run the parser without database update.
Return report as hashref.

=cut

sub channelIngest {
    my ( $self, $channel, $dryrun ) = @_;

    my $myIngest = cherryEpg::Ingester->new( channel => $channel, dryrun => $dryrun // 0 );
    return $myIngest->update() if $myIngest->parserReady;
} ## end sub channelIngest

=head3 channelGrab( $channel)

Run the grabber for channel $channel (channel hash).
Return report as hashref.

=cut

sub channelGrab {
    my ( $self, $channel ) = @_;

    my $myGrabber = cherryEpg::Grabber->new( channel => $channel );
    return $myGrabber->grab();
} ## end sub channelGrab

=head3 channelGrabIngestMulti( $target)

Grab and ingest channel schedules depending on target [daily, hourly, weekly]
Return list of grabbed files.

=cut

sub channelGrabIngestMulti {
    my ( $self, $target ) = @_;

    # just define
    $target //= "all";

    my @fullList;
    my @disabledList;

    my $logger = Log::Log4perl->get_logger("grabber");

    my $limit = IPC::ConcurrencyLimit->new(
        type      => 'Flock',
        max_procs => 1,
        path      => '/tmp/channelMulti.flock',
    );

    my $id = $limit->get_lock;
    if ( not $id ) {
        $logger->warn("service multigrab concurrency protection");
        return;
    }

    my $parallelTasks = $self->config->{cherryepg}{parallelTasks} // 3;
    my $pm            = Parallel::ForkManager->new($parallelTasks);

    $logger->trace("start multigrabber [$target] with $parallelTasks tasks");

    # this is needed to get back return data from forked processes
    $pm->run_on_finish(
        sub {
            my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $result ) = @_;
            if ( defined($result) ) {
                push( @fullList, @$result );
            }
        }
    );

    my $channelList = $self->epg->listChannel();

CHANNELMULTI_LOOP:
    foreach my $channel (@$channelList) {

        if ( $channel->{grabber}{disabled} ) {

            # skip disabled
            push( @disabledList, $channel->{channel_id} );
        } else {
            if ( $target eq "all" or $channel->{grabber}{update} eq $target ) {

                # fork proces
                my $process = $pm->start and next CHANNELMULTI_LOOP;

                my $result = $self->channelGrab($channel);

                # run ingest if new files
                $self->channelIngest($channel) if $result and scalar(@$result);

                $pm->finish( 0, $result );
            } ## end if ( $target eq "all" ...)
        } ## end else [ if ( $channel->{grabber...})]
        $pm->finish(0);
    } ## end CHANNELMULTI_LOOP: foreach my $channel (@$channelList)
    $pm->wait_all_children;

    # report full
    my $disabled = scalar @disabledList;
    $logger->info( "multigrabber [$target] fetch/update "
            . scalar(@fullList)
            . " files"
            . ( $disabled > 0 ? " (disabled services: $disabled)" : "" ) );
    return \@fullList;
} ## end sub channelGrabIngestMulti

=head3 carouselClean()
=head3 carouselClean( 'EIT')
=head3 carouselClean( $eit)

Remove .cts files from carousel directory. 

=cut

sub carouselClean {
    my ( $self, $param ) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    if ( !$param ) {
        my $pattern = file( $self->config->{cherryepg}{carousel}, "*.cts" );
        my @list    = glob($pattern);
        @list = grep {m|/[^_][^/]+\.cts$|} @list;
        my $count = unlink(@list);
        $logger->info("carousel cleaned [$count] files removed") if $count;
        return $count;
    } elsif ( $param eq 'EIT' ) {
        my $pattern = file( $self->config->{cherryepg}{carousel}, "eit_???.cts" );
        my @list    = glob($pattern);
        my $count   = unlink(@list);
        $logger->info("carousel cleaned [$count] EIT files removed") if $count;
        return $count;
    } else {
        my $eit_id     = $param->{eit_id};
        my $filename   = sprintf( "eit_%03i.cts", $eit_id );
        my $outputFile = file( $self->config->{cherryepg}{carousel}, $filename );

        if ( -f $outputFile ) {
            if ( unlink($outputFile) ) {
                $logger->info( "carousel cleaned [$outputFile] removed", undef, $eit_id );
                return 1;
            }
        } ## end if ( -f $outputFile )
        return;
    } ## end else [ if ( !$param ) ]
} ## end sub carouselClean

=head3 eitBuild( $eit, $forced)

Check if EIT with $eit must be updated and when needed build and export them to files.
When $forced always update.
Return filepath updated!

=cut

sub eitBuild {
    my ( $self, $eit, $forced ) = @_;

    my $logger = Log::Log4perl->get_logger("builder");

    my $eit_id = $eit->{eit_id};
    $logger->trace( "build EIT", undef, $eit_id );

    my $epg = $self->epgInstance;
    my $ret = $epg->updateEit( $eit_id, $forced );

    if ( !defined $ret ) {
        $logger->error( "build EIT", undef $eit_id );
    } elsif ( $ret or $forced ) {
        my $interval = 30;

        my $pes = $epg->getEit( $eit->{eit_id}, $interval );

        $eit->{output} =~ m|udp://(.+)$|;
        my $dst = $1;

        my $specs = {
            interval => $interval * 1000,          # must be in ms
            dst      => $dst,
            title    => "EIT PID=" . $eit->{pid}
        };

        $specs->{tdt} = 1 if exists $eit->{option}{TDT} and $eit->{option}{TDT} == 1;
        $specs->{pcr} = 1 if exists $eit->{option}{PCR} and $eit->{option}{PCR} == 1;

        my $encoded = JSON::XS::encode_json($specs);
        my $payload = "ringelspiel " . $encoded;

        if ( length($payload) > 183 ) {
            $logger->fatal( "commandstring to long [" . length($payload) . "]", undef, $eit_id );
            exit(1);
        }

        $payload .= "\x00";
        while ( length($payload) < 184 ) {
            $payload .= "\xff";
        }

        my $firstPacket = pack( "CnC", 0x47, 0x1fff, 0x10 ) . $payload;

        my $filename     = sprintf( "eit_%03i.cts", $eit->{eit_id} );
        my $tempFileName = $filename . ".tmp";
        my $outputFile   = file( $self->config->{cherryepg}{carousel}, $filename );
        my $tempFile     = file( $self->config->{cherryepg}{carousel}, $tempFileName );

        my $out;
        if ( !open( $out, '>', $tempFile ) ) {
            $logger->fatal( "open temporary export file [$tempFile] : $?", undef, $eit_id );
            exit(1);
        }
        binmode($out);
        print( $out $firstPacket );
        print( $out $pes );
        close($out);
        $logger->trace( "export " . length($pes) . " bytes to [$tempFileName]", undef, $eit_id );

        # rename temporary to outputfile with locking
        my $fh;
        if ( !( open( $fh, '+<', $outputFile ) or sysopen( $fh, $outputFile, O_WRONLY | O_CREAT | O_EXCL ) ) ) {
            $logger->fatal( "open export file [$outputFile] : $?", undef, $eit_id );
            exit(1);
        }
        if ( !flock( $fh, LOCK_EX ) ) {
            $logger->fatal( "lock [$outputFile]", undef, $eit_id );
            exit(1);
        }

        $logger->trace( "lock destination [$filename]", undef, $eit_id );

        seek( $fh, 0, 0 );
        if ( !rename( $tempFile, $outputFile ) ) {
            $logger->fatal( "rename [$tempFile -> $outputFile]", undef, $eit_id );
            exit(1);
        }
        close($fh);
        return $outputFile;
    } else {
        $logger->trace( "up-to-date", undef, $eit_id );
        return;
    }
} ## end sub eitBuild

=head3 eitMulti( $forced)

Check if EIT must be updated and when needed build and export them to files.
When $forced always update them.

=cut

sub eitMulti {
    my ( $self, $forced ) = @_;

    my $logger = Log::Log4perl->get_logger("builder");

    my $limit = IPC::ConcurrencyLimit->new(
        type      => 'Flock',
        max_procs => 1,
        path      => '/tmp/eitMulti.flock',
    );

    my $id = $limit->get_lock;
    if ( not $id ) {
        $logger->warn("eit multibuild concurrency protection");
        return;
    }

    my $parallelTasks = $self->config->{cherryepg}{parallelTasks} // 3;
    my $pm            = Parallel::ForkManager->new($parallelTasks);

    $logger->trace("start eit multibuild with $parallelTasks tasks");

    my $allEit = $self->epg->listEit();

EITMULTI_LOOP:
    foreach my $eit (@$allEit) {

        my $process = $pm->start and next EITMULTI_LOOP;

        $self->eitBuild( $eit, $forced );

        $pm->finish;
    } ## end EITMULTI_LOOP: foreach my $eit (@$allEit)
    $pm->wait_all_children;

    return [];    # FIXME
} ## end sub eitMulti


=head3 schemeImport( $scheme)

Import $scheme in scheme structure format 

=cut

sub schemeImport {
    my ( $self, $scheme ) = @_;
    my $filename = $scheme->{source}{filename};

    my $logger = Log::Log4perl->get_logger("system");

    my ( $success, $error ) = $self->epg->import($scheme);

    if ( scalar @$error == 0 ) {
        $logger->info( "import [$filename] with " . scalar(@$success) . " elements", undef, undef, $scheme );
    } else {
        $logger->warn( "import [$filename] with " . scalar(@$success) . " elements - " . scalar(@$error) . " errors",
            undef, undef, $scheme );
    }
    return ( $success, $error );
} ## end sub schemeImport

=head3 schemeExport( $filename)
=head3 schemeExport( )

Export current database scheme to file in yaml format and return 1 on success.
Return scheme data as string if no filename defined.

=cut

sub schemeExport {
    my ( $self, $filename ) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    # create the object
    my $schemeManager = cherryEpg::Scheme->new();

    # get struct
    my $exported = $self->epg->export;

    #import
    $schemeManager->set($exported);

    return $schemeManager->writeYAML($filename);
} ## end sub schemeExport

=head3 schemeStoreLoad ( $filename )

Load the $filename in YAML string format.
Return YAML string on success.

=cut

sub schemeStoreLoad {
    my ( $self, $filename ) = @_;

    my $store = dir( $self->config->{cherryepg}{scheme} );
    my $file  = file( $store, $filename . '.yaml.gz' );

    try {
        my $content = gunzip_file($file);
        return $content;
    };
} ## end sub schemeStoreLoad

=head3 schemeStoreSave ( $scheme )

Save the $scheme in YAML string format to the scheme store directory.
Return complete $filename on success.

=cut

sub schemeStoreSave {
    my ( $self, $scheme ) = @_;

    my $logger   = Log::Log4perl->get_logger("system");
    my $now      = localtime;
    my $filename = $now->strftime("%Y%m%d%H%M%S.yaml.gz");
    my $filePath = file( $self->config->{cherryepg}{scheme}, $filename );

    try {
        gzip_to_file( $scheme, $filePath );
        $logger->info("add scheme to store as [$filename]");
        return $filename;
    } catch {
        $logger->error("add scheme to store as [$filename]");
    };
} ## end sub schemeStoreSave

=head3 schemeStoreLast ( )

Get the last scheme from scheme directory.
Return scheme and date on success.

=cut

sub schemeStoreLast {
    my ($self) = @_;

    my $store = dir( $self->config->{cherryepg}{scheme} );

    if ( -d -r $store and opendir( my $dir, $store ) ) {
        my @files = grep {/\.yaml.gz$/} readdir($dir);
        closedir($dir);

        @files = sort { $a cmp $b } @files;

        my $last = pop @files;

        my $file = file( $store, $last );

        # open the file
        my $scheme;
        try {
            my $content = gunzip_file($file);
            $scheme = YAML::XS::Load($content);
        };

        my $t = Time::Piece->strptime( $last, "%Y%m%d%H%M%S.yaml.gz" );

        $scheme->{source}{timestamp} = $t->strftime();

        return $scheme;
    } ## end if ( -d -r $store and ...)
    return;
} ## end sub schemeStoreLast

=head3 schemeStoreDelete ( $filename )

Delete $filename 

=cut

sub schemeStoreDelete {
    my ( $self, $filename ) = @_;

    my $store = dir( $self->config->{cherryepg}{scheme} );
    my $file  = file( $store, $filename . '.yaml.gz' );

    if ( -e $file ) {
        return unlink($file);
    } else {
        return 0;
    }
} ## end sub schemeStoreDelete

=head3 schemeStoreList ( )

List all files in schemeStore with detailed data.

=cut

sub schemeStoreList {
    my ($self) = @_;

    my $store = dir( $self->config->{cherryepg}{scheme} );

    my @list = ();

    if ( -d -r $store and opendir( my $dir, $store ) ) {
        my @files = grep {/\.yaml.gz$/} readdir($dir);
        closedir($dir);

        @files = sort { $b cmp $a } @files;

        foreach my $current (@files) {
            my $file = file( $store, $current );

            # open the file
            my $item = try {
                my $content = gunzip_file($file);
                my $scheme  = YAML::XS::Load($content);
                my $t       = Time::Piece->strptime( $current, "%Y%m%d%H%M%S.yaml.gz" );
                $current =~ s/\.yaml\.gz//;
                return {
                    timestamp   => $t->epoch,
                    eit         => scalar @{ $scheme->{eit} },
                    channel     => scalar @{ $scheme->{channel} },
                    rule        => scalar @{ $scheme->{rule} },
                    source      => $scheme->{source}{filename},
                    description => $scheme->{source}{description} // '',
                    filename    => $current
                };
            };
            push( @list, $item ) if $item;
        } ## end foreach my $current (@files)
        return \@list;
    } ## end if ( -d -r $store and ...)
    return;
} ## end sub schemeStoreList

=head1 AUTHOR

This software is copyright (c) 2019-2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE.txt', which is part of this source code package.

=cut

1;
