package cherryEpg::Exporter;

use 5.024;
use utf8;
use Moo::Role;
use Time::Local;

=head3 export2XMLTV( $list, $url)

Export schedule data for $list of channels in xml format.
Use $url as source and $language for descriptors.
By $flavor we can change the output of various parameters. Default is undefined.
Return xml serialized string.

=cut

sub export2XMLTV {
  my ( $self, $list, $url, $flavor ) = @_;
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

  if ( $flavor && $flavor =~ 'stn' ) {
    delete $xml->{'tv'}{'generator-info-name'};
    delete $xml->{'tv'}{'generator-info-url'};
    delete $xml->{'tv'}{'channel'};
  }

  foreach my $channel ( sort { $a->{channel_id} <=> $b->{channel_id} } @$list ) {
    my $channel_id = $channel->{channel_id};

    my $channelNotDefined = 1;

    foreach my $event ( $self->listEvent( $channel->{channel_id} )->@* ) {

      # add events
      my $eventDescription;

      if ( $flavor && $flavor =~ 'stn' ) {

        # some flavored XMLTV outputL
        local $ENV{TZ} = 'UTC';
        $eventDescription = {
          'start' => Time::Piece->new( $event->{start} )->strftime("%Y%m%d%H%M%S %z"),
          'stop'  => Time::Piece->new( $event->{stop} )->strftime("%Y%m%d%H%M%S %z"),
          'title' => {
            content => $event->{title},
          },
          'desc' => {
            content => $event->{synopsis},
          }
        };
      } else {

        # standard XMLTV

        # define the channel with the first event
        if ($channelNotDefined) {
          my $channelDefinition = {
            'id'           => $channel_id & 0xffff,
            'display-name' => { 'lang' => $event->{language}, 'content' => $channel->{name} }
          };
          push( $xml->{tv}{channel}->@*, $channelDefinition );
          $channelNotDefined = 0;
        } ## end if ($channelNotDefined)

        $eventDescription = {
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

      } ## end else [ if ( $flavor && $flavor...)]

      $eventDescription->{image}{content} = $event->{image} if exists $event->{image};

      push( $xml->{tv}{programme}->@*, $eventDescription );
    } ## end foreach my $event ( $self->...)
  } ## end foreach my $channel ( sort ...)

  my $xmlParser = MyXMLSimple->new( RootName => 'xml', KeepRoot => 1 );
  $output .= $xmlParser->XMLout($xml);
  utf8::encode($output);

  return $output;
} ## end sub export2XMLTV


=head3 export2CSV( $channel, $custom)

Export schedule data for $channel in CSV format.
Set $custom for nonstandard columns.

This is done without using Text::CSV beacuse the module is not part of standard cherryEpg distribution
and using it would break backward compatibility because of missing module.

Return string.

=cut

sub export2CSV {
  my ( $self, $channel, $custom ) = @_;

  my @list;

  foreach my $event ( $self->listEvent( $channel->{channel_id} )->@* ) {

    my @row;

    if ( !$custom ) {

      # default columns
      # add column header
      push( @list, '"Date","Time","Duration","Title","Short","Synopsis","Parental"' ) unless @list;

      @row = (
        Time::Piece->new( $event->{start} )->strftime("%d/%m/%Y"),
        Time::Piece->new( $event->{start} )->strftime("%H:%M:%S"),
        Time::Piece->new( $event->{stop} )->epoch -Time::Piece->new( $event->{start} )->epoch,
        $event->{title},
        $event->{subtitle},
        $event->{synopsis}
      );

      foreach my $descriptor ( $event->{descriptors}->@* ) {
        next unless $descriptor->{descriptor_tag} == 85;
        my $item = shift( $descriptor->{list}->@* );
        if ($item) {
          push( @row, $item->{rating} );
          last;
        }
      } ## end foreach my $descriptor ( $event...)
    } elsif ( $custom =~ /stn/i ) {

      # customized CSV format
      # add column header
      push( @list,
        '"start_date","start_time","end_date","end_time","repeat_type","repeat_interval","repeat_count","repeat_start_date","repeat_end_on","repeat_end_after","repeat_never","repeat_by","repeat_on_sun","repeat_on_mon","repeat_on_tue","repeat_on_wed","repeat_on_thu","repeat_on_fri","repeat_on_sat","title","description","allDay","url","organizer","venue","resources","color","backgroundColor","textColor","borderColor","location","available","privacy","image","thumbnail","actors","tags","language","invitation","invitation_event_id","invitation_creator_id","invitation_response","free_busy"'
          )
          unless @list;

      @row = (
        Time::Piece->new( $event->{start} )->strftime("%d/%m/%Y"),
        Time::Piece->new( $event->{start} )->strftime("%H:%M:%S"),
        Time::Piece->new( $event->{stop} )->strftime("%d/%m/%Y"),
        Time::Piece->new( $event->{stop} )->strftime("%H:%M:%S"),
        'none',
        1,
        0,
        Time::Piece->new( $event->{start} )->strftime("%d/%m/%Y"),
        Time::Piece->new( $event->{stop} )->strftime("%d/%m/%Y"),
        0,
        0,
        '',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        $event->{title},
        $event->{synopsis},
        'on',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        1,
        'public',
        '',
        '',
        '',
        '',
        'english',
        1,
        '',
        '',
        'pending',
        'free',
      );

    } ## end elsif ( $custom =~ /stn/i)

    map( { s/\n/ /g; } @row ) if @row;

    # escape all double quotes and put all but numbers in double quotes
    push( @list, join( ',', map { m/^\d+$/ ? $_ : '"' . (s/\"/\"\"/rg) . '"' } @row ) ) if @row;
  } ## end foreach my $event ( $self->...)

  return join( "\n", @list );
} ## end sub export2CSV

1;

package MyXMLSimple;
use base 'XML::Simple';

# This is a sorting hack to have title, sub-title and desc on first order
sub sorted_keys {
  my ( $self, $name, $hashref ) = @_;

  my @origin = ( $self->SUPER::sorted_keys( $name, $hashref ) );

  if ( $name eq 'programme' ) {

    # only this tag I care about the order;
    my @wish  = ( 'title', 'sub-title', 'desc' );
    my %order = map { $wish[$_] => $_ } 0 .. $#wish;

    #set wish tags in front of others
    return
        sort { ( exists $order{$a} ? $order{$a} : scalar @wish ) <=> ( exists $order{$b} ? $order{$b} : scalar @wish ) } @origin;
  } ## end if ( $name eq 'programme')
  return @origin;

} ## end sub sorted_keys

=head1 AUTHOR

This software is copyright (c) 2019-2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
