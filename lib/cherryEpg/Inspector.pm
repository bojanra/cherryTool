package cherryEpg::Inspector;

use 5.024;
use utf8;
use Carp;
use Digest::CRC qw(crc);
use List::Util  qw(min max);
use Moo;
use POSIX qw(ceil);
use Readonly;
use Sys::Hostname;
use Time::Piece;
use Try::Tiny;

our $VERSION = '1.24';

has 'pid' => (
  is      => 'rw',
  default => 18,
);

has 'timeFrame' => (
  is      => 'rw',
  default => 29,     # default length of chunk is 30s
);

has 'parsingLimit' => (
  is      => 'rw',
  default => undef
);

has 'report' => ( is => 'lazy', );

has 'verbose' => (
  is      => 'rw',
  default => 0,
);

#  $self->{packetCount}
#       ->{packetFailed}
#       ->{byPid}->{$pid}->{packetCount}
#                        ->{stackCount}
#                        ->{sectionCount}
#                        ->{invalidCount}
#                        ->{crcErrorCount}
#                        ->{chunk}
#                        ->{service}->{$tsid}->{$onid}->{$sid}->{pfa}
#                                                             ->{pfo}
#                                                             ->{scha}
#                                                             ->{scho}
#                                                             ->{unknown}
#                                                             ->{table}->{$table_id}->{first}
#                                                                                   ->{last}
#                                                                                   ->{count}
#                                                                                   ->{max}
#                                                                                   ->{maxPF}
#                                                                                   ->{maxFirstDay}
#                                                                                   ->{maxOtherDay}
#                                                                                   ->{min}
#       ->{repetition}->{max}
#                                                                                                   {min}
#                                                                                   ->{section}->{0}
#                                                                                                {1}
#                        ->{seq}->[list] each has
#                                       ->{valid}
#                                       ->{crcOk}
#                                       ->{table_id}
#                                       ->{section_length}
#                                       ->{sid}
#                                       ->{section_number}
#                                       ->{tsid}
#                                       ->{onid}
#                                       ->{start}
#                                       ->{valid}
#
#

sub _build_report {
  my ($self) = @_;

  $self->inspect();
  return $self->reportBuild();
} ## end sub _build_report

=head3 load ( $file )

Read the $file and build structure.

=cut

sub load {
  my ( $self, $file ) = @_;

  $self->{packetCount}  = 0;
  $self->{packetFailed} = 0;
  $self->{byPid}        = {};       # storage for assembled packets organized by pid
  $self->{errorList}    = [];       # list of errors found during parsing
  $self->{currentPid}   = undef;    # info on current packetParse in process

  return unless -e $file;

  $self->{source} = $file;

  my $block;
  open( my $chunk, '<:raw', $file ) || return;
  while ( read( $chunk, $block, 188 ) ) {
    $self->packetParse($block);

    # stop if parsingLimit reached
    if ( $self->parsingLimit && $self->{packetCount} >= $self->parsingLimit ) {
      last;
    }
  } ## end while ( read( $chunk, $block...))

  close($chunk);
  return $self->{packetCount};
} ## end sub load

=head3 packetParse ( $packet)

Parse single $packet and run table parser for every found section.
Isolate incorrect packets.

=cut

