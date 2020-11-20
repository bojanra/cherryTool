package cherryEpg::Inspector;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Carp;
use Time::Piece;
use Sys::Hostname;
use Digest::CRC qw(crc);
use GD;
use POSIX qw(ceil);
use YAML::XS;

use Readonly;

our $VERSION = '0.9';

has 'sourceFile' => (
    is       => 'ro',
    required => 1,
    isa      => sub {
        croak "file not found" unless -e -f $_[0];
    },
);

has 'parsingLimit' => (
    is      => 'ro',
    default => undef
);

has 'report' => ( is => 'lazy', );

sub BUILDARGS {
    my ( $self, $arg ) = @_;

    return { sourceFile => $arg };
}

#  $self->{packetCount}->{all}
#                      ->{failed}
#       ->{byPid}->{$pid}->{packetCount}
#                        ->{sectionCount}
#                        ->{invalidCount}
#                        ->{crcErrorCount}
#                        ->{chunk}
#                        ->{service}->{$tsid}->{$onid}->{$sid}->{pfa}
#                                                             ->{pfo}
#                                                             ->{scha}
#                                                             ->{scho}
#                                                             ->{unknown}
#                                                             ->{gap}->{$table_id}->{first}
#                                                                                 ->{last}
#                                                                                 ->{min}
#                        ->{seq}->[list] each has
#                                       ->{valid}
#                                       ->{crcOk}
#                                       ->{table_id}
#                                       ->{section_length}
#                                       ->{sid}
#                                       ->{current_section}
#                                       ->{tsid}
#                                       ->{onid}
#                                       ->{start}
#                                       ->{valid}
#
#

sub BUILD {
    my ( $self, $args ) = @_;

    $self->{packetCount} = {
        all    => 0,
        failed => 0
    };
    $self->{byPid}      = {};       # storage for assembled packets organized by pid
    $self->{errorList}  = [];       # list of errors found during parsing
    $self->{currentPid} = undef;    # info on current packetParse in process
} ## end sub BUILD

sub _build_report {
    my ($self) = @_;

    my $count = $self->fileParse( $self->{sourceFile} );
    $self->inspect();

    return $self->reportBuild();
} ## end sub _build_report

=head3 failedAdd ( $msg)

Log failed packetParse block.

=cut

sub failedAdd {
    my ( $self, $msg ) = @_;

    my $pid = $self->{currentPid};

    $self->{packetCount}{failed} += $self->{byPid}{$pid}{packetCount} + 1;
    push( @{ $self->{errorList} }, sprintf( "[%4i] %s", $pid, $msg ) );

    # reset
    $self->{byPid}{$pid}{packetCount} = 0;
    $self->{byPid}{$pid}{chunk}       = "";
} ## end sub failedAdd

=head3 sectionAdd ( $raw, $crcOk, $start)

Save section (group of packets) for later statistics.

=cut

sub sectionAdd {
    my ( $self, $raw, $crcOk, $start ) = @_;
    my $pid     = $self->{currentPid};
    my $pidData = $self->{byPid}{$pid};
    my $section;

    $section->{valid}       = 0;
    $section->{packetCount} = $pidData->{packetCount};
    $section->{start}       = $start;

    if ( defined $raw && length($$raw) > 11 ) {
        my $table_id = unpack( "C", substr( $$raw, 0, 1, '' ) );
        $section->{table_id} = $table_id;

        # this only for EIT actual, p/f actual/other)
        if ( $table_id >= 0x4e && $table_id < 0x70 ) {
            $section->{valid} = 1;
            $section->{crcOk} = $crcOk;

            (
                $section->{section_length},
                $section->{sid}, undef, $section->{current_section},
                undef, $section->{tsid}, $section->{onid}, $raw
            )
                = unpack( "nnCCCnna*", $$raw );
            $section->{section_length} &= 0x0fff;
        } ## end if ( $table_id >= 0x4e...)
    } ## end if ( defined $raw && length...)
    push( @{ $pidData->{seq} }, $section );
} ## end sub sectionAdd

=head3 packetParse ( $packet)

