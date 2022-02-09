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
use cherryEpg::Epg;
use cherryEpg::Grabber;
use cherryEpg::Ingester;
use cherryEpg::Scheme;
use cherryEpg::Player;
use Parallel::ForkManager;
use IPC::ConcurrencyLimit;
use Fcntl qw/:flock O_WRONLY O_CREAT O_EXCL/;
use open qw ( :std :encoding(UTF-8));

our $VERSION = '2.1.4';

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

            # generate standard paths
            foreach (qw( scheme ingest stock carousel)) {
                $configuration->{core}{$_} = $configuration->{core}{basedir} . "$_/";
            }

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

    # replace database credentials for the logging system
    foreach (qw( datasource user pass)) {
        my $variable = $self->config->{core}{$_};
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
        carp("Initialization of logging system failed");
    };

} ## end sub BUILD

=head3 epgInstance( )

Get a new epg object with own database connection.

=cut

sub epgInstance {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");
    my $config = $self->config->{core};

    my $epg = cherryEpg::Epg->new( config => $config );

    if ( $epg->dbh ) {
        return $epg;
    } else {
        croak("Connect to database failed");
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

    $count = $self->epg->cleanupLog();

    $logger->info("cleanup old log records [$count]");
} ## end sub cleanup

=head3 stockDelete( )

Delete stock directory.

=cut

sub stockDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $dir = $self->config->{core}{stock};

    $logger->info("delete files from stock directory");
    return remove_tree( $dir, { keep_root => 1 } );
} ## end sub stockDelete

=head3 ingestDelete( )

Delete directories in ingest.

=cut

sub ingestDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $dir = $self->config->{core}{ingest};

    $logger->info("delete subdirs in ingest directory");
    return remove_tree( $dir, { keep_root => 1 } );
} ## end sub ingestDelete

=head3 ruleDelete( )

Delete all rules in database.

=cut

sub ruleDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $count = $self->epg->deleteRule();

    $logger->info("delete rules from database {$count}");
    return $count;
} ## end sub ruleDelete

=head3 sectionDelete( )

Delete all entries from section and version table.

=cut

sub sectionDelete {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $count = $self->epg->reset();

    $logger->info("reset section and version table");
    return $count;
} ## end sub sectionDelete

=head3 channelDelete( $channel_id)

Delete/wipe channel with $channel_id from database.

=cut

sub channelDelete {
    my ( $self, $channel_id ) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    my $dir = dir( $self->config->{core}{ingest}, $channel_id );

    remove_tree( $dir, { keep_root => 0 } );

    my $result = $self->epg->deleteChannel($channel_id);

    $logger->info( "wipe service from database and disk", $channel_id );
    return $result;
} ## end sub channelDelete

=head3 databaseReset( )

Clean all data and intialize database.

=cut

