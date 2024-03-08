package cherryEpg::Taster;

use 5.024;
use utf8;
use cherryEpg::Git;
use File::Temp qw( tempfile unlink0);
use IPC::Run3  qw(run3);
use JSON::XS;
use Moo::Role;
use Net::Curl::Easy qw(:constants );
use Net::NTP        qw(get_ntp_response);
use Readonly;
use Sys::Hostname;
use Time::Piece;
use Try::Tiny;

# status code used in NAGIOS/NAEMON
Readonly my $OK       => 0;
Readonly my $WARNING  => 1;
Readonly my $CRITICAL => 2;
Readonly my $UNKNOWN  => 3;

after BUILD => sub {
  my ( $self, $arg ) = @_;
  my $taster = $self->{config}{core}{taster};

  # number of days in future to check default
  $taster->{eventbudget}{days} //= 7;

  # this is the interval of days where EIT data must be defined, if not -> warning
  $taster->{eventbudget}{threshold}{warning} //= 3;

  # this is the interval of days where EIT data must be defined, if not -> critical
  # 1 - today
  # 2 - today and tomorrow
  $taster->{eventbudget}{threshold}{critical} //= 2;

  # check internet connection
  $taster->{internet}{url}     //= "https://getsamplefiles.com/download/jpg/sample-4.jpg";
  $taster->{internet}{timeout} //= 5;
};    ## end sub BUILD

=head3 eventBudget ( )

Report the eventbudget for all channels for n days in future(pos) or past (neg) days

=cut

sub eventBudget {
  my ( $self, $days ) = @_;
  $days = $days // $self->{config}{core}{taster}{eventbudget}{days};
  my @report;

  my $lastUpdate = $self->epg->listChannelLastUpdate();
  return unless $lastUpdate;
  my $eBudget = $self->getMultiInterval($days);

  # change from hash to array sorted by progname
  foreach my $channel_id ( sort { $eBudget->{$a}{name} cmp $eBudget->{$b}{name} } keys %$eBudget ) {

    my $name  = $eBudget->{$channel_id}{name};
    my $count = $eBudget->{$channel_id}{count};

    my $status = $OK;
    my $day    = 0;
    while ( $status < $CRITICAL and $day <= $#$count ) {
      if ( $day < $self->{config}{core}{taster}{eventbudget}{threshold}{critical} and $$count[$day] == 0 ) {
        $status = $CRITICAL;
      } elsif ( $day < $self->{config}{core}{taster}{eventbudget}{threshold}{warning} and $$count[$day] == 0 ) {
        $status = $WARNING;
      } else {
        $$count[$day] += 0;
      }
      $day += 1;
    } ## end while ( $status < $CRITICAL...)

    # make numeric
    if ( $lastUpdate->{$channel_id}{timestamp} > 0 ) {
      $lastUpdate->{$channel_id}{timestamp} += 0;
    } else {
      $lastUpdate->{$channel_id}{timestamp} = undef;
    }

    my $entry = {
      name   => $eBudget->{$channel_id}{name},
      update => $lastUpdate->{$channel_id}{timestamp},
      budget => $count,
      id     => $channel_id + 0,
      status => $status
    };
    push( @report, $entry );
  } ## end foreach my $channel_id ( sort...)

  return \@report;
} ## end sub eventBudget

