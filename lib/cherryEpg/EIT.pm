package cherryEpg::EIT;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Log::Log4perl qw(get_logger);
use Carp;
use Encode;
use Digest::CRC qw(crc);

my $logger = get_logger('builder');

has rule => (
    is       => 'ro',
    required => 1
);

my %prefix = (
    'iso-8859-1'  => "\x10\x00\x01",
    'iso-8859-2'  => "\x10\x00\x02",
    'iso-8859-3'  => "\x10\x00\x03",
    'iso-8859-4'  => "\x10\x00\x04",
    'iso-8859-5'  => "\x01",
    'iso-8859-6'  => "\x02",
    'iso-8859-7'  => "\x03",
    'iso-8859-8'  => "\x04",
    'iso-8859-9'  => "\x05",
    'iso-8859-10' => "\x10\x00\x0a",
    'iso-8859-11' => "\x10\x00\x0b",
    'iso-8859-12' => "\x10\x00\x0c",
    'iso-8859-13' => "\x10\x00\x0d",
    'iso-8859-14' => "\x10\x00\x0e",
    'iso-8859-15' => "\x10\x00\x0f",
    'utf-8'       => "\x15",
    'latin-1'     => "",
);

sub BUILD {
    my ( $self, $args ) = @_;

    my $rule = $self->rule;

    $self->{table}                       = 'EIT';
    $self->{table_id}                    = $rule->{table_id};
    $self->{service_id}                  = $rule->{service_id} & 0xffff;
    $self->{last_section_number}         = undef;
    $self->{transport_stream_id}         = $rule->{transport_stream_id};
    $self->{original_network_id}         = $rule->{original_network_id};
    $self->{channel_id}                  = $rule->{channel_id};
    $self->{segment_last_section_number} = undef;
    $self->{codepage}                    = lc( $rule->{codepage} );

    if ( !exists $prefix{ $self->{codepage} } ) {
        $logger->fatal( "prefix for [$self->{codepage}] not defined", $rule->{service_id}, $rule->{eit_id}, $rule );
        exit 1;
    }

    $self->{codepage_prefix}        = $prefix{ $self->{codepage} };
    $self->{codepage_prefix_length} = length( $self->{codepage_prefix} );

    if ( ( $rule->{table_id} & 0x4e ) == 0x4e ) {

        # this is for present/following
        $self->{last_table_id} = $self->{table_id};
    } else {

        # this is for schedule
        my $st = int( $rule->{maxsegments} / 32 );
        if ( $rule->{actual} == 1 ) {
            $self->{last_table_id} = 0x50 + $st;
        } else {
            $self->{last_table_id} = 0x60 + $st;
        }
    } ## end else [ if ( ( $rule->{table_id...}))]
    $self->{sections} = [];

    return;
} ## end sub BUILD

=head3 add2Segment( $segment_number, $event)

Add $event to segment with number $segment_number.
$event is reference to hash containin event data.

Return 1 on success.
Return undef on error.

=cut

sub add2Segment {
    my ( $self, $segment_number, $event ) = @_;

    if ( !defined $segment_number or !defined $event ) {
        return;
    }

    my $target_section         = ( $segment_number % 32 ) * 8;
    my $largest_target_section = $target_section + 8;
    my $size;

    while ( ( ( $size = $self->add2Section( $target_section, $event ) ) == -1 )
        and $target_section < $largest_target_section ) {
        ++$target_section;
    }
    return $size;
} ## end sub add2Segment

=head3 add2Section ( $section_number, $event)

Add $event to section with number $section_number.
$event is reference to hash containin event data.

Return binary $size of all events in section (always < 4078)
or negativ if section is full, undef on error.

=cut

