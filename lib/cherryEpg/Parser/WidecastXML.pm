package cherryEpg::Parser::WidecastXML;

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

  my $handler = WidecastXMLHandler->new($language_code);
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  try {
    $parser->parse( Source => { SystemId => $self->{source} } );
  };

  return $report;
} ## end sub parse

package WidecastXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Try::Tiny;
use Carp qw( croak );

sub new {
  my ( $this, $language_code ) = @_;
  my $class = ref($this) || $this;

  # set primary language_code od default
  my $self = { wanted_language_code => $language_code // 'eng', };

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

  if ( $element->{Name} eq 'Event' ) {
    my $event = {};

    # save the datetime Attributes
    $event->{start} = try {
      if ( exists $element->{Attributes}{start_time} ) {
        return gmtime->strptime( $element->{Attributes}{start_time}, "%Y-%m-%d %H:%M:%S" )->epoch;
      } else {
        return;
      }
    };

    $event->{duration} = try {
      if ( exists $element->{Attributes}{duration} ) {
        return $1 if $element->{Attributes}{duration} =~ m/^(\d+)$/;
      }
      return;
    };

    $self->{currentEvent} = $event;
  } ## end if ( $element->{Name} ...)

  if ( $element->{Name} eq 'short_event_descriptor'
    || $element->{Name} eq 'extended_event_descriptor' ) {
    $self->{currentEvent}{language_code} = try {
      if ( exists $element->{Attributes}{lang} ) {
        return $element->{Attributes}{lang};
      }
      return;
    };
    $self->{currentEvent}{name} = try {
      if ( exists $element->{Attributes}{name} ) {
        return $element->{Attributes}{name};
      }
      return;
    };
  } ## end if ( $element->{Name} ...)

  if ( $element->{Name} eq 'content_descriptor' ) {

    $self->{currentEvent}{nibble} = try {
      if ( exists $element->{Attributes}{nibble1}
        && exists $element->{Attributes}{nibble1} ) {
        return $element->{Attributes}{nibble1} << 4 | $element->{Attributes}{nibble2};
      }
      return;
    };
  } ## end if ( $element->{Name} ...)

  if ( $element->{Name} eq 'parental_rating_descriptor' ) {

    $self->{currentEvent}{country_code} = try {
      if ( exists $element->{Attributes}{country_code} ) {
        return $element->{Attributes}{country_code};
      }
      return;
    };
  } ## end if ( $element->{Name} ...)

  $self->{currentData} = "";
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;

  $self->{currentData} .= $element->{Data};
}

sub end_element {
  my ( $self, $element ) = @_;
  my $value         = $self->{currentData};
  my $event         = $self->{currentEvent};
  my $language_code = $event->{language_code} // 'eng';

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /Event/ && do {
      $self->mapLang();
      $self->addEvent();
      return;
    };
    /short_event_descriptor/ && do {
      $event->{lang}{$language_code}{title}    = $event->{name};
      $event->{lang}{$language_code}{subtitle} = $value;
      return;
    };
    /extended_event_descriptor/ && do {
      $event->{lang}{$language_code}{synopsis} = $value;
      return;
    };
    /parental_rating_descriptor/ && do {
      $event->{parental_rating} = $value;
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

sub mapLang {
  my $self                 = shift;
  my $event                = $self->{currentEvent};
  my $wanted_language_code = $self->{wanted_language_code};

  # try to use the selected lang
  foreach my $key (qw( title subtitle synopsis )) {
    $event->{$key} = $event->{lang}{$wanted_language_code}{$key} if exists $event->{lang}{$wanted_language_code}{$key};
  }

  # if the subtitle is empty try to use english version
  $event->{subtitle} = $event->{lang}{eng}{title} if !$event->{subtitle} && exists $event->{lang}{eng}{title};

  delete( @$event{qw(lang name language_code )} );

  return 1;
} ## end sub mapLang

sub addEvent {
  my $self  = shift;
  my $event = $self->{currentEvent};

  # check if all event data is complete and valid
  my @missing;
  push( @missing, "start" ) unless $event->{start};
  push( @missing, "title" ) unless $event->{title};

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
