package cherryEpg v2.5.33;

use 5.024;
use utf8;
use Carp;
use cherryEpg::Epg;
use cherryEpg::Grabber;
use cherryEpg::Ingester;
use cherryEpg::Player;
use cherryEpg::Scheme;
use Fcntl      qw/:flock O_WRONLY O_CREAT O_EXCL/;
use File::Find qw(find);
use File::Path qw(remove_tree);
use IPC::ConcurrencyLimit;
use Log::Log4perl::Level;
use Log::Log4perl;
use Moo;
use Parallel::ForkManager;
use Path::Class;
use Time::Piece;
use Try::Tiny;
use YAML::XS;
use open qw ( :std :encoding(UTF-8));

with( 'MooX::Singleton', 'cherryEpg::Taster', 'cherryEpg::Cloud' );

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

  # check if file exists
  if ( $configFile and -e $configFile ) {

    my $configuration = YAML::XS::LoadFile($configFile);

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

  $SIG{__WARN__} = sub {
    return if $^S;    # we're in an eval or try

    chomp( my $msg = shift );
    Log::Log4perl->get_logger("system")->warn($msg);
  }; ## end sub

  $SIG{__DIE__} = sub {
    return if $^S;               # we're in an eval or try
    die @_ if not defined $^S;

    chomp( my $msg = shift );
    Log::Log4perl->get_logger("system")->fatal($msg);
    die "$msg\n";
  } ## end sub
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

=head3 deleteStock( )

Delete stock directory.

=cut

sub deleteStock {
  my ($self) = @_;

  my $logger = Log::Log4perl->get_logger("system");

  my $dir = $self->config->{core}{stock};

  $logger->info("delete files from stock directory");
  return remove_tree( $dir, { keep_root => 1 } );
} ## end sub deleteStock

=head3 deleteIngest( )

Delete directories in ingest.

=cut

sub deleteIngest {
  my ($self) = @_;

  my $logger = Log::Log4perl->get_logger("system");

  my $dir = $self->config->{core}{ingest};

  $logger->info("delete subdirs in ingest directory");
  return remove_tree( $dir, { keep_root => 1 } );
} ## end sub deleteIngest

=head3 deleteSection( )

Delete all entries from section and version table.

=cut

sub deleteSection {
  my ($self) = @_;

  my $logger = Log::Log4perl->get_logger("system");

  my $count = $self->epg->reset();

  $logger->info("reset section and version table");
  return $count;
} ## end sub deleteSection

=head3 resetDatabase( )

Clean all data and intialize database.

=cut

sub resetDatabase {
  my ($self) = @_;

  my $logger = Log::Log4perl->get_logger("system");

  $logger->info("clean database - empty tables");

  return $self->epg->initdb();
} ## end sub resetDatabase

=head3 purgeChannel( $channel)

Reset ingest by deleting files for channel $channel.
If no channel defined, go for all.
Return ref. to list of removed files.

=cut

sub purgeChannel {
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
} ## end sub purgeChannel

=head3 resetChannel( $channel)

Reset ingest by removing *.md5.parsed files for channel $channel.
If no channel defined, go for all.
Return number of removed files.

=cut

sub resetChannel {
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
} ## end sub resetChannel

=head3 ingestChannel( $channel, $dump)

Run the ingester for channel $channel (channel hash).
If $dump also dump parser output.
Return report as hashref.

=cut

sub ingestChannel {
  my ( $self, $channel, $dump ) = @_;

  my $myIngest = cherryEpg::Ingester->new( channel => $channel, dump => $dump // 0 );
  return $myIngest->walkDir() if $myIngest->parserReady;
} ## end sub ingestChannel

=head3 grabChannel( $channel)

Run the grabber for channel $channel (channel hash).
Return report as hashref.

=cut

sub grabChannel {
  my ( $self, $channel ) = @_;

  my $myGrabber = cherryEpg::Grabber->new( channel => $channel );
  return $myGrabber->grab();
} ## end sub grabChannel

=head3 parallelGrabIngestChannel( $target, $grab, $ingest)

Grab and ingest channel schedules depending on target [daily, hourly, weekly]
Return list of grabbed files.

=cut

sub parallelGrabIngestChannel {
  my ( $self, $target, $grab, $ingest ) = @_;

  my $logger = Log::Log4perl->get_logger("grabber");

  if ( $self->isLinger ) {
    $logger->trace("skip grab&ingest in linger mode");
    return [];
  }

  # just define
  $target //= "all";
  $grab   //= 1;
  $ingest //= 1;

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
      } else {
        $logger->error( "process terminated without results", $ident );
      }
    }
  );

  my $channelList = $self->epg->listChannel();

CHANNELMULTI_LOOP:
  foreach my $channel (@$channelList) {

    if ( !$channel->{grabber}{disabled} ) {
      if ( $target eq "all" or $channel->{grabber}{update} eq $target ) {

        # fork proces
        my $pid = $pm->start( $channel->{channel_id} ) and next CHANNELMULTI_LOOP;

        my $result = [];

        # grab
        $result = $self->grabChannel($channel) if $grab;

        # ingest
        $self->ingestChannel($channel) if $ingest;

        $pm->finish( 0, $result );
      } ## end if ( $target eq "all" ...)
    } ## end if ( !$channel->{grabber...})
    $pm->finish(0);
  } ## end CHANNELMULTI_LOOP: foreach my $channel (@$channelList)
  $pm->wait_all_children;

  return $collected;
} ## end sub parallelGrabIngestChannel

=head3 buildEit( $eit)

Check if EIT with $eit must be updated and when needed build and export them to files.
Return filepath updated!

=cut