sub getMultiInterval {
  my ( $self, $days ) = @_;
  my $result = {};

  if ( $days >= 0 ) {

    # count events per service for today next $self->{days} and remaining days
    for ( my $dayCount = 0 ; $dayCount <= $days ; $dayCount++ ) {
      my $serviceList;
      if ( $dayCount == $days ) {

        # get number of all remaining events in database
        $serviceList = $self->epg->listChannelEventCount( $dayCount, 65535 );
      } else {
        $serviceList = $self->epg->listChannelEventCount( $dayCount, $dayCount + 1 );
      }

      if ( $dayCount == 0 ) {
        foreach my $row (@$serviceList) {
          my ( $name, $id, $count ) = @$row;
          $result->{$id}{name}  = $name;
          $result->{$id}{count} = [$count];
        }
      } else {
        foreach my $row (@$serviceList) {
          my ( $name, $id, $count ) = @$row;
          push( $result->{$id}{count}->@*, $count );
        }
      } ## end else [ if ( $dayCount == 0 ) ]
    } ## end for ( my $dayCount = 0 ...)
    return $result;

  } else {

    # count events per service for previous days but not today
    for ( my $dayCount = $days ; $dayCount < 0 ; $dayCount++ ) {
      my $serviceList = $self->epg->listChannelEventCount( $dayCount, $dayCount + 1 );

      # we are looking in the past and therefore we show count of events negative
      if ( $dayCount == $days ) {
        foreach my $row (@$serviceList) {
          my ( $name, $id, $count ) = @$row;
          $result->{$id}{name}  = $name;
          $result->{$id}{count} = [ -$count ];
        }
      } else {
        foreach my $row (@$serviceList) {
          my ( $name, $id, $count ) = @$row;
          push( $result->{$id}{count}->@*, -$count );
        }
      } ## end else [ if ( $dayCount == $days)]
    } ## end for ( my $dayCount = $days...)
    return $result;
  } ## end else [ if ( $days >= 0 ) ]

} ## end sub getMultiInterval

=head3 ringelspiel ( )

Return ringelspiel status structure.

=cut

sub ringelspiel {
  my ($self) = @_;

  my $url = "http://localhost:5001";
  my $response_body;
  my $curl = Net::Curl::Easy->new();
  $curl->setopt( CURLOPT_URL,       $url );
  $curl->setopt( CURLOPT_WRITEDATA, \$response_body );

  my $success = try {
    $curl->perform();
    1;
  };

  my $decoded;

  if ($success) {
    $decoded = JSON::XS::decode_json($response_body);
    my $d     = localtime( $decoded->{timestamp} );
    my $start = localtime( $decoded->{timestamp} - $decoded->{runtime} );
    $decoded->{timestamp} = $d->strftime();        # report time
    $decoded->{start}     = $start->datetime();    # ringelspiel launch time
    if ( exists $decoded->{target} ) {
      $decoded->{target} = $decoded->{version} .= " " . $decoded->{target};
      delete $decoded->{target};
    }
    if ( $decoded->{exceed} ) {
      $decoded->{status}  = $WARNING;
      $decoded->{message} = 'Public release - bitrate exceeded';
    } elsif ( $decoded->{trialend} ) {
      $decoded->{status}  = $WARNING;
      $decoded->{message} = 'Trial period has ended';
    } else {
      $decoded->{status}  = $OK;
      $decoded->{message} = 'Streaming';
    }

    foreach my $stream ( $decoded->{streams}->@* ) {
      my $last = 0;
      foreach my $file ( $stream->{files}->@* ) {
        $last = $file->{last} if $file->{last} > $last;
        my $t = localtime( $file->{last} );
        $file->{last} = $t->datetime;
      }
      my $t = localtime($last);
      $stream->{last} = $t->datetime;
    } ## end foreach my $stream ( $decoded...)
  } else {
    my $t = localtime;
    $decoded = {
      message   => "Carousel not responding. Check ringelspiel",
      status    => $CRITICAL,
      timestamp => $t->strftime()

    };
  } ## end else [ if ($success) ]

  # the timing key subtree is not processed just forwarded

  return $decoded;
} ## end sub ringelspiel

=head3 versionReport ( )

Report installed version numbers

=cut

sub versionReport {
  my ($self) = @_;

  # debian
  my $deb = try {
    `dpkg -s cherryepg 2>&1`;
  };

  if ( $deb =~ m|Version: (.*)$|m ) {
    $deb = $1;
  } else {
    $deb = undef;
  }

  # os
  my $os = try {
    `cat /etc/issue`;
  };

  $os =~ s/\\[nl]//g;
  $os =~ s/\s*$//g;

  my $report = {
    package     => $deb,
    cherryEpg   => $cherryEpg::VERSION . '',
    ringelspiel => $self->ringelspiel->{version},
    branch      => cherryEpg::Git->new()->branch,
    os          => $os,
  };

  return $report;
} ## end sub versionReport