Parse single packetParse $block and run table parser for every found section.
Isolate incorrect packets.

=cut

sub packetParse {
    my ( $self, $packet ) = @_;

    $self->{packetCount}{all} += 1;

    my ( $sync_byte, $pid, $continuity_counter, $payload ) = unpack( "CnCa*", $packet );
    my $transport_error_indicator    = $pid >> 15;
    my $payload_unit_start_indicator = ( $pid >> 14 ) & 0x01;
    my $transport_priority           = ( $pid >> 13 ) & 0x01;
    $pid &= 0x1fff;
    $self->{currentPid} = $pid;

    if ( !exists $self->{byPid}{$pid} ) {
        $self->{byPid}{$pid}{packetCount} = 0;
        $self->{byPid}{$pid}{chunk}       = "";
    }

    my $pidData = $self->{byPid}{$pid};

    # save start position of NEW chunk
    if ( $pidData->{packetCount} == 0 ) {
        $pidData->{start} = $self->{packetCount}{all};
    }

    my $transport_scrambling_control = ( $continuity_counter >> 6 ) & 0x03;
    my $adaptation_field_control     = ( $continuity_counter >> 4 ) & 0x03;
    $continuity_counter &= 0x0f;

    if ( $transport_error_indicator != 0 ) {
        $self->failedAdd("transport_error_indicator");
        return;
    }
    if ( $adaptation_field_control != 1 ) {
        $self->failedAdd("adaptation_field_control");
        return;
    }
    if ( $payload_unit_start_indicator == 1 ) {
        my $pointer_field = substr( $payload, 0, 1, '' );
        if ( $pointer_field ne "\x00" ) {
            $self->failedAdd("pointer_field");
            return;
        }
        if ( $pidData->{packetCount} != 0 ) {
            $self->failedAdd("head_zombie");
            return;
        }
    } else {
        if ( $pidData->{packetCount} == 0 ) {
            $self->failedAdd("tail_zombie") if $pid != 0x1fff;
            return;
        }
    } ## end else [ if ( $payload_unit_start_indicator...)]

    $pidData->{chunk} .= $payload;
    $pidData->{packetCount} += 1;

    # get section length
    my ( $table_id, $section_length, undef ) = unpack( "Cna*", $pidData->{chunk} );
    my $section_syntax_indicator = ( $section_length >> 15 );
    $section_length &= 0x0fff;

    # when section complete -> save it
    if ( length( $pidData->{chunk} ) >= ( $section_length + 3 ) ) {
        my $section = substr( $pidData->{chunk}, 0, $section_length + 3 );
        my $crc     = crc( $section, 32, 0xffffffff, 0x00000000, 0, 0x04C11DB7, 0, 0 );
        $self->sectionAdd( \$section, $crc == 0, $pidData->{start} );

        # prepare for next section
        $pidData->{chunk}       = "";
        $pidData->{packetCount} = 0;
    } ## end if ( length( $pidData->...))
} ## end sub packetParse

=head3 fileParse ( $file )

Parse the file and read packetParse by packetParse.

=cut

sub fileParse {
    my ( $self, $file ) = @_;

    my $block;
    open( my $chunk, '<', $file ) || return;
    binmode($chunk);
    while ( read( $chunk, $block, 188 ) ) {
        $self->packetParse($block);
        if ( $self->parsingLimit && $self->{packetCount} >= $self->parsingLimit ) {
            last;
        }
    } ## end while ( read( $chunk, $block...))
    close($chunk);
    return $self->{packetCount};
} ## end sub fileParse

=head3 distanceMinMax ( $serviceData, $section)

Calculate min./max- distance between sections with same table_id.

=cut

