package cherryEpg::Table;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use YAML::XS;
use Time::Piece;
use Digest::CRC qw(crc);
use Encode;

=head3 build( $table)

Build output chunk from input $table structure.

=cut

sub build {
    my ( $self, $table ) = @_;

    if ( $table && ref($table) eq 'HASH' && $table->{table} ) {

        my $tableMethod = '_' . $table->{table};
        if ( $self->can($tableMethod) ) {

            $self->{table} = $table->{table};

            # no strict 'refs';
            my $section = $self->$tableMethod($table);

            if ($section) {
                $self->crcAdd($section);

                return unless defined $table->{pid};

                return $self->packetize( $table->{pid}, $section );
            } ## end if ($section)
            return;
        } else {
            return;
        }
    } else {
        return;
    }
} ## end sub build

=head3 descriptorBuilder( $descriptor)

Parse the $descriptor structure and return binary presentation on success.

=cut

sub descriptorBuilder {
    my ( $self, $descriptor ) = @_;

    if ( !ref($descriptor) ) {

        # simple plain binary descriptor
        my $len          = length($descriptor);
        my $effectiveLen = $len - 2;
        substr( $descriptor, 1, 1, chr($effectiveLen) );
        return $descriptor;
    } else {

        # extract descriptor name
        my @key = keys %$descriptor;
        if ( scalar @key == 1 ) {
            my $name   = $key[0];
            my $method = '_' . $name;

            if ( $self->can($method) ) {
                return $self->$method( $descriptor->{$name} );
            }
        } ## end if ( scalar @key == 1 )
    } ## end else [ if ( !ref($descriptor))]
    return;
} ## end sub descriptorBuilder

=head3 _PAT ($table)

Parse the PAT $table structure and return \$section.

=cut