sub databaseReset {
    my ($self) = @_;

    my $logger = Log::Log4perl->get_logger("system");

    $logger->info("clean database - empty tables");

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
        $dir = dir( $self->config->{core}{ingest}, $channel->{channel_id} );
    } else {
        $dir = dir( $self->config->{core}{ingest} );
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
        $dir = dir( $self->config->{core}{ingest}, $channel->{channel_id} );
    } else {
        $dir = dir( $self->config->{core}{ingest} );
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

=head3 channelIngest( $channel, $dump)

Run the ingester for channel $channel (channel hash).
If $dump also dump parser output.
Return report as hashref.

=cut

sub channelIngest {
    my ( $self, $channel, $dump ) = @_;

    my $myIngest = cherryEpg::Ingester->new( channel => $channel, dump => $dump // 0 );
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

=head3 channelMulti( $target, $grab, $ingest)

Grab and ingest channel schedules depending on target [daily, hourly, weekly]
Return list of grabbed files.

=cut

sub channelMulti {
    my ( $self, $target, $grab, $ingest ) = @_;

    # just define
    $target //= "all";
    $grab   //= 1;
    $ingest //= 1;

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

    my $collected     = [];
    my $parallelTasks = $self->config->{core}{parallelTasks} // 3;
    my $pm            = Parallel::ForkManager->new($parallelTasks);

    my @job;
    push( @job, 'grab' )   if $grab;
    push( @job, 'ingest' ) if $ingest;

    $logger->info( "start multi " . join( '&', @job ) . " [$target] with $parallelTasks tasks" );

    # this is needed to get return data from forked processes
    $pm->run_on_finish(
        sub {
            my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $result ) = @_;
            if ( defined($result) ) {
                push( $collected->@*, @$result );
            }
        }
    );

    my $channelList = $self->epg->listChannel();

CHANNELMULTI_LOOP:
    foreach my $channel (@$channelList) {

        if ( !$channel->{grabber}{disabled} ) {
            if ( $target eq "all" or $channel->{grabber}{update} eq $target ) {

                # fork proces
                my $process = $pm->start and next CHANNELMULTI_LOOP;

                my $result = [];

                # grab
                $result = $self->channelGrab($channel) if $grab;

                # ingest
                $self->channelIngest($channel) if $ingest;

                $pm->finish( 0, $result );
            } ## end if ( $target eq "all" ...)
        } ## end if ( !$channel->{grabber...})
        $pm->finish(0);
    } ## end CHANNELMULTI_LOOP: foreach my $channel (@$channelList)
    $pm->wait_all_children;

    return $collected;
} ## end sub channelMulti

=head3 eitBuild( $eit)

Check if EIT with $eit must be updated and when needed build and export them to files.
Return filepath updated!

=cut

sub eitBuild {
    my ( $self, $eit ) = @_;

    my $logger = Log::Log4perl->get_logger("builder");

    my $eit_id = $eit->{eit_id};
    $logger->trace( "build EIT", undef, $eit_id );

    my $report = {
        update => undef,
        list   => []
    };

    my $epg = $self->epgInstance;
    $report->{update} = $epg->updateEit($eit_id);

    my $filename = sprintf( "eit_%03i", $eit->{eit_id} );

    my $player = cherryEpg::Player->new();

    if ( !defined $report->{update} ) {
        $logger->error( "build EIT", undef, $eit_id );
    } elsif ( $report->{update} || !$player->isPlaying($filename) ) {
        my $interval = 30;

        my $pes = $epg->getEit( $eit->{eit_id}, $interval );

        $eit->{output} =~ m|udp://(.+)$|;
        my $dst = $1;

        my $specs = {
            interval => $interval * 1000,    # must be in ms
            dst      => $dst,
            title    => "Dynamic EIT"
        };

        $specs->{tdt} = 1 if $eit->{option}{TDT};
        $specs->{pcr} = 1 if $eit->{option}{PCR};

        # limit bitrate
        if ( exists $eit->{option}{MAXBITRATE} and $eit->{option}{MAXBITRATE} ) {
            my $maxBitrate     = $eit->{option}{MAXBITRATE};
            my $currentBitrate = int( length($pes) * 8 / $interval );
            if ( $currentBitrate > $maxBitrate ) {
                delete $specs->{interval};
                $specs->{bitrate} = $maxBitrate + 0;
                $logger->info( "MaxBitrate protection activated ($currentBitrate bps > $maxBitrate bps)", undef, $eit_id );
            }
        } ## end if ( exists $eit->{option...})

        if ( $player->arm( $filename, $specs, \$pes, $eit_id ) && $player->play($filename) ) {
            push( $report->{list}->@*, { filename => $filename, success => 1 } );
        } else {
            push( $report->{list}->@*, { filename => $filename, success => 0, msg => 'play failed' } );
        }

        if ( $eit->{option}{COPY} ) {

            # copy stream to other destination
            my $counter = 1;
            $specs->{title} = "Dynamic EIT cc";
            say $eit->{option}{COPY};
            foreach ( split( /\s*[|;+]\s*/, $eit->{option}{COPY} ) ) {
                say $_;
                $specs->{dst} = $_;
                $filename = sprintf( "eit_%03ix%02i", $eit->{eit_id}, $counter++ );
                if ( $player->arm( $filename, $specs, \$pes, $eit_id ) && $player->play($filename) ) {
                    push( $report->{list}->@*, { filename => $filename, success => 1 } );
                } else {
                    push( $report->{list}->@*, { filename => $filename, success => 0, msg => 'play failed' } );
                }
            } ## end foreach ( split( /\s*[|;+]\s*/...))
        } ## end if ( $eit->{option}{COPY...})
    } else {
        $logger->trace( "up-to-date", undef, $eit_id );
    }
    return $report;
} ## end sub eitBuild

=head3 eitMulti()

Check if EIT must be updated and when needed build and export them to files.

=cut

sub eitMulti {
    my ($self) = @_;

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

    my $collected     = [];
    my $parallelTasks = $self->config->{core}{parallelTasks} // 3;
    my $pm            = Parallel::ForkManager->new($parallelTasks);

    $logger->trace("start eit multibuild with $parallelTasks tasks");

    # this is needed to get return data from forked processes
    $pm->run_on_finish(
        sub {
            my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $result ) = @_;
            if ( defined($result) ) {
                push( $collected->@*, $result );
            }
        }
    );

    my $allEit = $self->epg->listEit();

EITMULTI_LOOP:
    foreach my $eit (@$allEit) {

        my $process = $pm->start and next EITMULTI_LOOP;

        my $result = $self->eitBuild($eit);

        $pm->finish( 0, $result );
    } ## end EITMULTI_LOOP: foreach my $eit (@$allEit)
    $pm->wait_all_children;

    return $collected;    # FIXME
} ## end sub eitMulti

=head1 AUTHOR

This software is copyright (c) 2019-2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