sub distanceMinMax {
    my ( $self, $serviceData, $section ) = @_;

    if ( !exists $serviceData->{gap}{ $section->{table_id} } ) {
        $serviceData->{gap}{ $section->{table_id} } = {};
        my $g = $serviceData->{gap}{ $section->{table_id} };
        $g->{first} = $section->{start};
        $g->{last}  = $section->{start} + $section->{packetCount};
        $g->{min}   = undef;
        $g->{max}   = undef;

#                            print " $section->{table_id};$section->{start};$g->{first};$g->{last};$g->{min}\n"
#                                if ( $section->{sid} == 7 );
    } else {
        my $g   = $serviceData->{gap}{ $section->{table_id} };
        my $gap = $section->{start} - $g->{last};
        if ( !$g->{min} || $gap < $g->{min} ) {
            $g->{min} = $gap;
        }
        if ( !$g->{max} || $gap > $g->{max} ) {
            $g->{max} = $gap;
        }

#                            print "$section->{table_id};$section->{start};$g->{first};$g->{last};$g->{min}\n"
#                                if ( $section->{sid} == 7 );
        $g->{last} = $section->{start} + $section->{packetCount};
    } ## end else [ if ( !exists $serviceData...)]
} ## end sub distanceMinMax

=head3 inspect ( )

Analyze stored sections and generate report structure.

=cut

sub inspect {
    my ($self) = @_;

    # analyze packets for each PID
    foreach my $pid ( keys %{ $self->{byPid} } ) {

        my $pidData = $self->{byPid}{$pid};
        $pidData->{sectionCount}  = 0;
        $pidData->{packetCount}   = 0;
        $pidData->{invalidCount}  = 0;
        $pidData->{crcErrorCount} = 0;

        # skip stuffing
        next if $pid == 8191;

        my $nextMappedServiceId = 0;

        say $pid;

        # iterate over all found sections
        foreach my $section ( @{ $pidData->{seq} } ) {

            $pidData->{sectionCount} += 1;
            $pidData->{packetCount}  += $section->{packetCount};

            if ( $section->{valid} ) {
                if ( $section->{crcOk} ) {
                    if ( !exists $pidData->{service}{ $section->{tsid} }{ $section->{onid} }{ $section->{sid} } ) {
                        $pidData->{service}{ $section->{tsid} }{ $section->{onid} }{ $section->{sid} } = {
                            pfa     => 0,
                            pfo     => 0,
                            scha    => 0,
                            scho    => 0,
                            unknown => ''
                        };
                    } ## end if ( !exists $pidData->...)

                    my $serviceData = $pidData->{service}{ $section->{tsid} }{ $section->{onid} }{ $section->{sid} };

                    # calculate distance from previous appearance (gap between sections of same table)
                    $self->distanceMinMax( $serviceData, $section );

                    if    ( $section->{table_id} == 0x4e ) { $serviceData->{pfa} += 1; }
                    elsif ( $section->{table_id} == 0x4f ) { $serviceData->{pfo} += 1; }
                    elsif ( $section->{table_id} >= 0x50 && $section->{table_id} < 0x60 ) {
                        $serviceData->{scha} += 1;
                    } else {
                        $serviceData->{scho} += 1;
                    }

#                    # map various sid to compact range
#                    if ( !exists $st->{serviceIdMapping}{ $section->{sid} } ) {
#                        $st->{serviceIdMapping}{ $section->{sid} } = $nextMappedServiceId;
#                        $nextMappedServiceId += 1;
#                    }
#
#                    # replace old sid with mapped
#                    $section->{sid} = $st->{serviceIdMapping}{ $section->{sid} };
                } else {
                    $pidData->{crcErrorCount} += 1;
                }
            } else {
                $pidData->{invalidCount} += 1;
            }
        } ## end foreach my $section ( @{ $pidData...})

        delete $self->{byPid}{$pid}{seq};
        delete $self->{byPid}{$pid}{start};
    } ## end foreach my $pid ( keys %{ $self...})

#    say YAML::XS::Dump($self->{byPid});
    return $self->{byPid};
} ## end sub inspect

=head3 reportBuild( )

Return text formated report of the inspected file content.

=cut