sub _PAT {
    my ( $self, $table ) = @_;

    my @requiredKey = qw( transport_stream_id programs);
    return if $self->keyMissing( $table, @requiredKey );

    my $programs             = '';
    my @requiredKeyInService = qw(program_number pid);
    foreach my $program ( @{ $table->{programs} } ) {
        return if $self->keyMissing( $program, @requiredKeyInService );

        # pack stream
        $programs .= pack( "nn", $program->{program_number}, 0xe000 | $program->{pid} );
    } ## end foreach my $program ( @{ $table...})

    my $section = pack( "CnnCCCa*",
        $table->{table_id} // 0,
        ( 5 + length($programs) + 4 ) | 0b1011 << 12,
        $table->{transport_stream_id},
        ( ( $table->{version_number} // 0 ) << 1 ) | 0b11000001,
        $table->{section_number} // 0,
        $table->{last_section_number} // 0, $programs );

    return \$section;
} ## end sub _PAT

=head3 _SDT ($table)

Parse the SDT $table structure and return \$section.

=cut

sub _SDT {
    my ( $self, $table ) = @_;

    my @requiredKey = qw( transport_stream_id original_network_id services);
    return if $self->keyMissing( $table, @requiredKey );

    my $services = '';
    my @requiredKeyInService =
        qw(service_id eit_schedule_flag eit_present_following_flag running_status free_ca_mode descriptors);
    foreach my $service ( @{ $table->{services} } ) {
        return if $self->keyMissing( $service, @requiredKeyInService );
        my $descriptor = $self->descriptorLoop( $service->{descriptors} );
        return if !defined $descriptor;

        # pack stream
        $services .= pack( "nCna*",
            $service->{service_id},
            0xfc | ( $service->{eit_schedule_flag} & 1 ) << 1 | ( $service->{eit_present_following_flag} & 1 ),
            ( $service->{running_status} & 0x07 ) << 13 | ( $service->{free_ca_mode} & 1 ) << 12 | length($descriptor),
            $descriptor );

    } ## end foreach my $service ( @{ $table...})

    my $section = pack( "CnnCCCnCa*",
        $table->{table_id} // 0x42,
        ( 8 + length($services) + 4 ) | 0xf000,
        $table->{transport_stream_id},
        ( ( $table->{version_number} // 0 ) << 1 ) | 0b11000001,
        $table->{section_number}      // 0,
        $table->{last_section_number} // 0,
        $table->{original_network_id},
        0xff,
        $services );

    return \$section;
} ## end sub _SDT

=head3 _PMT ($table)

Parse the PMT $table structure and return \$section.

=cut

sub _PMT {
    my ( $self, $table ) = @_;

    my @requiredKey = qw( program_number pcr_pid);
    return if $self->keyMissing( $table, @requiredKey );

    my $info = $self->descriptorLoop( $table->{program_info_descriptors} );
    return if !defined $info;

    my $bin                 = '';
    my @requiredKeyInStream = qw( descriptors stream_type elementary_pid);
    foreach my $stream ( @{ $table->{elementary_streams} } ) {
        return if $self->keyMissing( $stream, @requiredKeyInStream );
        my $descriptor = $self->descriptorLoop( $stream->{descriptors} );
        return if !defined $descriptor;

        $bin .=
            pack( "Cnna*", $stream->{stream_type}, 0xe000 | $stream->{elementary_pid}, 0xf000 | length($descriptor),
            $descriptor );

    } ## end foreach my $stream ( @{ $table...})

    my $section = pack(
        "CnnCCCnna*a*",    # Sestavi celoten section
        2,
        0xb000 | ( 9 + length($bin) + length($info) + 4 ),
        $table->{program_number},
        0b11000001 | ( ( ( $table->{version_number} // 0 ) & 0x1f ) << 1 ),
        $table->{section_number}      // 0,
        $table->{last_section_number} // 0,
        0xe000 | $table->{pcr_pid},
        0xf000 | length($info),
        $info,
        $bin
    );

    return \$section;
} ## end sub _PMT

=head3 descriptorLoop( $list)

Parse all descriptors in $loop and return $binary on success.

=cut

sub descriptorLoop {
    my ( $self, $loop ) = @_;

    my $buffer = '';
    foreach ( @{$loop} ) {
        my $d = $self->descriptorBuilder($_);
        if ( defined $d ) {
            $buffer .= $d;
        } else {
            return;
        }
    } ## end foreach ( @{$loop} )

    return $buffer;
} ## end sub descriptorLoop

sub _service_descriptor {
    my ( $self, $descriptor ) = @_;

    my @requiredKey = qw(service_type service_name service_provider_name);
    return if $self->keyMissing( $descriptor, @requiredKey );

    my $service_provider_name = encode( 'utf-8', $descriptor->{service_provider_name} );

    # only add codepage indication when needed
    if ( $service_provider_name ne $descriptor->{service_provider_name} ) {
        $service_provider_name = "\x15" + $service_provider_name;
    }

    my $service_name = encode( 'utf-8', $descriptor->{service_name} );
    if ( $service_name ne $descriptor->{service_name} ) {
        $service_name = "\x15" . $service_name;
    }

    my $bin = pack( "CCCCa*Ca*",
        0x48,
        3 + length($service_provider_name) + length($service_name),
        $descriptor->{service_type},
        length($service_provider_name),
        $service_provider_name, length($service_name), $service_name );

    return $bin;
} ## end sub _service_descriptor

=head3 crcAdd( $section)

Calculate and add CRC to end of $$section.

=cut

sub crcAdd {
    my ( $self, $section ) = @_;

    utf8::downgrade($$section);
    my $crc = crc( $$section, 32, 0xffffffff, 0x00000000, 0, 0x04C11DB7, 0 );
    $$section .= pack( "N", $crc );
    return;
} ## end sub crcAdd

=head3 packetize( $pid, $section)

Split $$section in packets with correct header and $pid
Return PES.

=cut

sub packetize {
    my ( $self, $pid, $section ) = @_;
    my $packet_payload_size = 188 - 4;
    my $data                = "\x00" . $$section;

    # 'pointer_field' is only in the packet, carrying first byte of this section.
    # Therefore this packet has 'payload_unit_start_indicator' equal '1'.
    # All other packets don't have a 'pointer_filed' and therefore
    # 'payload_unit_start_indicator' is cleared
    #
    my $offs    = 0;
    my $stream  = "";
    my $counter = 0;

    no warnings;    # this is because off the substr warning behaviour
    while ( my $payload = substr( $data, $offs, $packet_payload_size ) ) {

        # Add stuffing byte to payload
        my $stuffing_bytes = $packet_payload_size - length($payload);
        while ( $stuffing_bytes-- ) { $payload .= "\xff"; }

        # Header + Payload:
        my $p_u_s_i = $offs == 0 ? 0b0100 << 12 : 0;                                            # payload_unit_start_indicator
        my $packet  = pack( "CnC", 0x47, $pid | $p_u_s_i, 0b00010000 | $counter ) . $payload;
        $stream .= $packet;
        $offs += $packet_payload_size;
        ++$counter;
    } ## end while ( my $payload = substr...)
    return $stream;
} ## end sub packetize

=head3 keyMissing( $hash, @key)

Verify if @key exists in $hash and generate report if not.
Return 1 if failed.

=cut

sub keyMissing {
    my ( $self, $hash, @key ) = @_;

    my $missing = 0;
    foreach (@key) {
        next if exists $hash->{$_} and ( defined $hash->{$_} or $_ eq 'descriptors' or $_ eq 'subcell_info' );
        $missing += 1;
    }
    return $missing;
} ## end sub keyMissing

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE.txt', which is part of this source code package.

=cut

1;