sub buildEit {
  my ( $self, $eit ) = @_;

  my $logger = Log::Log4perl->get_logger("builder");

  my $eit_id = $eit->{eit_id};
  my $subdir = $eit->{option}{LINGERONLY} ? '/COMMON.linger/' : '/';

  $logger->trace( "build EIT", undef, $eit_id );

  my $report = {
    eit_id => $eit_id,
    update => undef,
    list   => []
  };

  my $epg = $self->epgInstance;
  $report->{update} = $epg->updateEit($eit_id);

  my $filename = sprintf( "eit_%03i", $eit_id );

  my $player = cherryEpg::Player->new();

  if ( !defined $report->{update} ) {
    $logger->error( "build EIT", undef, $eit_id );
  } elsif ( $report->{update} || !$player->isPlaying( $subdir, $filename ) ) {

    # unless specified use default timeFrame for builing
    my $timeFrame = $self->config->{core}{timeFrame} // 29;

    my $pes = $epg->getEit( $eit->{eit_id}, $timeFrame );

    my $dst = $eit->{output};

    # for backward compatibility remove the method stuff
    $dst =~ s|^udp://||;

    my $specs = {
      interval => $timeFrame * 1000,    # must be in ms
      dst      => $dst,
      title    => "Dynamic EIT"
    };

    $specs->{tdt} = 1 if $eit->{option}{TDT};
    $specs->{pcr} = 1 if $eit->{option}{PCR};
    $specs->{title} .= ' - ' . $eit->{option}{TITLE} if $eit->{option}{TITLE};

    # limit bitrate
    if ( exists $eit->{option}{MAXBITRATE} and $eit->{option}{MAXBITRATE} ) {
      my $maxBitrate     = $eit->{option}{MAXBITRATE};
      my $currentBitrate = int( length($pes) * 8 / $timeFrame );
      if ( $currentBitrate > $maxBitrate ) {
        delete $specs->{timeFrame};
        $specs->{bitrate} = $maxBitrate + 0;
        $logger->info( "MaxBitrate protection activated ($currentBitrate bps > $maxBitrate bps)", undef, $eit_id );
      }
    } ## end if ( exists $eit->{option...})

    # remove file if no data
    if ( length($pes) == 0 ) {
      $player->delete( $subdir, $filename );

      # or try to play
    } elsif ( $player->arm( $subdir, $filename, $specs, \$pes, $eit_id ) && $player->play( $subdir, $filename ) ) {
      push( $report->{list}->@*, { path => $subdir . $filename, success => 1 } );
    } else {
      push( $report->{list}->@*, { path => $subdir . $filename, success => 0, msg => 'play failed' } );
    }

    if ( $eit->{option}{COPY} ) {

      # copy stream to other destination
      my $counter = 1;
      $specs->{title} = "Dynamic EIT cc";
      foreach ( split( /\s*[|;+]\s*/, $eit->{option}{COPY} ) ) {
        $specs->{dst} = $_;
        my $theCopy = sprintf( "eit_%03ix%02i", $eit->{eit_id}, $counter++ );
        if ( length($pes) == 0 ) {
          $player->delete( '/', $theCopy );
        } elsif ( $player->arm( '/', $theCopy, $specs, \$pes, $eit_id ) && $player->play( '/', $theCopy ) ) {
          push( $report->{list}->@*, { path => '/' . $theCopy, success => 1 } );
        } else {
          push( $report->{list}->@*, { path => '/' . $theCopy, success => 0, msg => 'play failed' } );
        }
      } ## end foreach ( split( /\s*[|;+]\s*/...))
    } ## end if ( $eit->{option}{COPY...})
  } else {
    $logger->trace( "up-to-date", undef, $eit_id );
  }
  return $report;
} ## end sub buildEit

=head3 parallelUpdateEit()

When not in linger mode, check if EIT must be updated and when needed build and export them to files.
In linger mode sync .cts files from cloud provider to carousel.

=cut

sub parallelUpdateEit {
  my ($self) = @_;
  my $logger;

  if ( $self->isLinger ) {
    $logger = Log::Log4perl->get_logger("system");
    $logger->info("sync from cloud");
    return $self->syncLinger();
  }

  $logger = Log::Log4perl->get_logger("builder");

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

  my @pidLauched;
  local $SIG{ALRM} = sub {
    my $killed = kill( 9, @pidLauched );
    $logger->fatal("eit building time exceeded [$killed]");
    exit 1;
  };

  # stop all after timeout
  alarm(55) unless $self->config->{core}{disableTimeout};

  my $doneList      = [];
  my $parallelTasks = $self->config->{core}{parallelTasks} // 3;
  my $pm            = Parallel::ForkManager->new($parallelTasks);

  $logger->trace("start eit multibuild with $parallelTasks tasks");

  # this is needed to get return data from forked processes
  $pm->run_on_finish(
    sub {
      my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $result ) = @_;
      if ( defined($result) ) {
        push( $doneList->@*, $result );
      }
    }
  );

  my $allEit = $self->epg->listEit();

EITMULTI_LOOP:
  foreach my $eit (@$allEit) {

    my $pid;
    if ( $pid = $pm->start ) {
      push( @pidLauched, $pid );
      next EITMULTI_LOOP;
    }

    my $result = $self->buildEit($eit);

    $pm->finish( 0, $result );
  } ## end EITMULTI_LOOP: foreach my $eit (@$allEit)
  $pm->wait_all_children;

  alarm(0);

  # mapping build EIT to linger sites subdir
  my $pathByEit = {};
  map { $pathByEit->{ $_->{eit_id} } = $_->{list}[0]->{path} . '.cts' if $_->{list}->@* } $doneList->@*;
  $self->makeSymbolicLink($pathByEit) if scalar( keys(%$pathByEit) );

  return $doneList;
} ## end sub parallelUpdateEit

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
