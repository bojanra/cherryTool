package cherryEpg::Exporter;

use 5.024;
use utf8;
use Moo::Role;
use Time::Local;

=head3 exportScheduleData( $list, $url)

Export schedule data for $list of channels in xml format.
Use $url as source and $language for descriptors.
Return xml serialized string.

=cut

sub exportScheduleData {
  my ( $self, $list, $url ) = @_;
  $url //= "127.0.0.1";

  # make a correct header
  my $output = '<?xml version="1.0" encoding="utf-8"?>' . "\n";

  my $xml = {
    'tv' => {
      'generator-info-name' => 'cherryEpg',
      'generator-info-url'  => 'https://epg.cherryhill.eu',
      'channel'             => [],
      'programme'           => []
    }
  };

  foreach my $channel ( sort { $a->{channel_id} <=> $b->{channel_id} } @$list ) {
    my $channel_id = $channel->{channel_id};

    my $channelNotDefined = 1;

    foreach my $event ( $self->listEvent( $channel->{channel_id} )->@* ) {

      # define the channel with the first event
      if ($channelNotDefined) {
        my $channelDefinition = {
          'id'           => $channel_id & 0xffff,
          'display-name' => { 'lang' => $event->{language}, 'content' => $channel->{name} }
        };
        push( $xml->{tv}{channel}->@*, $channelDefinition );
        $channelNotDefined = 0;
      } ## end if ($channelNotDefined)

      # add events
      my $eventDescription = {
        'title' => {
          'lang'    => $event->{language},
          'content' => $event->{title},
        },
        'channel' => $channel->{channel_id} & 0xffff,
        'start'   => Time::Piece->new( $event->{start} )->strftime("%Y%m%d%H%M%S %z"),
        'stop'    => Time::Piece->new( $event->{stop} )->strftime("%Y%m%d%H%M%S %z"),
      };

      $eventDescription->{'sub-title'}{lang}    = $event->{language};
      $eventDescription->{'sub-title'}{content} = $event->{subtitle};

      $eventDescription->{desc}{lang}    = $event->{language};
      $eventDescription->{desc}{content} = $event->{synopsis};

      foreach my $descriptor ( $event->{descriptors}->@* ) {
        next unless $descriptor->{descriptor_tag} == 85;
        my $item = shift( $descriptor->{list}->@* );
        if ($item) {
          $eventDescription->{parentalrating}{lang}    = $event->{language};
          $eventDescription->{parentalrating}{content} = $item->{rating};
        }
      } ## end foreach my $descriptor ( $event...)

      $eventDescription->{image}{content} = $event->{image} if exists $event->{image};

      push( $xml->{tv}{programme}->@*, $eventDescription );
    } ## end foreach my $event ( $self->...)
  } ## end foreach my $channel ( sort ...)

  my $xmlParser = MyXMLSimple->new( RootName => 'xml', KeepRoot => 1 );
  $output .= $xmlParser->XMLout($xml);
  utf8::encode($output);

  return $output;
} ## end sub exportScheduleData

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