=head3 databaseReport ( )

Get mysql database summary status

=cut

sub databaseReport {
  my ($self) = @_;

  my $healthCheck = $self->epg->healthCheck;

  if ($healthCheck) {
    my @list;
    my $status = $OK;

    my $report = {};

    foreach my $t (@$healthCheck) {
      my @fields = @$t;
      $report->{ $fields[0] } = $fields[2];
    }

    return {
      status  => $OK,
      message => "Running " . $self->epg->version,
      report  => $report,
    };
  } else {
    return {
      status  => $CRITICAL,
      message => "No connection",
      report  => {},
    };
  } ## end else [ if ($healthCheck) ]
} ## end sub databaseReport

=head3 ringelspielReport ( )

Report ringelspiel summary information.

=cut

sub ringelspielReport {
  my ($self) = @_;

  my $ringelspiel = $self->ringelspiel;

  if ( $ringelspiel->{version} ) {
    my @list;
    my $streamCount = 0;
    my $bitrate     = 0;

    foreach my $s ( $ringelspiel->{streams}->@* ) {
      $streamCount += 1;
      $bitrate     += $s->{bitrate};
      $s->{last} = localtime->strptime( $s->{last}, "%Y-%m-%dT%H:%M:%S" )->epoch();
      foreach my $f ( $s->{files}->@* ) {
        $f->{last} = localtime->strptime( $f->{last}, "%Y-%m-%dT%H:%M:%S" )->epoch();
      }
    } ## end foreach my $s ( $ringelspiel...)

    # 2000-02-29T12:34:56
    my $start = localtime->strptime( $ringelspiel->{start}, "%Y-%m-%dT%H:%M:%S" )->epoch();

    $ringelspiel->{start}   = $start;
    $ringelspiel->{bitrate} = $bitrate;

    my $report;
    %$report = %$ringelspiel{qw( message status)};
    delete @$ringelspiel{qw( message status timestamp)};
    $report->{report} = $ringelspiel;

    return $report;
  } else {
    return {
      status  => $CRITICAL,
      message => "Not responding",
      report  => {},
    };
  } ## end else [ if ( $ringelspiel->{version...})]
} ## end sub ringelspielReport

=head3 uptime ( )

Report system uptime in seconds.

=cut

sub uptime {
  my ($self) = @_;

  my $uptime = try {
    `cat /proc/uptime`;
  };

  if ( $uptime =~ m/^(\d+)\./ ) {
    return $1;
  } else {
    return undef;
  }
} ## end sub uptime

=head3 ntpReport ( )

Report system ntp status

=cut

sub ntpReport {
  my ($self) = @_;

  my %ntp;

  my $success = try {
    %ntp = get_ntp_response('localhost');
    1;
  };

  if ($success) {
    my $stratum = $ntp{Stratum};
    my $report  = {
      stratum   => $stratum,
      offset    => $ntp{Offset},
      reference => $ntp{'Reference Clock Identifier'}
    };

    if ( $stratum > 0 ) {
      return {
        status  => $OK,
        message => "Reference o.k.",
        report  => $report,
      };
    } elsif ( $ntp{'Reference Clock Identifier'} =~ m/STEP|INIT/ ) {
      return {
        status  => $WARNING,
        message => "Reference - " . $ntp{'Reference Clock Identifier'},
        report  => $report,
      };

    } else {
      return {
        status  => $WARNING,
        message => "Reference not o.k.",
        report  => $report,
      };
    } ## end else [ if ( $stratum > 0 ) ]
  } else {
    return {
      status  => $CRITICAL,
      message => "Not running",
      report  => {},
    };
  } ## end else [ if ($success) ]
} ## end sub ntpReport

