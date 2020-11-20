package cherryEpg::Exporter;

use 5.010;
use utf8;
use Moo::Role;
use strictures 2;
use Time::Local;

=head3 channelListExport( $list, $url, $language)

Export schedule data for $list of channels in xml format.
Use $url as source and $language for descriptors.
Return xml serialized string.

=cut

sub channelListExport {
    my ( $self, $list, $url, $language ) = @_;
    $url      //= "127.0.0.1";
    $language //= "en";

    # make a correct header
    my $output = '<?xml version="1.0" encoding="utf-8"?>' . "\n";
    $output .= '<!DOCTYPE tv SYSTEM "http://' . $url . '/xmltv.dtd">' . "\n";

    my $xml = {
        'tv' => {
            'generator-info-name' => 'cherryEpg - http://epg.cherryhill.eu',
            'channel'             => [],
            'programme'           => []
        }
    };

    foreach my $channel ( sort { $a->{channel_id} <=> $b->{channel_id} } @$list ) {
        my $channel_id = $channel->{channel_id};

        my $channelDefinition = {
            'id'           => $channel_id & 0xffff,
            'display-name' => { 'content' => $channel->{name} }
        };
        push( @{ $xml->{tv}{channel} }, $channelDefinition );

        foreach my $event ( $self->listEvent( $channel->{channel_id} ) ) {
            my $eventDescription = {
                'title' => {
                    'lang'    => $language,
                    'content' => $self->_extractDescriptor( $event->{descriptors}, 77, "event_name" ),
                },
                'channel' => $channel->{channel_id} & 0xffff,
                'start'   => Time::Piece->new( $event->{start} )->strftime("%Y%m%d%H%M%S %z"),
                'stop'    => Time::Piece->new( $event->{stop} )->strftime("%Y%m%d%H%M%S %z"),
            };

            my $subTitle = $self->_extractDescriptor( $event->{descriptors}, 77, "text" );
            $eventDescription->{'sub-title'}{'lang'}    = $language;
            $eventDescription->{'sub-title'}{'content'} = $subTitle;

            my $description = $self->_extractDescriptor( $event->{descriptors}, 78, "text" );
            $eventDescription->{'desc'}{'lang'}    = $language;
            $eventDescription->{'desc'}{'content'} = $description;

            push( @{ $xml->{tv}{programme} }, $eventDescription );
        } ## end foreach my $event ( $self->...)
    } ## end foreach my $channel ( sort ...)

    my $xmlParser = MyXMLSimple->new( RootName => 'xml', KeepRoot => 1 );
    $output .= $xmlParser->XMLout($xml);

    return $output;
} ## end sub channelListExport

=head3 _extractDescriptor( $descriptorList, $path¸)

Extract field name $field of event descriptor with $descriptor_tag from list.

=cut

sub _extractDescriptor {
    my ( $self, $descriptorList, $descriptor_tag, $field ) = @_;

    foreach my $descriptor (@$descriptorList) {
        next if $descriptor->{descriptor_tag} != $descriptor_tag;
        return $descriptor->{$field};
    }

    return "";
} ## end sub _extractDescriptor

1;

package MyXMLSimple;
use base 'XML::Simple';

# Overriding the method here
sub sorted_keys {
    my ( $self, $name, $hashref ) = @_;
    if ( $name eq 'programme' )    # only this tag I care about the order;
    {
        my @ordered      = ( 'title', 'sub-title', 'desc' );
        my %ordered_hash = map { $_ => 1 } @ordered;

        #set ordered tags in front of others
        return @ordered, grep { not $ordered_hash{$_} } $self->SUPER::sorted_keys( $name, $hashref );
    } ## end if ( $name eq 'programme'...)
    return $self->SUPER::sorted_keys( $name, $hashref );    # for the rest, I don't care!

} ## end sub sorted_keys

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