sub reportBuild {
    my ($self) = @_;

#    say YAML::XS::Dump($self);
#    exit;
    my $output = "";
    my ( $pid, $onid, $tsid, $sid, $serviceData, $pidData, $minGap, $interGap, $serviceCount, $table_id );

    # number of packets between same table and service to achieve 25ms requirement
    my $requiredGapCount = ceil( $self->{packetCount}{all} * 25 / 1000 / 30 );

    format HEAD =
-- cherryInspector - ver. @<<<<< Copyright 2014-2020 Bojan Ramsak --------------
$cherryEpg::Inspector::VERSION
               PID: @>>>>>              Date:   @>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
$pid, Time::Piece::localtime->strftime()
Number of sections: @>>>>>         not valid: @>>>>>          CRC failed: @>>>>>
$pidData->{sectionCount}, $pidData->{invalidCount}, $pidData->{crcErrorCount}
Number of packets : @>>>>>      bitrate(30s): @>>>>> kb/s      Gap(25ms): @>>>>>
$pidData->{packetCount}, $pidData->{packetCount}*188*8/30000, $requiredGapCount
 onid   tsid    sid    p/f a   p/f o   sch a   sch o  tbl  gap(inter)  ref  flag
--------------------------------------------------------------------------------
.

    format TABLE =
@>>>>  @>>>>>  @>>>>  @|||||  @|||||  @|||||  @||||| 
sprintf( "%4Xh",$onid), $tsid,  $sid, $serviceData->{pfa}, $serviceData->{pfo}, $serviceData->{scha}, $serviceData->{scho}
.

    format SUBTABLE =
                                                      @>>  @>>>(@>>>) @>>>  @>>>
sprintf( "%2Xh",$table_id), $minGap, $interGap, '?', $interGap<$requiredGapCount ? 'Err' : ' - '
.

    format FOOT = 
================================================================================
  Number of services: @>>>>>
$serviceCount

.

    open( RPRT, '>', \$output ) or die;
    binmode( RPRT, ":utf8" );
    select(RPRT);
    $-  = 0;
    $%  = 0;
    $=  = 100000;    # never paginate
    $^L = '';

    # iterate over PID
    foreach $pid ( sort keys %{ $self->{byPid} } ) {

        # skip stuffing
        next if $pid == 8191;

        $pidData      = $self->{byPid}{$pid};
        $serviceCount = 0;

        $~ = "HEAD";
        write;

        # iterate over tsid
        foreach $tsid ( sort { $a <=> $b } keys %{ $pidData->{service} } ) {

            # iterate over onid
            foreach $onid ( sort keys %{ $pidData->{service}{$tsid} } ) {

                #iterate over sid
                foreach $sid ( sort { $a <=> $b } keys %{ $pidData->{service}{$tsid}{$onid} } ) {

                    $serviceCount += 1;
                    $serviceData = $pidData->{service}{$tsid}{$onid}{$sid};
                    $serviceData->{pfa}  = '-' if !$serviceData->{pfa};
                    $serviceData->{pfo}  = '-' if !$serviceData->{pfo};
                    $serviceData->{scha} = '-' if !$serviceData->{scha};
                    $serviceData->{scho} = '-' if !$serviceData->{scho};

                    $~ = "TABLE";
                    write;

                    foreach $table_id ( sort { $a <=> $b } keys %{ $serviceData->{gap} } ) {
                        my $g = $serviceData->{gap}{$table_id};
                        $minGap   = $g->{min};
                        $interGap = $self->{packetCount}{all} - $g->{last} + $g->{first};
                        if ( $minGap < $interGap ) {
                            $interGap = $minGap;
                        }
                        $minGap   = '-' if $minGap == -1;
                        $interGap = '-' if $interGap == -1;

                        $~ = "SUBTABLE";
                        write;
                    } ## end foreach $table_id ( sort { ...})
                } ## end foreach $sid ( sort { $a <=>...})
            } ## end foreach $onid ( sort keys %...)
        } ## end foreach $tsid ( sort { $a <=>...})

        $~ = "FOOT";
        write;
    } ## end foreach $pid ( sort keys %{...})

    select(STDOUT);

    return $output;
} ## end sub format

=head3 EITdistrChart( $filename, $pid)

Save to file time distribution of EIT sections.
If $filename not defined return to stdout.
Use $pid to work on. Default is 18.

=cut

