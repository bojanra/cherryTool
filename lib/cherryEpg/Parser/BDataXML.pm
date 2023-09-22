package cherryEpg::Parser::BDataXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.29';

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

  my $handler = BDataXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  $parser->parse( Source => { SystemId => $self->{source} } );

  return $report;
} ## end sub parse

package BDataXMLHandler;
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
  $self->{report}{channel}   = $self->{Service};
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} eq "Event" ) {
    $self->{currentEvent} = {};
  }

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

  for ( $element->{Name} ) {
    $_ eq "Event" && do {

      # add the event to the list
      $self->addEvent();
      return;
    };
    $_ eq "StartDateTime" && do {
      return unless $value;

      # remove .000 from 2023-04-22T05:00:00.000+0000
      if ( $value =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.\d{3}(.+)$/ ) {
        my $t = $1 . $2;
        $event->{start} = try { gmtime->strptime( $t, "%Y-%m-%dT%H:%M:%S%z" )->epoch; };
      }

      return;
    };
    $_ eq "Duration" && do {
      return unless $value;
      if ( $value =~ m/^(\d\d):(\d\d):(\d\d)$/ ) {
        $event->{duration} = ( ( $1 * 60 ) + $2 ) * 60 + $3;
      }
      return;
    };
    /TitleEnglish/ && do {
      return unless $value;

      $event->{title} = $value;
      return;
    };
    /TitleArabic/ && do {
      return unless $value;

      # $event->{title}{ara} = $value;
      return;
    };
    /DescriptionEnglish/ && do {
      return unless $value;

      $event->{synopsis} = $value;
      return;
    };
  } ## end for ( $element->{Name} )
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

=encoding utf8

This software is copyright (c) 2023 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