=head3 internetReport ()

Check internet connection 

=cut

sub internetReport {
  my ($self) = @_;

  my $taster  = $self->{config}{core}{taster};
  my $timeout = $taster->{internet}{timeout};
  my ( $fh, $tempfile ) = tempfile( TEMPLATE => 'downloadXXXXX', TMPDIR => 1, UNLINK => 1 );
  my $common = "-t 1 --timeout=$timeout -O $tempfile";

  my $url = $taster->{internet}{url};
  my $err = "-";

  run3( "wget $common $url", \undef, \undef, \$err );

  unlink0( $fh, $tempfile );

  if ( $? != 0 ) {
    if ( $err =~ /unable to resolve host address/m ) {
      return { status => $WARNING, message => "DNS Lookup failed" };
    } else {
      return { status => $CRITICAL, message => "No connection" };
    }
  } else {
    return { status => $OK, message => "Connected" };
  }
} ## end sub internetReport

=head3 systemReport ( )

Report system ntp status

=cut

sub systemReport {
  my ($self) = @_;

  my $report;
  my $status  = $OK;
  my $message = "Stable";

  # ip interfaces
  my $ip = try {
    `ip -f inet addr show | grep brd`;
  };

  while ( $ip =~ /inet (.+) brd.+ (.+)$/gm ) {
    $report->{network}{$2} = $1;
  }

  my $route = try {
    `ip route`;
  };

  $route =~ s/\n/\r/gm;

  $report->{network}{route} = $route;


  # cpuinfo
  my $cpuinfo = try {
    `cat /proc/cpuinfo`;
  };

  my @line = split( /\n/, $cpuinfo );
  my ($model) = grep( {/model name/} @line );

  if ( $model =~ m/model name\s*: (.+)$/ ) {
    $report->{cpu}{model} = $1;
  }

  my $count = grep {/processor/} @line;
  $report->{cpu}{cores} = $count;

  # diskspace
  my $workdir = try {
    `df --output=avail -B 1 "$self->{config}{core}{basedir}" | tail -n 1`;
  };

  chomp $workdir;
  $report->{diskspace}{home} = $workdir;

  my $tmpdir = try {
    `df --output=avail -B 1 "/tmp" | tail -n 1`;
  };

  chomp $tmpdir;
  $report->{diskspace}{tmp} = $tmpdir;

  # load
  my $load = try {
    `cat /proc/loadavg`;
  };

  if ( $load =~ m/^(\d+\.\d+\s\d+\.\d+\s\d+\.\d+)\s/ ) {
    $report->{load} = $1;
  }

  # memory
  my $meminfo = try {
    `cat /proc/meminfo`;
  };

  @line = split( /\n/, $meminfo );
  my $element;

  foreach (@line) {
    if (/(.+):\s+(\d+) kb/i) {
      $element->{$1} = $2;
    }
  }

  my @keys = qw( MemTotal MemAvailable );
  foreach (@keys) {
    my $name = lc $_;
    $name =~ s/mem//;
    $report->{memory}{$name} = $element->{$_};

  } ## end foreach (@keys)

  return {
    status  => $status,
    message => $message,
    report  => $report,
  };
} ## end sub systemReport

=head3 eventBudgetReport ( )

Report Epg builder status.

=cut

sub eventBudgetReport {
  my ($self) = @_;

  my $budget = $self->eventBudget();

  if ( !$budget ) {
    return {
      status  => $CRITICAL,
      message => "No connection",
      report  => [],
    };

  } ## end if ( !$budget )

  my $status  = $OK;
  my @message = ( "Data available", "Shortly out of data (less than 3 days left)", "Missing data" );

  # get the worst status
  foreach my $channel (@$budget) {
    $status = $channel->{status}
        if $status < $channel->{status};
  }

  return {
    report  => $budget,
    status  => $status,
    message => $message[$status]
  };

} ## end sub eventBudgetReport

