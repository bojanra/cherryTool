package cherryEpg::Taster;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Net::Curl::Easy qw(:constants );
use Net::NTP qw(get_ntp_response);
use JSON::XS;
use Time::Piece;
use Sys::Hostname;
use Readonly;

our $VERSION = '1.16';

# status code used in NAGIOS/NAEMON
Readonly my $OK       => 0;
Readonly my $WARNING  => 1;
Readonly my $CRITICAL => 2;
Readonly my $UNKNOWN  => 3;

with('MooX::Singleton');

has 'cherry' => ( is => 'lazy', );

sub BUILD {
    my ( $self, $arg ) = @_;

    # read configuration
    foreach my $key ( keys %{ $self->cherry->{config}{cherryepg}{taster} } ) {
        $self->{$key} = $self->cherry->{config}{cherryepg}{taster}{$key};
    }

    # number of days in future to check- default
    $self->{eventbudget}{days} //= 7;

    # this is the interval of days where EIT data must be defined, if not -> warning
    $self->{eventbudget}{threshold}{warning} //= 3;

    # this is the interval of days where EIT data must be defined, if not -> critical
    # 1 - today
    # 2 - today and tomorrow
    $self->{eventbudget}{threshold}{critical} //= 2;

} ## end sub BUILD

sub _build_cherry {
    my ($self) = @_;

    return cherryEpg->instance();
}

=head3 eventBudget ( )

Report the eventbudget for all channels for n days in future(pos) or past (neg) days

=cut

sub eventBudget {
    my ( $self, $days ) = @_;
    $days = $days // $self->{eventbudget}{days};
    my @report;

    my $lastUpdate = $self->cherry->epg->listChannelLastUpdate();
    return unless $lastUpdate;
    my $eBudget = $self->getMultiInterval($days);

    # change from hash to array sorted by progname
    foreach my $channel_id ( sort { $eBudget->{$a}{name} cmp $eBudget->{$b}{name} } keys %$eBudget ) {

        my $name  = $eBudget->{$channel_id}{name};
        my $count = $eBudget->{$channel_id}{count};

        my $status = $OK;
        my $day    = 0;
        while ( $status < $CRITICAL and $day <= $#$count ) {
            if ( $day < $self->{eventbudget}{threshold}{critical} and $$count[$day] == 0 ) {
                $status = $CRITICAL;
            } elsif ( $day < $self->{eventbudget}{threshold}{warning} and $$count[$day] == 0 ) {
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

    # TODO
    if ( $days >= 0 ) {

        # count events per service for today next $self->{days} and remaining days
        for ( my $dayCount = 0 ; $dayCount <= $days ; $dayCount++ ) {
            my $serviceList;
            if ( $dayCount == $days ) {

                # get number of all remaining events in database
                $serviceList = $self->cherry->epg->listChannelEventCount( $dayCount, 65535 );
            } else {
                $serviceList = $self->cherry->epg->listChannelEventCount( $dayCount, $dayCount + 1 );
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
                    push( @{ $result->{$id}{count} }, $count );
                }
            } ## end else [ if ( $dayCount == 0 ) ]
        } ## end for ( my $dayCount = 0 ...)
        return $result;

    } else {

        # count events per service for previous days but not today
        for ( my $dayCount = $days ; $dayCount < 0 ; $dayCount++ ) {
            my $serviceList = $self->cherry->epg->listChannelEventCount( $dayCount, $dayCount + 1 );

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
                    push( @{ $result->{$id}{count} }, -$count );
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
    $curl->setopt( CURLOPT_URL,            $url );
    $curl->setopt( CURLOPT_FOLLOWLOCATION, 1 );
    $curl->setopt( CURLOPT_MAXREDIRS,      5 );
    $curl->setopt( CURLOPT_SSL_VERIFYPEER, 0 );
    $curl->setopt( CURLOPT_WRITEDATA,      \$response_body );

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
        $decoded->{status}    = $OK;
        if ( exists $decoded->{target} ) {
            $decoded->{target} = $decoded->{version} .= " " . $decoded->{target};
            delete $decoded->{target};
        }

        foreach my $stream ( @{ $decoded->{streams} } ) {
            my $last = 0;
            foreach my $file ( @{ $stream->{files} } ) {
                $last = $file->{last} if $file->{last} > $last;
                my $t = localtime( $file->{last} );
                $file->{last} = $t->datetime;
            }
            my $t = localtime($last);
            $stream->{last} = $t->datetime;
        } ## end foreach my $stream ( @{ $decoded...})
    } else {
        my $t = localtime;
        $decoded = {
            error     => "Ringelspiel not running",
            status    => $CRITICAL,
            timestamp => $t->strftime()

        };
    } ## end else [ if ($success) ]

    # the timing key subtree is not processed just forwarded

    return $decoded;
} ## end sub ringelspiel

=head3 version ( )

Report installed version numbers

=cut

sub version {
    my ($self) = @_;

    my $report = {
        cherryEpg    => $cherryEpg::VERSION,
        cherryTaster => $cherryEpg::Taster::VERSION,
        cherryWeb    => $cherryWeb::VERSION,
        ringelspiel  => $self->ringelspiel->{version}
    };

    return $report;
} ## end sub version

=head3 databaseSummary ( )

Get mysql database summary status

=cut

sub databaseSummary {
    my ($self) = @_;

    my $healthCheck = $self->cherry->epg->healthCheck;

    if ($healthCheck) {
        my @list;
        my $status = $OK;

        my $report = {};

        foreach my $t (@$healthCheck) {
            my @fields = @$t;
            $report->{ $fields[0] } = $fields[2];
        }

        return {
            status => $OK,
            msg    => "Running " . $self->cherry->epg->version,
            report => $report,
        };
    } else {
        return {
            status => $CRITICAL,
            msg    => "No connection",
            report => {},
        };
    } ## end else [ if ($healthCheck) ]
} ## end sub databaseSummary

=head3 ringelspielSummary ( )

Report ringelspiel summary information.

=cut

sub ringelspielSummary {
    my ($self) = @_;

    my $ringelspiel = $self->ringelspiel;

    if ( $ringelspiel->{version} ) {
        my @list;
        my $streamCount = 0;
        my $bitrate     = 0;

        foreach my $s ( @{ $ringelspiel->{streams} } ) {
            $streamCount += 1;
            $bitrate     += $s->{bitrate};
        }

        # 2000-02-29T12:34:56
        my $start = Time::Piece->strptime( $ringelspiel->{start}, "%Y-%m-%dT%H:%M:%S" );

        my $report = {
            streams   => $streamCount,
            bitrate   => $bitrate,
            start     => $start->epoch(),
            timing    => $ringelspiel->{timing}{minSleep} . '/' . $ringelspiel->{timing}{slipCount} . ' min/slip',
            overshoot => $ringelspiel->{timing}{overshootProtection},
            exceed    => $ringelspiel->{exceed}
        };

        return {
            status => $OK,
            msg    => "Streaming",
            report => $report,
        };
    } else {
        return {
            status => $CRITICAL,
            msg    => "Not running",
            report => {},
        };
    } ## end else [ if ( $ringelspiel->{version...})]
} ## end sub ringelspielSummary

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

=head3 ntp ( )

Report system ntp status

=cut

sub ntp {
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
                status => $OK,
                msg    => "Reference o.k.",
                report => $report,
            };
        } elsif ( $ntp{'Reference Clock Identifier'} =~ m/STEP|INIT/ ) {
            return {
                status => $WARNING,
                msg    => "Reference - " . $ntp{'Reference Clock Identifier'},
                report => $report,
            };

        } else {
            return {
                status => $WARNING,
                msg    => "Reference not o.k.",
                report => $report,
            };
        } ## end else [ if ( $stratum > 0 ) ]
    } else {
        return {
            status => $CRITICAL,
            msg    => "Not running",
            report => {},
        };
    } ## end else [ if ($success) ]
} ## end sub ntp