sub EITdistrChart {
    my $self     = shift;
    my $filename = shift;
    my $pid      = shift || 18;

    my $p = $self->{pid}{$pid};

    die( "No data defined for EITdistrChart [$pid]!") if( ! defined $p);

    my $height = 580;
    my $width  = $p->{packet_count};

    my $image = GD::Image->new( $width, $height);
    $image->interlaced('true');

    my $black  = $image->colorAllocate( 0,   0,   0);
    my $white  = $image->colorAllocate( 255, 255, 255);    # define background
    my $red    = $image->colorAllocate( 255, 0,   0);
    my $blue   = $image->colorAllocate( 0,   0,   255);
    my $green  = $image->colorAllocate( 50,  200, 0);
    my $orange = $image->colorAllocate( 255, 200, 0);
    my $grey   = $image->colorAllocate( 15,  15,  15);
    my @colors = (
        0xCCC791, 0xD1DAF5, 0xB27171, 0x7177B2, 0xAEADB2, 0xB28E71,
        0xD1EAF5, 0xF5D1D6, 0x8AA4B0, 0xB2B0AD, 0x71B2B2, 0x71B2A8,
        0xCC91C8, 0x7E71B2, 0xEEE676, 0xCCC771, 0xD1DAD5, 0xB27151,
        0x717792, 0xAEAD92, 0xB28E51, 0xD1EAD5, 0xF5D1B6, 0x8AA490,
        0xB2B08D, 0x71B292, 0x71B288, 0xCC91A8, 0x7E7192, 0xEEE656
    );

    # convert/allocate colors from the hex definition above
    foreach ( @colors) {
        my $c = $image->colorAllocate( ($_ >> 16), ($_ >> 8) & 0xff, $_ & 0xff);
        $_ = $c;
    }

    my $i      = 0;
    my $raster = 0;

    # vertical gridlines
    while ( $raster < $width) {
#        $image->line( $raster, 0, $raster, $height, $grey);
        $raster += 10;
    }

    $raster = int( $width/17);
    # vertical gridlines
    while ( $raster < $width) {
        $image->line( $raster, 0, $raster, $height, $grey);
        $raster += int( $width/17);
    }

    # horizontal gridlines
    $raster = 0;
    while ( $raster < $height) {
        $image->line( 0, $raster, $width, $raster, $grey);
        $raster += 10;
    }

    my $x            = 0;
    my $chunkCounter = 0;
    foreach my $chunk ( @{$p->{seq}}) {
        my $chunkSize = $chunk->{packet_in_chunk};
        $chunkCounter += $chunkSize;
        while( $chunkSize-- > 0) {
            if( $chunk->{valid} ) { $image->setPixel( $x, 58, $green);}
            if( ! $chunk->{crcOk} ) {
                $image->setPixel( $x, 2, $red);
                $image->setPixel( $x, 3, $red);
            }
            else {

                # show struct length
                $image->setPixel( $x, 4 + ( $chunkCounter % 2) * 2, $black);
                $image->setPixel( $x, 5 + ( $chunkCounter % 2) * 2, $black);
                # show service_id
                $image->setPixel( $x, 8 + 2*$chunk->{service_id}, $colors[$chunk->{service_id} % scalar @colors]);
                $image->setPixel( $x, 9 + 2*$chunk->{service_id}, $colors[$chunk->{service_id} % scalar @colors]);
                # make some offset because of multiple tables
                my $corr = 0;
                if( $chunk->{table_id} == 0x4e) {
                    $corr = -4;
                }
                elsif( $chunk->{table_id} >= 0x50) {
                    $corr = (256*($chunk->{table_id}-0x50)) % 512;
                }
                $image->setPixel( $x, 60 + $chunk->{current_section}+$corr, $colors[$chunk->{service_id} % scalar @colors]);
                $image->setPixel( $x, 61 + $chunk->{current_section}+$corr, $colors[$chunk->{service_id} % scalar @colors]);
            }
            ++$x;
        }
    }

    # write png-format to file
    open( my $fh, ">$filename") or die "Error writing [$filename]: $!";
    binmode( $fh);
    print( $fh $image->png);
    close( $fh);
    return 1;
}
=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