=head3 lingerReport ( )

Report linger status.

=cut

sub lingerReport {
  my ($self) = @_;

  my $linger = $self->isLinger();

  return {
    report => {
      cloud => "cherryhill.eu",    # TODO
    },
    status  => 0,
    message => 'Last synchronization on xxxx',    # TODO
  };

} ## end sub lingerReport

=head3 announcerReport ( )

Report Announcer status.

=cut

sub announcerReport {
  my ($self) = @_;

  my $a = $self->epg->announcerLoad();

  if ( $a && ( $a->{present}{publish} || $a->{following}{publish} ) ) {
    my $msg = {};
    foreach ( 'present', 'following' ) {
      $msg->{$_} = $a->{$_}{text} if $a->{$_}{publish};
    }

    return {
      status  => $OK,
      message => "Active",
      report  => $msg,
    };

  } else {

    # inactive
    return undef;
  }
} ## end sub announcerReport

=head3 report ( )

Generate sysinfo overall report hash.

=cut

sub report {
  my ($self) = @_;

  my $timestamp = localtime;

  my $report = {
    timestamp => $timestamp->epoch(),
    version   => $self->versionReport(),
    modules   => {
      ntp      => $self->ntpReport(),
      system   => $self->systemReport(),
      playout  => $self->ringelspielReport(),
      database => $self->databaseReport(),
    },
    uptime => $self->uptime(),
  };

  # disable internet checking if url = "";
  $report->{modules}{internet} = $self->internetReport() if $self->{config}{core}{taster}{internet}{url};

  if ( $self->isLinger ) {
    $report->{modules}{linger} = $self->lingerReport();
    $report->{modules}{epg}    = {
      status  => 1,
      message => "Local EIT building disabled",
    };
  } else {
    $report->{modules}{epg}    = $self->eventBudgetReport();
    $report->{modules}{linger} = {
      status  => 1,
      message => "Disabled",
    };
  } ## end else [ if ( $self->isLinger )]

  my $announcer = $self->announcerReport();
  $report->{modules}{announcer} = $announcer if $announcer;

  my $status = $OK;
  foreach my $module ( keys %{ $report->{modules} } ) {
    $status = $report->{modules}{$module}{status} if $status < $report->{modules}{$module}{status};
  }

  $report->{status} = $status;

  return $report;
} ## end sub report

=head3 format ( $report )

Format the generated $report for text output.
If no $report given, just generate it.

=cut