=head3 epg ( )

Report Epg builder status.

=cut

sub epg {
    my ($self) = @_;

    my $budget = $self->eventBudget();

    if ( !$budget ) {
        return {
            status => $CRITICAL,
            msg    => "No connection",
            report => [],
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
        report => $budget,
        status => $status,
        msg    => $message[$status]
    };

} ## end sub epg

=head3 announcer ( )

Report Announcer status.

=cut

sub announcer {
    my ($self) = @_;

    my $a = $self->cherry->epg->announcerLoad();

    if ( $a && ( $a->{present}{publish} || $a->{following}{publish} ) ) {
        my $msg = {};
        foreach ( 'present', 'following' ) {
            $msg->{$_} = $a->{$_}{text} if $a->{$_}{publish};
        }

        return {
            status => $OK,
            msg    => "Active",
            report => $msg,
        };

    } ## end if ( $a && ( $a->{present...}))
    else {
        # inactive
        return undef;
    }
} ## end sub announcer

=head3 report ( )

Generate sysinfo overall report hash.

=cut

sub report {
    my ($self) = @_;

    my $timestamp = localtime;

    my $report = {
        timestamp => $timestamp->epoch(),
        version   => $self->version(),
        modules   => {
            ntp      => $self->ntp(),
            playout  => $self->ringelspielSummary(),
            database => $self->databaseSummary(),
            epg      => $self->epg(),
        },
        uptime => $self->uptime(),
    };

    my $announcer = $self->announcer();
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
-- cherryTaster - ver. @<<<<<< Copyright 2014-2019 Bojan Ramsak ---SYSTEM INFO--
$cherryEpg::Taster::VERSION
Hostname: @<<<<<<<<<<<<<<<<<<   Date : @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
          hostname,           $reportTime
Uptime  : @<<<<<<<<<<<<<<<<<<   Since: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
          $uptime,                      $systemStart
.

    my $field;
    my $value;
    my $group;
    my $status;
    my $msg;
    my $errorCount = 0;
    my $data;
    my ( $channel_id, $channel_name, $channel_status, $channel_last );

    format REPORT_GROUP =
--------------------------------------------------------------------------------
@<< @<<<<<<<<<<<<: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
($status != 0 ? '!!!' : ''), $group, $msg
.

    format REPORT =
    - @<<<<<<<<<<: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$field, $value
.

    format REPORT_DATABASE =
    - @<<<<<<<<<<: @>>>>>>> rows
$field, $value
.

    format REPORT_BOTTOM =
================================================================================
  @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
  $msg
.

    format REPORT_EPG =
     @>>   @<<<<<<<<<<<<<<<  @<<<<<<<  @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$channel_id, $channel_name, $channel_status, $channel_last
.

    format REPORT_EPG_HEADER =
    - id - channel_name ---- status -- last_update ----------------------------
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
        ( $field, $value ) = ( $key, $data->{$key} // '-' );
        write;
    }

    $group = "ntp";
    $errorCount += 1 if $modules->{$group}->{status} != 0;
    $status = $modules->{$group}->{status};
    $msg    = $modules->{$group}->{msg};
    $data   = $modules->{$group}->{report};
    $~      = "REPORT_GROUP";
    write;
    $~ = "REPORT";

    foreach my $key ( sort keys %{$data} ) {
        ( $field, $value ) = ( $key, $data->{$key} // '-' );
        write;
    }

    $group = "database";
    $errorCount += 1 if $modules->{$group}->{status} != 0;
    $status = $modules->{$group}->{status};
    $msg    = $modules->{$group}->{msg};
    $data   = $modules->{$group}->{report};
    $~      = "REPORT_GROUP";
    write;
    $~ = "REPORT_DATABASE";

    foreach my $key ( sort keys %{$data} ) {
        ( $field, $value ) = ( $key, $data->{$key} // '-' );
        write;
    }

    $group = "epg";
    $errorCount += 1 if $modules->{$group}->{status} != 0;
    $status = $modules->{$group}->{status};
    $msg    = $modules->{$group}->{msg};
    $data   = $modules->{$group}->{report};

#    use Data::Dumper;
#    print Dumper $modules;
    my @statusMapping = ( 'O.K.', 'WARNING', 'CRITICAL' );
    $~ = "REPORT_GROUP";
    write;
    if ( scalar @$data ) {
        $~ = "REPORT_EPG_HEADER";
        write;

        $~ = "REPORT_EPG";
        foreach my $channel ( sort { $a->{id} <=> $b->{id} } @$data ) {
            my $t = Time::Piece->localtime( $channel->{update} );
            ( $channel_id, $channel_name, $channel_status, $channel_last ) =
                ( $channel->{id}, $channel->{name}, $statusMapping[ $channel->{status} ], $t->strftime() );
            write;
        } ## end foreach my $channel ( sort ...)
    } ## end if ( scalar @$data )

    $group = "playout";
    $errorCount += 1 if $modules->{$group}->{status} != 0;
    $status = $modules->{$group}->{status};
    $msg    = $modules->{$group}->{msg};
    $data   = $modules->{$group}->{report};
    $~      = "REPORT_GROUP";
    write;
    $~ = "REPORT";

    foreach my $key ( sort keys %{$data} ) {

        if ( $key eq 'bitrate' ) {
            ( $field, $value ) = ( $key, $data->{$key} . ' bps' );
        } elsif ( $key eq 'start' ) {
            my $start = Time::Piece->gmtime( $data->{$key} );
            ( $field, $value ) = ( $key, $start->strftime() );
        } else {
            ( $field, $value ) = ( $key, $data->{$key} // '-' );
        }
        write;
    } ## end foreach my $key ( sort keys...)

    if ( exists $modules->{webgrab} ) {
        $group = "webgrab";
        $errorCount += 1 if $modules->{$group}->{status} != 0;
        $status = $modules->{$group}->{status};
        $msg    = $modules->{$group}->{msg};
        $data   = $modules->{$group}->{report};
        $~      = "REPORT_GROUP";
        write;
        $~ = "REPORT";

        foreach my $key ( sort keys %{$data} ) {
            if ( $key eq 'last' ) {
                my $start = Time::Piece->gmtime( $data->{$key} );
                ( $field, $value ) = ( $key, $start->strftime() );
            } else {
                ( $field, $value ) = ( $key, $data->{$key} // '-' );
            }
            write;
        } ## end foreach my $key ( sort keys...)
    } ## end if ( exists $modules->...)

    if ( exists $modules->{announcer} ) {
        $group = "announcer";
        $errorCount += 1 if $modules->{$group}->{status} != 0;
        $status = $modules->{$group}->{status};
        $msg    = $modules->{$group}->{msg};
        $data   = $modules->{$group}->{report};
        $~      = "REPORT_GROUP";
        write;
        $~ = "REPORT";

        foreach my $key ( sort keys %{$data} ) {
            if ( $key eq 'last' ) {
                my $start = Time::Piece->gmtime( $data->{$key} );
                ( $field, $value ) = ( $key, $start->strftime() );
            } else {
                ( $field, $value ) = ( $key, $data->{$key} // '-' );
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

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