sub add2Section {
    my ( $self, $section_number, $event ) = @_;

    return unless defined $section_number;

    my $section_size = length( $self->{sections}[$section_number] // "" );

    # add empty event
    if ( !defined $event ) {
        $self->{sections}[$section_number] .= "";
        return $section_size;
    }

    my $alldescriptors = "";

    # iterate over event descriptors
    foreach my $descriptor ( @{ $event->{descriptors} } ) {
        for ( $descriptor->{descriptor_tag} ) {
            $_ == 0x4d && do {
                $alldescriptors .= $self->getShortEventDescriptorBin($descriptor);
                last;
            };
            $_ == 0x55 && do {
                $alldescriptors .= $self->getParentalRatingDescriptor($descriptor);
                last;
            };
            $_ == 0x4e && do {
                $alldescriptors .= $self->getExtendedEventDescriptorBin($descriptor);
                last;
            };
            $_ == 0x54 && do {
                $alldescriptors .= $self->getContentDescriptorBin($descriptor);
                last;
            };
        } ## end for ( $descriptor->{descriptor_tag...})
    } ## end foreach my $descriptor ( @{...})

    my $descriptor_loop_length = length($alldescriptors);

    # build binary presentation
    my $struct = pack( 'na5a3na*',
        $event->{event_id},
        _epoch2mjd( $event->{start} ),
        _int2bcd( $event->{duration} ),
        ( ( ( ( $event->{running_status} & 0x07 ) << 1 ) + ( $event->{free_CA_mode} & 0x01 ) ) << 12 ) + $descriptor_loop_length,
        $alldescriptors );

    my $struct_size = length($struct);

    # add to section if enough space left
    if ( $section_size + $struct_size < 4078 ) {
        $self->{sections}[$section_number] .= $struct;
        return $section_size + $struct_size;
    } else {

        return -1;
    }
} ## end sub add2Section

=head3 getSections ()

Return reference to hash of sections with section_number as key and packetized section as value.

=cut

sub getSections {
    my ( $self, $version_number ) = @_;
    $version_number //= 0;
    my $sections = {};

    my $last_section_number = $#{ $self->{sections} };
    my $num_segments        = int( $last_section_number / 8 );

    my $current_segment = 0;

    # iterate over segments
    while ( $current_segment <= $num_segments ) {

        # find last used section in this segment
        my $i = 7;
        while ( $i >= 0 and !defined $self->{sections}[ $current_segment * 8 + $i ] ) {
            --$i;
        }
        my $segment_last_section_number = $i + $current_segment * 8;

        # iterate over sections in this segment and add them to final hash
        my $current_section = $current_segment * 8;
        while ( $current_section <= $segment_last_section_number ) {
            my $section_length = length( $self->{sections}[$current_section] ) + 15;

            my $struct = pack(
                'CnnCCCnnCCa*',
                $self->{table_id},
                0xf000 + ( $section_length & 0xfff ),                                    # section_syntax_indicator is always 1
                $self->{service_id}, 0xc0 + ( ( $version_number & 0x1f ) << 1 ) + 0x01,  # current_next indicator MUST be always 1
                $current_section,
                $last_section_number,
                $self->{transport_stream_id},
                $self->{original_network_id},
                $segment_last_section_number,
                $self->{last_table_id},
                $self->{sections}[$current_section]
            );
            my $crc = crc( $struct, 32, 0xffffffff, 0x00000000, 0, 0x04C11DB7, 0, 0 );

            # add the binary to result
            # we will build with default PID = 18 and change it later
            $sections->{$current_section} = _packetize( 18, $struct . pack( "N", $crc ) );
            ++$current_section;
        } ## end while ( $current_section ...)
        ++$current_segment;
    } ## end while ( $current_segment ...)
    return $sections;
} ## end sub getSections

sub _bytes {
    use bytes;
    return length shift;
}

=head3 getShortEventDescriptorBin( $descriptor)

Return Short Event Descriptor

=cut

sub getShortEventDescriptorBin {
    my ( $self, $descriptor ) = @_;
    my $struct = "";

    my $descriptor_tag = 0x4d;
    my $descriptor_length;
    my $language_code  = $descriptor->{language_code} // 'slv';
    my $raw_event_name = $descriptor->{event_name}    // '';
    my $raw_text       = $descriptor->{text}          // '';
    my $event_name     = "";
    my $encoded;
    my $available_space = 255 - 5;

    if ( $raw_event_name ne "" ) {
        $encoded    = encode( $self->{codepage}, $raw_event_name );
        $event_name = $self->{codepage_prefix} . substr( $encoded, 0, $available_space - $self->{codepage_prefix_length} );
    }
    my $event_name_length = length($event_name);
    $available_space -= $event_name_length;

    my $text = "";
    if ( $raw_text ne "" && $available_space > $self->{codepage_prefix_length} ) {
        $encoded = encode( $self->{codepage}, $raw_text );
        $text =
            $self->{codepage_prefix} . substr( $encoded, 0, $available_space - $self->{codepage_prefix_length} );
    }
    my $text_length = length($text);

    $descriptor_length = $event_name_length + $text_length + 5;
    $struct            = pack( "CCa3Ca*Ca*",
        $descriptor_tag, $descriptor_length, $language_code, $event_name_length, $event_name, $text_length, $text );

    return $struct;
} ## end sub getShortEventDescriptorBin

=head3 getParentalRatingDescriptor( $descriptor)

Return 1 or many Parental rating Descriptors

=cut

sub getParentalRatingDescriptor {
    my ( $self, $descriptor ) = @_;

    my $descriptor_tag = 0x55;
    my $descriptor_length;

    my $substruct = '';
    foreach ( @{ $descriptor->{list} } ) {
        my $country_code = $_->{country_code} // 'SVN';
        my $rating       = $_->{rating}       // 0;
        $substruct .= pack( "a3C", $country_code, $rating );
    }
    $descriptor_length = length($substruct);
    return pack( "CCa*", $descriptor_tag, $descriptor_length, $substruct );
} ## end sub getParentalRatingDescriptor

=head3 getExtendedEventDescriptorBin( $descriptor)

Return 1 or many Extended Event Descriptors

=cut

sub getExtendedEventDescriptorBin {
    my ( $self, $descriptor ) = @_;
    my $struct = "";

    # skip if nothing to do
    return '' if !exists $descriptor->{text} || !defined $descriptor->{text} || $descriptor->{text} eq "";

    my $raw_fulltext     = $descriptor->{text};
    my $full_text_length = length($raw_fulltext);
    my $fulltext;

    # the limit for this is 16 x 255 by numbers of extended event descriptors
    # also is a limit the max. section size 4096
    # let's say the max is 2048(2034)
    if ( $full_text_length > 2034 ) {
        $raw_fulltext = substr( $raw_fulltext, 0, 2034 );    # shorten text
    }

    $fulltext         = encode( $self->{codepage}, $raw_fulltext );
    $full_text_length = length($fulltext);

    # split up the text into multiple Extended Event Descriptors
    my $maxTextLength          = 255 - 6;
    my $last_descriptor_number = int( $full_text_length / $maxTextLength );

    my $descriptor_tag = 0x4e;
    my $language_code  = $descriptor->{language_code} // 'slv';
    my $descriptor_length;

    my $items = '';

    # generate item (description + text)
    if ( exists $descriptor->{item} ) {
        my $description = $descriptor->{item}{description};
        if ( length($description) > 64 ) {
            $description = substr( $description, 0, 64 );
        }
        $description = encode( $self->{codepage}, $description );
        my $description_length = length($description);
        my $text               = $descriptor->{item}{text};
        if ( length($text) > 64 ) {
            $text = substr( $text, 0, 64 );
        }
        $text = encode( $self->{codepage}, $text );
        my $text_length = length($text);

        $items = pack( "Ca*Ca*", $description_length, $description, $text_length, $text );
    } ## end if ( exists $descriptor...)

    my $items_length = length($items);
    my $text;
    my $text_length;
    my $descriptor_number = 0;

    while ( $descriptor_number <= $last_descriptor_number ) {
        $text = $self->{codepage_prefix}
            . substr( $fulltext, 0, $maxTextLength - $self->{codepage_prefix_length} - $items_length, '' );
        $text_length       = length($text);
        $descriptor_length = 6 + $items_length + $text_length;
        $struct .= pack( "CCCa3Ca*Ca*",
            $descriptor_tag, $descriptor_length, ( $descriptor_number << 4 ) | $last_descriptor_number,
            $language_code,  $items_length, $items, $text_length, $text );
        if ( $descriptor_number == 0 ) {

            # reset items after first iteration
            $items_length = 0;
            $items        = '';
        } ## end if ( $descriptor_number...)
        ++$descriptor_number;
    } ## end while ( $descriptor_number...)
    return $struct;
} ## end sub getExtendedEventDescriptorBin

=head3 getContentDescriptorBin( $descriptor)

Return Content Descriptor

=cut

sub getContentDescriptorBin {
    my ( $self, $descriptor ) = @_;

    my $descriptor_tag = 0x54;
    my $descriptor_length;

    my $substruct = '';
    foreach my $nibbles ( @{ $descriptor->{list} } ) {
        $substruct .= pack( "CC", $nibbles, 0 );
    }
    $descriptor_length = length($substruct);
    return pack( "CCa*", $descriptor_tag, $descriptor_length, $substruct );
} ## end sub getContentDescriptorBin

=head3 _packetize( $pid, $section)

Generate MPEG transport stream for defined $pid and $section in database.
Continuity counter starts at 0;
Return MTS.

=cut

sub _packetize {
    my ( $pid, $data ) = @_;
    my $continuity_counter  = 0;
    my $packet_payload_size = 188 - 4;

    $data = "\x00" . $data;    # add the pointer field at the beginning
    my $data_len = length($data);

    # 'pointer_field' is only in the packet, carrying first byte of this section.
    # Therefore this packet has 'payload_unit_start_indicator' equal '1'.
    # All other packets don't have a 'pointer_filed' and therefore
    # 'payload_unit_start_indicator' is '0'
    #
    my $offs = 0;
    my $mts  = "";

    while ( my $payload = substr( $data, $offs, $packet_payload_size ) ) {

        # Add stuffing byte to payload
        my $stuffing_bytes = $packet_payload_size - length($payload);

        # while ( $stuffing_bytes-- ) { $payload .= "\xff"; }
        $payload .= "\xff" x $stuffing_bytes;

        # Header + Payload:
        my $payload_unit_start_indicator = $offs == 0 ? 0b0100 << 12 : 0;    # payload_unit_start_indicator
        my $packet =
            pack( "CnC", 0x47, $pid | $payload_unit_start_indicator, 0b00010000 | ( $continuity_counter & 0x0f ) ) . $payload;
        $mts .= $packet;
        $offs += $packet_payload_size;
        ++$continuity_counter;
        last if $offs > $data_len - 1;
    } ## end while ( my $payload = substr...)
    return $mts;
} ## end sub _packetize

=head3 _int2bcd( $time)

Convert integer $time in seconds into 24 bit time BCD format (hour:minute:seconds).

=cut

sub _int2bcd {
    my ($time) = @_;
    my $hour   = int( $time / ( 60 * 60 ) ) % 99;
    my $min    = int( $time / 60 ) % 60;
    my $sec    = $time % 60;
    my $struct = pack( 'CCC', int( $hour / 10 ) * 6 + $hour, int( $min / 10 ) * 6 + $min, int( $sec / 10 ) * 6 + $sec );
    return $struct;
} ## end sub _int2bcd

=head3 _bcd2int( $bcd)

Convert time in 24 bit BCD format (hour:minute:seconds) in seconds from midnight;

=cut

sub _bcd2int {
    my ($bcd) = @_;
    my ( $hour, $min, $sec ) = unpack( 'H2H2H2', $bcd );
    my $int = ( $hour * 60 + $min ) * 60 + $sec;
    return $int;
} ## end sub _bcd2int

=head3 _epoch2mjd( $time)

Convert epoch $time into 40 bit Modified Julian Date and time BCD format.

=cut

sub _epoch2mjd {
    my ($time) = @_;
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday ) = gmtime($time);
    ++$mon;

    my $l      = $mon == 1 || $mon == 2 ? 1 : 0;
    my $MJD    = 14956 + $mday + int( ( $year - $l ) * 365.25 ) + int( ( $mon + 1 + $l * 12 ) * 30.6001 );
    my $struct = pack( 'na*', $MJD, _int2bcd( $time % ( 60 * 60 * 24 ) ) );
    return $struct;
} ## end sub _epoch2mjd

=head3 _mjd2epoch( $time)

Convert 40 bit Modified Julian Date and time BCD format into epoch.

=cut

sub _mjd2epoch {
    my ($combined) = @_;
    my ( $mjd, $bcd ) = unpack( 'na3', $combined );

    my ( $y, $m );
    $y = int( ( $mjd - 15078.2 ) / 365.25 );
    $m = int( ( $mjd - 14956 - int( $y * 365.25 ) ) / 30.6001 );
    my $k     = $m == 14 || $m == 15 ? 1 : 0;
    my $year  = $y + $k;
    my $mon   = $m - 1 - $k * 12 - 1;
    my $mday  = $mjd - 14956 - int( $y * 365.25 ) - int( $m * 30.6001 );
    my $epoch = mktime( 0, 0, 1, $mday, $mon, $year, 0, 0, 0 ) + bcd2int($bcd);
    return $epoch;
} ## end sub _mjd2epoch

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