sub format {
  my ( $self, $report ) = @_;

  $report = $self->report() if ( !$report );
  my $modules = $report->{modules};

  my $uptime      = $report->{uptime};
  my $t           = localtime( time - $uptime );
  my $systemStart = $t->strftime();
  $t = localtime( $report->{timestamp} );
  my $reportTime = $t->strftime();

  # convert seconds to days and hours
  my $days  = int( $uptime / ( 24 * 60 * 60 ) );
  my $hours = ( $uptime / ( 60 * 60 ) ) % 24;
  my $mins  = ( $uptime / (60) ) % 60;

  $uptime = $days > 1 ? "$days days, " : ( $days > 0 ? "$days day, " : "" );
  $uptime .= $hours > 0 ? sprintf( "%02i:%02i", $hours, $mins ) : "$mins min";

  my $i      = 0;
  my $output = "";

  format REPORT_TOP =
-- cherryTaster - Copyright 2024 Bojan Ramsak                 --- SYSTEM INFO --
Hostname: @<<<<<<<<<<<<<<<<<<   Date : @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
          hostname,           $reportTime
Uptime  : @<<<<<<<<<<<<<<<<<<   Since: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
          $uptime,                      $systemStart
.

  my $group;
  my $status;
  my $msg;
  my $errorCount = 0;
  my $data;
  my ( $channel_id, $channel_name, $channel_status, $channel_last );
  my @fields;

  format REPORT_GROUP =
--------------------------------------------------------------------------------
@<@<<<<<<<<<<<<: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
($status != 0 ? '!' : ''), $group, $msg
.

  format REPORT =
  - @<<<<<<<<<<: ^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
@fields
~~               ^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$fields[1]
.

  format REPORT_SUB =
    - @<<<<<<<<: ^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
@fields
~~               ^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$fields[1]
.

  format REPORT_DATABASE =
  - @<<<<<<<<<<: @>>>>>>> rows
@fields
.

  format REPORT_BOTTOM =
================================================================================
  @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
  $msg
.

  format REPORT_EPG =
      @>>>>>>>  @<<<<<<<<<<<<<<<  @<<<<<<<  @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
@fields
.

  format REPORT_EPG_HEADER =
    - id        channel_name      status    last_update
.

  format REPORT_CAROUSEL_HEADER =
    - ip               port   bitrate      PIDs  last_update
.

  format REPORT_CAROUSEL =
      @<<<<<<<<<<<<<<  @<<<<  @>>>>>> bps  @>>>  @<<<<<<<<<<<<<<<<<<<<<<<<
@fields
.

  open( RPRT, '>', \$output ) or die;
  binmode( RPRT, ":utf8" );
  select(RPRT);
  $-  = 0;
  $%  = 0;
  $=  = 100000;         # never paginate
  $^L = '';
  $^  = "REPORT_TOP";

  $group  = "version";
  $status = 0;
  $msg    = '';
  $data   = $report->{version};
  $~      = "REPORT_GROUP";
  write;
  $~ = "REPORT";
  foreach my $key ( sort keys %{$data} ) {
    @fields = ( $key, $data->{$key} // '-' );
    write;
  }

  $group = "system";
  $errorCount += 1 if $modules->{$group}->{status} != 0;
  $status = $modules->{$group}->{status};
  $msg    = $modules->{$group}->{message};
  $data   = $modules->{$group}->{report};
  $~      = "REPORT_GROUP";
  write;

  foreach my $key ( sort keys %{$data} ) {
    my $value;

    if ( ref( $data->{$key} ) eq 'HASH' && keys( $data->{$key}->%* ) ) {

      # for more than 1 level of keys
      $~      = "REPORT";
      @fields = ( $key, '' );
      write;

      $~ = "REPORT_SUB";
      foreach ( sort keys $data->{$key}->%* ) {
        @fields = ( $_, $data->{$key}{$_} );
        write;
      }
    } else {

      # standard
      if ( ref( $data->{$key} ) eq 'ARRAY' ) {
        $value = join( "\r", sort( $data->{$key}->@* ) );
      } elsif ( $data->{$key} ) {
        $value = $data->{$key};
      } else {
        $value = '-';
      }
      $~      = "REPORT";
      @fields = ( $key, $value );
      write;
    } ## end else [ if ( ref( $data->{$key...}))]
  } ## end foreach my $key ( sort keys...)

  $group = "internet";
  if ( exists $modules->{$group} ) {
    $errorCount += 1 if $modules->{$group}->{status} != 0;
    $status = $modules->{$group}->{status};
    $msg    = $modules->{$group}->{message};
    $data   = $modules->{$group}->{report};
    $~      = "REPORT_GROUP";
    write;
    $~ = "REPORT";

    foreach my $key ( sort keys %{$data} ) {
      @fields = ( $key, $data->{$key} // '-' );
      write;
    }
  } ## end if ( exists $modules->...)

  $group = "ntp";
  $errorCount += 1 if $modules->{$group}->{status} != 0;
  $status = $modules->{$group}->{status};
  $msg    = $modules->{$group}->{message};
  $data   = $modules->{$group}->{report};
  $~      = "REPORT_GROUP";
  write;
  $~ = "REPORT";

  foreach my $key ( sort keys %{$data} ) {
    @fields = ( $key, $data->{$key} // '-' );
    write;
  }

  $group = "database";
  $errorCount += 1 if $modules->{$group}->{status} != 0;
  $status = $modules->{$group}->{status};
  $msg    = $modules->{$group}->{message};
  $data   = $modules->{$group}->{report};
  $~      = "REPORT_GROUP";
  write;
  $~ = "REPORT_DATABASE";

  foreach my $key ( sort keys %{$data} ) {
    @fields = ( $key, $data->{$key} // '-' );
    write;
  }

  $group = "epg";
  $errorCount += 1 if $modules->{$group}->{status} != 0;
  $status = $modules->{$group}->{status};
  $msg    = $modules->{$group}->{message};
  $data   = $modules->{$group}->{report};

  my @statusMapping = ( 'O.K.', 'WARNING', 'CRITICAL' );
  $~ = "REPORT_GROUP";
  write;
  if ( scalar @$data ) {
    $~ = "REPORT_EPG_HEADER";
    write;

    $~ = "REPORT_EPG";
    foreach my $channel ( sort { $a->{id} <=> $b->{id} } @$data ) {
      my $t = localtime( $channel->{update} );
      @fields =
          ( $channel->{id}, $channel->{name}, $statusMapping[ $channel->{status} ], $t->strftime() );
      write;
    } ## end foreach my $channel ( sort ...)
  } ## end if ( scalar @$data )

  $group = "playout";
  $errorCount += 1 if $modules->{$group}->{status} != 0;
  $status = $modules->{$group}->{status};
  $msg    = $modules->{$group}->{message};
  $data   = $modules->{$group}->{report};
  $~      = "REPORT_GROUP";
  write;
  $~ = "REPORT";

  foreach my $key ( sort keys %{$data} ) {
    next if $key eq 'streams';
    my $d = $data->{$key};

    if ( $key eq 'bitrate' ) {
      @fields = ( $key, $d . ' bps (effective)' );
    } elsif ( $key eq 'start' ) {
      @fields = ( $key, localtime($d)->strftime() );
    } elsif ( $key eq 'runtime' ) {
      @fields = ( $key, $d . ' s' );
    } elsif ( $key eq 'timing' ) {
      @fields = ( $key, $d->{slipCount} . '/' . $d->{minSleep} . '/' . $d->{overshootProtection} );
    } else {
      @fields = ( $key, $d // '-' );
    }
    write;
  } ## end foreach my $key ( sort keys...)

  if ( ref $data->{streams} eq 'ARRAY' && $data->{streams}->@* ) {
    $~ = "REPORT_CAROUSEL_HEADER";
    write;

    $~ = "REPORT_CAROUSEL";
    foreach my $stream ( sort { $a->{addr} cmp $b->{addr} } $data->{streams}->@* ) {

      @fields = (
        $stream->{addr}, $stream->{port}, $stream->{bitrate},
        scalar $stream->{files}->@*,
        localtime( $stream->{last} )->strftime()
      );
      write;
    } ## end foreach my $stream ( sort {...})
  } ## end if ( ref $data->{streams...})

  if ( exists $modules->{announcer} ) {
    $group = "announcer";
    $errorCount += 1 if $modules->{$group}->{status} != 0;
    $status = $modules->{$group}->{status};
    $msg    = $modules->{$group}->{message};
    $data   = $modules->{$group}->{report};
    $~      = "REPORT_GROUP";
    write;
    $~ = "REPORT";

    foreach my $key ( sort keys %{$data} ) {
      if ( $key eq 'last' ) {
        my $start = localtime( $data->{$key} );
        @fields = ( $key, $start->strftime() );
      } else {
        @fields = ( $key, $data->{$key} // '-' );
      }
      write;
    } ## end foreach my $key ( sort keys...)
  } ## end if ( exists $modules->...)

  $~ = "REPORT_BOTTOM";
  if ( $errorCount == 1 ) {
    $msg = "1 error found";
  } elsif ( $errorCount > 1 ) {
    $msg = sprintf( "%i errors found", $errorCount );
  } else {
    $msg = "O.K.";
  }
  write;

  select(STDOUT);

  return $output;
} ## end sub format

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