sub packetParse {
  my ( $self, $packet ) = @_;

  $self->{packetCount} += 1;

  my ( $sync_byte, $pid, $continuity_counter, $payload ) = unpack( "CnCa*", $packet );
  my $transport_error_indicator    = $pid >> 15;
  my $payload_unit_start_indicator = ( $pid >> 14 ) & 0x01;
  my $transport_priority           = ( $pid >> 13 ) & 0x01;
  $pid &= 0x1fff;
  $self->{currentPid} = $pid;

  $self->{byPid}{$pid} = {} unless exists $self->{byPid}{$pid};
  my $pidData = $self->{byPid}{$pid};

  $pidData->{packetCount} += 1;

  # stuffing
  if ( $pid == 0x1fff ) {
    if ( $continuity_counter == 0x10 && $payload =~ /^ringelspiel (\{.+\})/ ) {
      my $decoded = try {
        JSON::XS->new->utf8->decode($1);
      };
      if ($decoded) {
        $self->{timeFrame} = $decoded->{interval} / 1000;
        $self->{target}    = $decoded->{dst};
        $self->{title}     = $decoded->{title};
        my @flag;
        push( @flag, 'PCR' ) if $decoded->{pcr};
        push( @flag, 'TDT' ) if $decoded->{tdt};
        $self->{flags} = join( ' ', @flag );
      } ## end if ($decoded)
    } ## end if ( $continuity_counter...)
    return;
  } ## end if ( $pid == 0x1fff )

  # save start position of NEW chunk
  if ( !$pidData->{stackCount} ) {
    $pidData->{start} = $self->{packetCount};
  }

  my $transport_scrambling_control = ( $continuity_counter >> 6 ) & 0x03;
  my $adaptation_field_control     = ( $continuity_counter >> 4 ) & 0x03;
  $continuity_counter &= 0x0f;

  my $valid;
  if ( $transport_error_indicator != 0 ) {
    $self->failedAdd("transport_error_indicator");
  } elsif ( $adaptation_field_control != 1 ) {
    $self->failedAdd("adaptation_field_control");
  } elsif ( $payload_unit_start_indicator == 1 ) {
    my $pointer_field = substr( $payload, 0, 1, '' );
    if ( $pointer_field ne "\x00" ) {
      $self->failedAdd("pointer_field");
    } elsif ( $pidData->{stackCount} ) {
      $self->failedAdd("head_zombie");
    } else {
      $valid = 1;
    }
  } else {

    # seems to be first packet in section
    if ( !$pidData->{stackCount} ) {
      $self->failedAdd("tail_zombie");
    } else {
      $valid = 1;
    }
  } ## end else [ if ( $transport_error_indicator...)]

  # stop processing if not valid
  if ( !$valid ) {
    delete $pidData->{stackCount};
    delete $pidData->{chunk};
    return;
  }

  $pidData->{chunk} .= $payload;
  $pidData->{stackCount} += 1;    # count of packets in section

  # get section length
  my ( $table_id, $section_length, undef ) = unpack( "Cna*", $pidData->{chunk} );
  my $section_syntax_indicator = ( $section_length >> 15 );
  $section_length &= 0x0fff;

  # when section complete -> save it
  if ( length( $pidData->{chunk} ) >= ( $section_length + 3 ) ) {
    my $section   = substr( $pidData->{chunk}, 0, $section_length + 3 );
    my $crc       = crc( $section, 32, 0xffffffff, 0x00000000, 0, 0x04C11DB7, 0, 0 );
    my $structure = $self->sectionGet( \$section, $crc == 0, $pidData->{start} );

    push( $pidData->{seq}->@*, $structure ) if $structure;

    # prepare for next section
    $pidData->{chunk}      = "";
    $pidData->{stackCount} = 0;
  } ## end if ( length( $pidData->...))
} ## end sub packetParse

=head3 failedAdd ( $msg)

Log failed packetParse block.

=cut

