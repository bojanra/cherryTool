package cherryEpg::Parser::PlusXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.26';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => hash of arrays of events found

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $handler = PlusXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  $parser->parse( Source => { SystemId => $self->{source} } );

  return $report;
} ## end sub parse

package PlusXMLHandler;
use strict;
use warnings;
use Time::Piece;
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

  if ( $element->{Name} eq 'EVENT' ) {
    my $event = {};

    # save the datetime Attributes
    $event->{start} = try {
      if ( exists $element->{Attributes}{time} ) {
        return gmtime->strptime( $element->{Attributes}{time}, "%Y-%m-%dT%H:%M:%SZ" )->epoch;
      } else {
        return;
      }
    };

    $event->{duration} = try {
      if ( exists $element->{Attributes}{duration} ) {
        return $1                         if $element->{Attributes}{duration} =~ m/PT(\d+)S$/;
        return $1 * 60 + $2               if $element->{Attributes}{duration} =~ m/PT(\d+)M(\d+)S$/;
        return ( $1 * 60 + $2 ) * 60 * $3 if $element->{Attributes}{duration} =~ m/PT(\d)H(\d+)M(\d+)S$/;
      }
      return;
    };

    $self->{currentEvent} = $event;
  } ## end if ( $element->{Name} ...)

  if ( $element->{Name} eq 'PARENTAL_RATING' ) {

    $self->{currentEvent}{parental_rating} = try {
      if ( exists $element->{Attributes}{dvb_rating}
        && $element->{Attributes}{dvb_rating} =~ m|^(0x[a-f0-9]+)$| ) {
        return hex($1) + 3;
      }
      return;
    };
    $self->{currentEvent}{country_code} = try {
      return $element->{Attributes}{country};
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
  my $value = $self->{currentData};
  my $event = $self->{currentEvent};
  my $lang  = $self->{currentLang};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
    /EVENT/ && do {

      # add the event to the list
      $self->addEvent();
      return;
    };
    /SHORT_DESCRIPTION/ && do {

      return if $value eq '';

      $event->{subtitle} = $value;
      return;
    };
    /NAME/ && do {

      return if $value eq '';

      $event->{title} = $value;
      return;
    };
    /DESCRIPTION/ && do {

      return if $value eq '';

      $event->{synopsis} = $value;
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
  push( @missing, "start" ) unless defined $event->{start};
  push( @missing, "title" ) unless defined $event->{title};

  if ( scalar @missing > 0 ) {
    $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  # push to final array
  push( @{ $self->{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2023 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
