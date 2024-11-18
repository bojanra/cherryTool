package cherryEpg::Parser::TitanXML;

use 5.024;
use utf8;
use Moo;
use Try::Tiny;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.27';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => hash of arrays of events found

The parser accepts the prefered language_code as an option in the $parserOption field.

The language_code should be a 3-letter language code (eng, alb) which will be used for
selecting the event title/subtitle/synopsis. If not used it should be empty.

=cut

sub parse {
  my ( $self, $parserOption ) = @_;
  my $report = $self->{report};

  # get value
  my ($language_code) = split( /,/, $parserOption // '' );

  my $handler = TitanXMLHandler->new($language_code);
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  try {
    $parser->parse( Source => { SystemId => $self->{source} } );
  };

  return $report;
} ## end sub parse

package TitanXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Try::Tiny;
use Carp qw( croak );

sub new {
  my ( $this, $language_code ) = @_;
  my $class = ref($this) || $this;

  # set primary language_code od default
  my $self = {};

  bless( $self, $class );
  return $self;
} ## end sub new

sub start_document {
  my ($self) = @_;

  # this will be the list of events
  $self->{eventList} = [];

  # and the possible error list
  $self->{errorList} = [];
} ## end sub start_document

sub end_document {
  my ( $self, $element ) = @_;

  $self->{report}            = $self->{'_parser'}->{output};
  $self->{report}{eventList} = $self->{eventList};
  $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} eq 'Show' ) {
    my $event = {};

    # save the datetime Attributes
    $event->{start} = try {
      if ( exists $element->{Attributes}{startTimeUtc} ) {
        return gmtime->strptime( $element->{Attributes}{startTimeUtc}, "%Y-%m-%dT%H:%M:%S" )->epoch;
      } else {

        return;
      }
    };

    $event->{duration} = try {

      # decode duration in PT1H20M30S format
      if ( exists $element->{Attributes}{duration} && $element->{Attributes}{duration} =~ /^PT(.+)$/ ) {
        my $dit = $1;
        my $duration;
        while ( $dit =~ m/(\d+)([HMS])/g ) {
          $duration += $1 * ( $2 eq 'H' ? 60 * 60 : ( $2 eq 'M' ? 60 : 1 ) );
        }
        return $duration if $duration;
      } ## end if ( exists $element->...)
      return;
    };

    $self->{currentEvent} = $event;
  } ## end if ( $element->{Name} ...)

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
    $_ eq 'Show' && do {
      $self->addEvent();
      return;
    };
    $_ eq 'Title' && do {
      $event->{title} = $value;
      return;
    };
    $_ eq 'EpisodeTitle' && do {
      $event->{subtitle} = $value;
      return;
    };
    $_ eq 'Description' && do {
      if ( !exists $event->{synopsis} || length( $event->{synopsis} ) < length($value) ) {
        $event->{synopsis} = $value;
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
  foreach (qw( start title duration)) {
    push( @missing, $_ ) unless $event->{$_};
  }

  if ( scalar @missing > 0 ) {
    $self->_error( "missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  # push to final array
  push( $self->{eventList}->@*, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