sub failedAdd {
  my ( $self, $msg ) = @_;

  my $pid = $self->{currentPid};

  my $stack = ( $self->{byPid}{$pid}{stackCount} // 0 );
  $self->{packetFailed} += $stack + 1;
  push( $self->{errorList}->@*, sprintf( "[%4i] %s at packet no %i", $pid, $msg, $self->{packetCount} ) );
} ## end sub failedAdd

=head3 sectionGet ( $raw, $isCRC, $start)

Save section (group of packets) for later statistics.

=cut

sub sectionGet {
  my ( $self, $raw, $isCRC, $start ) = @_;
  my $pid     = $self->{currentPid};
  my $pidData = $self->{byPid}{$pid};
  my $section = {
    valid      => 0,
    stackCount => $pidData->{stackCount},
    start      => $start,
  };

  if ( length($$raw) > 11 ) {
    my $table_id = unpack( "C", substr( $$raw, 0, 1, '' ) );
    $section->{table_id} = $table_id;

    # this only for EIT actual, p/f actual/other)
    if ( $table_id >= 0x4e && $table_id < 0x70 ) {
      $section->{crcOk} = $isCRC;
      my $data;

      (
        $section->{section_length},
        $section->{sid}, undef, $section->{section_number},
        undef, $section->{tsid}, $section->{onid}, $data
      )
          = unpack( "nnCCCnna*", $$raw );
      $section->{section_length} &= 0x0fff;
      $section->{valid} = ( $section->{section_length} - length($data) ) == 9 ? 1 : 0;
      return $section;
    } ## end if ( $table_id >= 0x4e...)
  } ## end if ( length($$raw) > 11)
  return;
} ## end sub sectionGet

=head3 distanceMinMax ( $serviceData, $section)

Calculate min. distance between sections for table_id 0x4e and
max. distance between sections of same number.

=cut

sub distanceMinMax {
  my ( $self, $serviceData, $section ) = @_;

  # min. distance for table/subtable
  if ( !exists( $serviceData->{table}{ $section->{table_id} } ) ) {

    # start with some default
    $serviceData->{table}{ $section->{table_id} } = {
      first => $section->{start},
      min   => undef,
      count => 1,
    };
  } else {
    my $g   = $serviceData->{table}{ $section->{table_id} };
    my $gap = $section->{start} - $g->{last};

    $g->{min} = min( $gap, $g->{min} // $gap );
    $g->{count} += 1;
  } ## end else [ if ( !exists( $serviceData...))]
  $serviceData->{table}{ $section->{table_id} }{last} = $section->{start} + $section->{stackCount};

  # max. distance between same section number
  if ( !exists $serviceData->{table}{ $section->{table_id} }{section}[ $section->{section_number} ] ) {
    $serviceData->{table}{ $section->{table_id} }{section}[ $section->{section_number} ] = {
      first => $section->{start},
      max   => undef,
      count => 1,
    };
  } else {
    my $g   = $serviceData->{table}{ $section->{table_id} }{section}[ $section->{section_number} ];
    my $gap = $section->{start} - $g->{last};
    if ( $section->{sid} == 117 && $section->{table_id} == 0x50 && $section->{section_number} <= 64 ) {

      #  printf( "[%i] %.1f +\n",$section->{section_number}, $gap/$self->{packetCount} * $self->timeFrame);
    }

    $g->{max} = max( $gap, $g->{max} // $gap );
    $g->{count} += 1;
  } ## end else [ if ( !exists $serviceData...)]

  $serviceData->{table}{ $section->{table_id} }{section}[ $section->{section_number} ]{last} =
      $section->{start} + $section->{stackCount};
} ## end sub distanceMinMax

=head3 inspect ( )

Analyze stored sections and generate report structure by Pid.

=cut

sub inspect {
  my ($self) = @_;

  # analyze packets for each PID
  foreach my $pid ( keys $self->{byPid}->%* ) {

    my $pidData = $self->{byPid}{$pid};

    if ( not $pidData->{seq} ) {
      delete $pidData->{chunk};
      next;
    }

    $pidData->{sectionCount}  = 0;
    $pidData->{packetCount}   = 0;
    $pidData->{invalidCount}  = 0;
    $pidData->{crcErrorCount} = 0;

    my $nextMappedServiceId = 0;

    # iterate over all found sections
    foreach my $section ( $pidData->{seq}->@* ) {

      $pidData->{sectionCount} += 1;
      $pidData->{packetCount}  += $section->{stackCount};    # count packets with same PID

      if ( $section->{valid} ) {
        if ( $section->{crcOk} ) {
          if ( !exists $pidData->{service}{ $section->{tsid} }{ $section->{onid} }{ $section->{sid} } ) {
            $pidData->{service}{ $section->{tsid} }{ $section->{onid} }{ $section->{sid} } = {
              pfa     => undef,
              pfo     => undef,
              scha    => undef,
              scho    => undef,
              unknown => undef,
            };
          } ## end if ( !exists $pidData->...)

          my $serviceData = $pidData->{service}{ $section->{tsid} }{ $section->{onid} }{ $section->{sid} };
          $self->distanceMinMax( $serviceData, $section );

          # count sections pre table type
          if    ( $section->{table_id} == 0x4e ) { $serviceData->{pfa} += 1; }
          elsif ( $section->{table_id} == 0x4f ) { $serviceData->{pfo} += 1; }
          elsif ( $section->{table_id} >= 0x50 && $section->{table_id} <= 0x5f ) {
            $serviceData->{scha} += 1;
          } elsif ( $section->{table_id} >= 0x60 && $section->{table_id} < 0x6f ) {
            $serviceData->{scho} += 1;
          } else {
            $serviceData->{unknown} += 1;
          }
        } else {
          $pidData->{crcErrorCount} += 1;
        }
      } else {
        $pidData->{invalidCount} += 1;
      }
    } ## end foreach my $section ( $pidData...)
    delete $self->{byPid}{$pid}{seq};
    delete $self->{byPid}{$pid}{start};
  } ## end foreach my $pid ( keys $self...)

  # finalize data
  foreach my $pid ( sort keys $self->{byPid}->%* ) {

    my $pidData = $self->{byPid}{$pid};
    next if not exists $pidData->{service};

    foreach my $tsid ( keys $pidData->{service}->%* ) {
      foreach my $onid ( keys $pidData->{service}{$tsid}->%* ) {
        foreach my $sid ( keys $pidData->{service}{$tsid}{$onid}->%* ) {
          foreach my $table_id ( keys $pidData->{service}{$tsid}{$onid}{$sid}{table}->%* ) {

            # get min. distance for table
            my $t = $pidData->{service}{$tsid}{$onid}{$sid}{table}{$table_id};
            $t->{min} = min( $t->{min} // $self->{packetCount}, $self->{packetCount} - $t->{last} + $t->{first} );

            # include interchunk timing for max. distance per section
            if ( $sid == 117 ) {

              #              say "[$table_id]";
              #              p $pidData->{service}{$tsid}{$onid}{$sid}{table}{$table_id}
            }
            while ( my ( $id, $s ) = each $t->{section}->@* ) {

              next unless $s->{first};
              $s->{max} = max( $s->{max} // 0, $self->{packetCount} - $s->{last} + $s->{first} );

              # printf( "%3i | %4i - %4i + %4i = %4i\n", $id, $self->{packetCount}, $s->{last}, $s->{first}, $s->{max} );

              if ( $table_id == 0x4e || $table_id == 0x4f ) {

                # calculate for pfa
                $t->{maxPF} = max( $t->{maxPF} // 0, $s->{max} );
              } elsif ( $table_id == 0x50 && $id <= 64 ) {

                # for first day
                # printf( "[%i] %.1f\n",$id,$s->{max}/$self->{packetCount} * $self->timeFrame) if $sid == 117;
                $t->{maxFirstDay} = max( $t->{maxFirstDay} // 0, $s->{max} );
              } else {

                # printf( "[%i] %.1f\n",$id,$s->{max}/$self->{packetCount} * $self->timeFrame) if $sid == 121;
                # and all other
                $t->{maxOtherDay} = max( $t->{maxOtherDay} // 0, $s->{max} );
              } ## end else [ if ( $table_id == 0x4e...)]

            } ## end while ( my ( $id, $s ) = ...)

            delete $t->{section};

            # prepare reporting data

            my @report;

            # min
            push( @report, ceil( $t->{min} / $self->{packetCount} * $self->timeFrame * 1000 ) );

            if ( $table_id == 0x4e && exists( $t->{maxPF} ) ) {
              push( @report, sprintf( "%.1f", $t->{maxPF} / $self->{packetCount} * $self->timeFrame ) );
            } else {
              push( @report, undef );
            }

            if ( $table_id == 0x50 && exists( $t->{maxFirstDay} ) ) {
              push( @report, sprintf( "%.1f", $t->{maxFirstDay} / $self->{packetCount} * $self->timeFrame ) );
            } else {
              push( @report, undef );
            }

            if ( $table_id > 0x50 && $table_id < 0x60 && exists( $t->{maxOtherDay} ) ) {
              push( @report, sprintf( "%.1f", $t->{maxOtherDay} / $self->{packetCount} * $self->timeFrame ) );
            } else {
              push( @report, undef );
            }

            if ( $table_id == 0x4f && exists( $t->{maxPF} ) ) {
              push( @report, sprintf( "%.1f", $t->{maxPF} / $self->{packetCount} * $self->timeFrame ) );
            } else {
              push( @report, undef );
            }

            if ( $table_id >= 0x60 && exists( $t->{maxOtherDay} ) ) {
              push( @report, sprintf( "%.1f", $t->{maxOtherDay} / $self->{packetCount} * $self->timeFrame ) );
            } else {
              push( @report, undef );
            }

            $t->{report} = \@report;
          } ## end foreach my $table_id ( keys...)
        } ## end foreach my $sid ( keys $pidData...)
      } ## end foreach my $onid ( keys $pidData...)
    } ## end foreach my $tsid ( keys $pidData...)
  } ## end foreach my $pid ( sort keys...)

  return $self->{byPid};
} ## end sub inspect

=head3 errorReport( )

Generate error report from list.

=cut

sub errorReport {
  my ($self) = @_;

  my $output = "";

  $output = join( "\n", $self->{errorList}->@*, "" );
  return $output;
} ## end sub errorReport

=head3 reportBuild( )

Return text formated report of the inspected file content.

=cut

sub reportBuild {
  my ($self) = @_;

  my $output = "";
  my ( @list, $pid, $pidData, $serviceCount );

  sub preformat {
    my ($table) = shift;
    my $aI = '!';
    my @list;

    if ( $table->{report}[0] ) {
      my $gap = $table->{report}[0];
      push( @list, $gap . ( $gap >= 25 ? ' ' : $aI ) );
    } else {
      push( @list, '-  ' );
    }

    if ( $table->{report}[1] ) {
      my $max = $table->{report}[1];
      push( @list, sprintf( "%.1f%s", $max, $max <= 2 ? ' ' : $aI ) );
    } else {
      push( @list, '-  ' );
    }

    if ( $table->{report}[2] ) {
      my $max = $table->{report}[2];
      push( @list, sprintf( "%.1f%s", $max, $max <= 10 ? ' ' : $aI ) );
    } else {
      push( @list, '-  ' );
    }

    if ( $table->{report}[3] ) {
      my $max = $table->{report}[3];
      push( @list, sprintf( "%.1f%s", $max, $max <= 30 ? ' ' : $aI ) );
    } else {
      push( @list, '-  ' );
    }

    if ( $table->{report}[4] ) {
      my $max = $table->{report}[4];
      push( @list, sprintf( "%.1f%s", $max, $max <= 2 ? ' ' : $aI ) );
    } else {
      push( @list, '-  ' );
    }

    if ( $table->{report}[5] ) {
      my $max = $table->{report}[5];
      push( @list, sprintf( "%.1f%s", $max, $max <= 30 ? ' ' : $aI ) );
    } else {
      push( @list, '-  ' );
    }
    return @list;
  } ## end sub preformat

  # number of packets between same table and service to achieve 25ms requirement
  my $requiredGap = ceil( $self->{packetCount} * 25 / 1000 / $self->timeFrame );

  format HEAD =
-- cherryEPG Inspector - Copyright 2024 Bojan Ramsak ----------------------------------------
Source: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   Date: @>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
$self->{source}, localtime->strftime()
Target: @<<<<<<<<<<<<<<<<<<<<<  Title: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<  Flags: @<<<<<<<<<
$self->{target} // 'undefined', $self->{title} // '-', $self->{flags} // '-'
Sections total: @>>>>>>>   Timeframe: @>>>>s     Min. required actual p/f section gap is 25ms
$pidData->{sectionCount}, $self->timeFrame
     not valid: @>>>>>>>   Packets: @>>>>>
$pidData->{invalidCount}, $pidData->{packetCount},
     CRC error: @>>>>>>>   Bitrate: @>>>>>>> kb/s                                  PID: @>>>>
$pidData->{crcErrorCount},  sprintf( "%.1f", $pidData->{packetCount}*188*8/($self->timeFrame*1000)), $pid
                                       [ms]    |  actual max. rep [s]    | other max. rep [s]
   onid   tsid   sid  table sections min. gap  |  p/f     today    next  |   p/f       sch
---------------------------------------------------------------------------------------------
.

  format TABLE =
  @>>>>  @>>>>  @>>>>  @>>   @>>>    @>>>>>>    @>>>>>>  @>>>>>>  @>>>>>>  @>>>>>>  @>>>>>>
@list
.

  format FOOT =
=============================================================================================
            Summary:  @>>>>>        @>>>>>>    @>>>>>>  @>>>>>>  @>>>>>>  @>>>>>>  @>>>>>>
@list
.

  my $foundPID = {};

  open( RPRT, '>:utf8', \$output ) or return;

  select(RPRT);
  $-  = 0;
  $%  = 0;
  $=  = 100000;    # never paginate
  $^L = '';

  # iterate over PID
  foreach $pid ( sort keys $self->{byPid}->%* ) {

    $pidData      = $self->{byPid}{$pid};
    $serviceCount = 0;

    if ( !exists $pidData->{service} ) {
      $foundPID->{$pid} = $pidData->{packetCount};
      next;
    }

    $~ = "HEAD";
    write;

    $~ = "TABLE";

    my @summary;

    # iterate over tsid
    foreach my $tsid ( sort { $a <=> $b } keys $pidData->{service}->%* ) {

      # iterate over onid
      foreach my $onid ( sort keys $pidData->{service}{$tsid}->%* ) {

        #iterate over sid
        foreach my $sid ( sort { $a <=> $b } keys $pidData->{service}{$tsid}{$onid}->%* ) {

          $serviceCount += 1;
          my $serviceData = $pidData->{service}{$tsid}{$onid}{$sid};

          @list = ( sprintf( "%04xh", $onid ), $tsid, $sid, );

          # report for each found table but write tsid,onid, sid only in first row
          foreach my $table_id ( sort { $a <=> $b } keys $serviceData->{table}->%* ) {

            my $t = $serviceData->{table}{$table_id};
            push( @list, sprintf( "%2xh", $table_id ) );
            push( @list, $t->{count} );
            push( @list, preformat($t) );

            # calculate summary
            if ( $t->{report}[0] ) {
              $summary[0] = min( $summary[0] // $t->{report}[0], $t->{report}[0] );
            }
            foreach my $i ( 1 .. 5 ) {
              $summary[$i] = max( $summary[$i] // 0, $t->{report}[$i] ) if $t->{report}[$i];
            }

            write;

            # set first 3 elements of list to undef
            @list    = ();
            $list[2] = undef;
            @list    = map {''} @list;
          } ## end foreach my $table_id ( sort...)
        } ## end foreach my $sid ( sort { $a...})
      } ## end foreach my $onid ( sort keys...)
    } ## end foreach my $tsid ( sort { $a...})

    foreach my $i ( 0 .. 5 ) {
      $summary[$i] = '- ' unless $summary[$i];
    }

    @list = ( $serviceCount, @summary );

    $~ = "FOOT";
    write;
  } ## end foreach $pid ( sort keys $self...)

  if ( $foundPID->%* ) {
    say( '=' x 93 );
    say( "Other detected PID: ", join( ',', sort keys $foundPID->%* ) );
    say( "     Total packets: ", $self->{packetCount} );
    say( "           Bitrate: ", sprintf( "%.4f Mbps", $self->{packetCount} * 188 * 8 / $self->timeFrame / 1E6 ) );
  } ## end if ( $foundPID->%* )
  select(STDOUT);

  return $output;
} ## end sub reportBuild

=head1 AUTHOR

This software is copyright (c) 2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
