package cherryEpg::Parser::TurnerXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.01';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $handler = TurnerXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  $parser->parse( Source => { SystemId => $self->{source} } );

  return $report;
} ## end sub parse

package TurnerXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;
use Carp qw( croak );

sub new {
  my $this  = shift;
  my $class = ref($this) || $this;
  my $self  = {};

  bless( $self, $class );
  return $self;
} ## end sub new

sub start_document {
  my ($self) = @_;

  # this will be the events array
  $self->{eventList} = [];

  # and the possible error list
  $self->{errorList} = [];
} ## end sub start_document

sub end_document {
  my ($self) = @_;

  $self->{report}            = $self->{'_parser'}->{output};
  $self->{report}{eventList} = $self->{eventList};
  $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} =~ /^listing$/i ) {
    $self->{currentEvent} = {};
  } elsif ( $element->{Name} =~ /^channel$/i ) {

    # Extract channel name from attributes if present
    if ( defined $element->{Attributes}{name} ) {
      my $channel_name = $element->{Attributes}{name};
      $channel_name =~ s/\s+/-/g;    # replace spaces with dashes
      $self->{channel_id} = lc($channel_name);
    }
  } ## end elsif ( $element->{Name} ...)

  $self->{currentData} = "";
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;

  $self->{currentData} .= $element->{Data};
}

sub end_element {
  my ( $self, $element ) = @_;
  my $value = $self->{currentData};
  my $event = $self->{currentEvent};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /^listing$/i && do {
      $self->addEvent();
      return;
    };
    /^broadcastDate$/i && do {
      $event->{start} = try {
        localtime->strptime( $value, "%Y-%m-%d %H:%M:%S" )->epoch;
      };
      $self->_error("broadcastDate not valid format [$value]") unless $event->{start};
      return;
    };
    /^duration$/i && do {
      if ( $value =~ /(\d+)/ && $1 > 0) {
        $event->{duration} = $1 * 60;
      } else {
        $self->_error("duration not valid number or 0 [$value]");
      }
      return;
    };
    /^title$/i && do {
      $event->{title} = $value;
      return;
    };
    /^episodeTitle$/i && do {
      $event->{subtitle} = $value;
      return;
    };
    /^synopsis$/i && do {
      $event->{synopsis} = $value;
      return;
    };
    /^episodeSynopsis$/i && do {

      # Use episode synopsis if no main synopsis exists
      $event->{synopsis} ||= $value;
      return;
    };
    /^certification$/i && do {
      return if $value eq 'TP';    # TP (Todos los Públicos) — equivalent to 'suitable for all'
      if ( $value =~ /(\d+)/ ) {
        $event->{parental_rating} = $1;
      }
      return;
    };
    /^yearOfProduction$/i && do {
      if ( $value =~ /(\d{4})/ ) {
        $event->{year} = $1;
      }
      return;
    };
    /^episodeNb$/i && do {
      if ( $value =~ /(\d+)/ ) {
        $event->{episodeNum} = $1;
      }
      return;
    };
    /^seasonNb$/i && do {
      if ( $value =~ /(\d+)/ ) {
        $event->{seasonNum} = $1;
      }
      return;
    };
    /^episodeCount$/i && do {
      if ( $value =~ /(\d+)/ ) {
        $event->{episodeCount} = $1;
      }
      return;
    };
  } ## end SWITCH: for ( $element->{Name} )
  return;
} ## end sub end_element

sub set_document_locator {
  my ( $self, $params ) = @_;
  $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
  my $self = shift;

  push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

sub addEvent {
  my $self  = shift;
  my $event = $self->{currentEvent};

  # check if all event data is complete and valid
  my @missing;
  push( @missing, "start" )    unless defined $event->{start};
  push( @missing, "duration" ) unless defined $event->{duration} && $event->{duration} > 0;
  push( @missing, "title" )    unless defined $event->{title};
  if ( scalar @missing > 0 ) {
    $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  if ( $event->{yearOfProduction} && $event->{title} ) {
    $event->{title} .= " (" . $event->{yearOfProduction} . ")";
  }

  # Build episode information if available
  if ( $event->{episodeNum} && $event->{seasonNum} ) {
    my $episodeInfo = "";
    $episodeInfo .= "S" . $event->{seasonNum};
    $episodeInfo .= "E" . $event->{episodeNum} . ( $event->{episodeCount} ? "/$event->{episodeCount}" : "" );
    $event->{subtitle} = $episodeInfo . $event->{subtitle};
  } ## end if ( $event->{episodeNum...})

  # push to final array
  push( @{ $self->{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2026 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
